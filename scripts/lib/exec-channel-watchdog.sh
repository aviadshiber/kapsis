#!/usr/bin/env bash
#===============================================================================
# exec-channel-watchdog.sh — Host-side podman exec channel degraded-state
# reporter (Issue #382, demoted from lethal to observability-only in #414)
#
# Detects a silent-wedge mode that the v2.24.0 vfkit watchdog cannot catch:
# vfkit is still alive, the container is `Up`, the agent process is in
# `podman top`, but `podman exec <container> ...` hangs. status-sync stalls
# in lockstep (the same daemon channel is wedged), so the host sees
# `phase: running` and no exit code even though the agent may be working fine.
#
# THIS LIBRARY IS OBSERVABILITY ONLY (Issue #414). It never terminates the
# agent and never writes terminal status. The original (#382) design fired
# terminally past the failure threshold — status_complete with exit 4 plus a
# SIGTERM of the agent's foreground process. Incident #414 proved both halves
# wrong: the kill was ineffective (container stop must propagate through the
# very daemon channel that is wedged — the incident agent survived it and
# worked 40 more minutes), while the host-side terminal status write was the
# direct cause of a false "failed" verdict on an agent that later exited 0
# with committed work. Any design that keeps a kill/terminal path in this lib
# preserves the harm and the futility, so both were removed.
#
# Mechanism: every $interval seconds, run `timeout $exec_timeout podman exec
# <ctr> true`. If $threshold consecutive ticks fail, enter DEGRADED:
#   - create the host-only degraded marker (see contract below),
#   - log a single KAPSIS_EXEC_CHANNEL_DEGRADED line,
#   - keep probing forever with exponential backoff capped at
#     KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP (default 300s).
# Every failed tick while degraded refreshes the marker's mtime — an
# independent host-side heartbeat that dashboards can watch even while
# status.json is frozen. On the first successful probe after degradation:
#   - remove the marker,
#   - log KAPSIS_EXEC_CHANNEL_RECOVERED with the degraded duration,
#   - reset the failure counter and probe interval.
#
# Degraded-marker path contract (arg 6):
#   - MUST be host-private (under $TMPDIR or another non-bind-mounted dir)
#     so a compromised agent inside the container cannot forge or clear it.
#   - Created on entering DEGRADED, mtime-refreshed on every degraded tick,
#     removed on recovery, and removed by the caller's cleanup path.
#   - The caller pre-cleans it before starting the watchdog so a leftover
#     marker can never make a resumed --agent-id run appear degraded.
#
# Termination during a wedge is explicitly NOT this lib's job. It is owned
# by the machinery that actually works while the daemon exec channel is
# wedged: natural `podman run` exit, the vfkit watchdog (Issue #303), the
# liveness monitor (Issue #257), or the documented manual VM recovery
# (`podman machine` stop then start).
#
# DO NOT reintroduce (see incident #414):
#   - Any `podman machine` restart from this lib. Restarting the shared VM
#     destroys every concurrent bystander agent (3 were running during the
#     incident). Tests statically assert this lib never invokes it.
#   - Daemon-dependent corroboration (e.g. `podman inspect`) as a hard gate
#     for any terminal action. inspect shares the libpod API socket with
#     exec; whether it survives the FB16008360/podman#23061 wedge is
#     empirically unverified — gating on it either blocks real detection or
#     manufactures false confidence. Verify empirically first (tracked in
#     the #414 follow-up) before making it a decision input.
#
# Public API:
#   start_exec_channel_watchdog <agent_id> [container_name] [interval] \
#                               [exec_timeout] [threshold] [degraded_marker_path]
#       Spawns a backgrounded watchdog subshell. Sets
#       _EXEC_CHANNEL_WATCHDOG_PID (caller-readable). No-op on Linux or when
#       disabled.
#
# Caller is responsible for cleanup (same shape as vfkit-watchdog):
#   if [[ -n "$_EXEC_CHANNEL_WATCHDOG_PID" ]]; then
#       kill "$_EXEC_CHANNEL_WATCHDOG_PID" 2>/dev/null || true
#       wait "$_EXEC_CHANNEL_WATCHDOG_PID" 2>/dev/null || true
#   fi
#   rm -f "$degraded_marker_path"
#===============================================================================

[[ -n "${_KAPSIS_EXEC_CHANNEL_WATCHDOG_LOADED:-}" ]] && return 0
_KAPSIS_EXEC_CHANNEL_WATCHDOG_LOADED=1

# Stubs for isolated test contexts (production has logging.sh + compat.sh sourced first).
declare -f log_warn  &>/dev/null || log_warn()  { echo "[WARN] $*" >&2; }
declare -f log_debug &>/dev/null || log_debug() { :; }
declare -f is_macos  &>/dev/null || is_macos()  { [[ "$(uname -s)" == "Darwin" ]]; }

_KAPSIS_EXEC_WATCHDOG_PODMAN="${KAPSIS_EXEC_WATCHDOG_PODMAN:-podman}"

#-------------------------------------------------------------------------------
# start_exec_channel_watchdog <agent_id> [container_name] [interval]
#                             [exec_timeout] [threshold] [degraded_marker_path]
#
# interval       — seconds between probes while healthy (default 30;
#                  KAPSIS_EXEC_WATCHDOG_INTERVAL). While degraded the
#                  interval doubles per failed tick up to the backoff cap.
# exec_timeout   — seconds per probe (default 5; KAPSIS_EXEC_WATCHDOG_TIMEOUT)
# threshold      — consecutive failures before entering DEGRADED (default 3;
#                  KAPSIS_EXEC_WATCHDOG_THRESHOLD). With defaults: ~90s from
#                  first hang to the degraded report. Trade-off: lower
#                  thresholds report wedges faster but may flap on transient
#                  daemon hiccups (network pause, image pull on another
#                  container). 3 is a conservative default.
# degraded_marker_path
#                — host-only file the watchdog creates on entering DEGRADED,
#                  mtime-refreshes on every degraded tick, and removes on
#                  recovery. MUST be host-private (under $TMPDIR or another
#                  non-bind-mounted dir); see the header contract.
#
# Backoff knob:
#   KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP — max degraded probe interval in seconds
#   (default 300; validated positive integer). Bounds both host load while
#   degraded and worst-case recovery-detection latency.
#
# Exits silently on parent death or external SIGTERM/SIGHUP — a stale
# watchdog must not report on a future agent that reuses the same AGENT_ID
# via --agent-id resume.
#
# Sets:
#   _EXEC_CHANNEL_WATCHDOG_PID — PID of the watchdog subshell, or empty if skipped
#-------------------------------------------------------------------------------
start_exec_channel_watchdog() {
    local agent_id="${1:-}"
    local container_name="${2:-}"
    local interval="${3:-${KAPSIS_EXEC_WATCHDOG_INTERVAL:-30}}"
    local exec_timeout="${4:-${KAPSIS_EXEC_WATCHDOG_TIMEOUT:-5}}"
    local threshold="${5:-${KAPSIS_EXEC_WATCHDOG_THRESHOLD:-3}}"
    local degraded_marker_path="${6:-}"
    local backoff_cap="${KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP:-300}"

    _EXEC_CHANNEL_WATCHDOG_PID=""

    if [[ -z "$agent_id" ]]; then
        log_warn "exec-channel watchdog: missing agent_id — skipping"
        return 0
    fi
    if ! is_macos; then
        # The wedge family (FB16008360 / podman#23061) is macOS-applehv-specific.
        # Skip on Linux for the same reason vfkit-watchdog does.
        return 0
    fi
    if [[ "${KAPSIS_EXEC_WATCHDOG_ENABLED:-true}" != "true" ]]; then
        log_debug "exec-channel watchdog disabled by KAPSIS_EXEC_WATCHDOG_ENABLED"
        return 0
    fi

    # Default container name follows launch-agent.sh's `--name kapsis-${AGENT_ID}` convention.
    [[ -z "$container_name" ]] && container_name="kapsis-${agent_id}"

    # Validate AGENT_ID format (defense in depth — caller already validates).
    if ! [[ "$agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_warn "exec-channel watchdog: invalid agent_id '$agent_id' — skipping"
        return 0
    fi
    # Container name must be safe to pass to podman without quoting hazards.
    if ! [[ "$container_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        log_warn "exec-channel watchdog: invalid container_name '$container_name' — skipping"
        return 0
    fi
    # All timing knobs must be positive integers.
    if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "exec-channel watchdog: invalid interval '$interval' — using default 30s"
        interval=30
    fi
    if ! [[ "$exec_timeout" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "exec-channel watchdog: invalid exec_timeout '$exec_timeout' — using default 5s"
        exec_timeout=5
    fi
    if ! [[ "$threshold" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "exec-channel watchdog: invalid threshold '$threshold' — using default 3"
        threshold=3
    fi
    if ! [[ "$backoff_cap" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "exec-channel watchdog: invalid backoff cap '$backoff_cap' — using default 300s"
        backoff_cap=300
    fi

    # Verify `timeout` is available. macOS doesn't ship GNU coreutils;
    # Homebrew installs `gtimeout` (used by other kapsis scripts) but for
    # this watchdog we prefer the `timeout` symlink which `setup.sh`
    # provisions, falling back to gtimeout.
    local timeout_bin=""
    if command -v timeout &>/dev/null; then
        timeout_bin="timeout"
    elif command -v gtimeout &>/dev/null; then
        timeout_bin="gtimeout"
    else
        log_warn "exec-channel watchdog: neither timeout nor gtimeout found — skipping"
        return 0
    fi

    local parent_pid=$$
    (
        set +e
        # Exit silently when the parent cleanup kills us, so a stale watchdog
        # never reports on a later agent after a normal shutdown.
        trap 'exit 0' TERM HUP INT

        local failures=0
        local degraded=0
        local base_interval="$interval"
        local degraded_since=""
        while true; do
            # Orphan protection: a stale watchdog (parent SIGKILLed,
            # terminal hung up) must not report on a future agent that
            # reuses the same AGENT_ID via --agent-id resume.
            if ! kill -0 "$parent_pid" 2>/dev/null; then
                exit 0
            fi

            # Active probe. `true` is the lightest possible payload — no
            # filesystem touch, no command parsing inside the container.
            # The hang we're catching lives in the podman daemon's exec
            # attach channel; the inner command doesn't matter.
            #
            # `</dev/null` is critical: without it, `podman exec` would
            # inherit this subshell's stdin which is the parent script's
            # stdin (often a TTY), giving spurious behavior on probe.
            if "$timeout_bin" "$exec_timeout" \
                "$_KAPSIS_EXEC_WATCHDOG_PODMAN" exec "$container_name" true \
                </dev/null >/dev/null 2>&1; then
                if (( degraded == 1 )); then
                    # Recovery from a degraded episode: clear the marker,
                    # report, and go back to the healthy cadence.
                    if [[ -n "$degraded_marker_path" ]]; then
                        rm -f "$degraded_marker_path" 2>/dev/null || true
                    fi
                    log_warn "KAPSIS_EXEC_CHANNEL_RECOVERED[exec_channel_watchdog]: exec channel recovered after $(( $(date +%s) - degraded_since ))s degraded on ${container_name}"
                    degraded=0
                    degraded_since=""
                    interval="$base_interval"
                fi
                # A wedge that clears on its own (transient daemon
                # contention) must not accumulate across long uptimes.
                failures=0
            else
                failures=$((failures + 1))
                log_debug "exec-channel watchdog: probe failed (${failures}/${threshold}) for ${container_name}"
                if (( failures >= threshold )); then
                    if (( degraded == 0 )); then
                        # Enter DEGRADED exactly once per episode. The
                        # marker is the host-side proof + heartbeat; the
                        # log line is what dashboards tail. Nothing is
                        # terminal — the agent keeps running and this
                        # watchdog keeps probing.
                        degraded=1
                        degraded_since=$(date +%s)
                        if [[ -n "$degraded_marker_path" ]]; then
                            : > "$degraded_marker_path" 2>/dev/null || true
                        fi
                        log_warn "KAPSIS_EXEC_CHANNEL_DEGRADED[exec_channel_watchdog]: ${failures} consecutive podman exec timeouts on ${container_name} — daemon exec channel degraded; continuing to probe (agent NOT killed)"
                    else
                        # Heartbeat: refresh the marker mtime on every
                        # degraded tick so out-of-band consumers can tell
                        # "still degraded, watchdog alive" from "stale".
                        if [[ -n "$degraded_marker_path" ]]; then
                            touch "$degraded_marker_path" 2>/dev/null || true
                        fi
                        # Exponential backoff, capped: bounds host load
                        # while degraded and recovery-detection latency.
                        interval=$(( interval * 2 ))
                        if (( interval > backoff_cap )); then
                            interval="$backoff_cap"
                        fi
                    fi
                fi
            fi

            # Backgrounded sleep + wait so SIGTERM from the cleanup trap
            # interrupts immediately (otherwise normal-shutdown wait would
            # block up to $interval seconds).
            sleep "$interval" & wait $! 2>/dev/null
        done
    ) &
    _EXEC_CHANNEL_WATCHDOG_PID=$!

    log_debug "exec-channel watchdog active (container: $container_name, poll: ${interval}s, timeout: ${exec_timeout}s, threshold: ${threshold}, backoff cap: ${backoff_cap}s, watchdog PID: $_EXEC_CHANNEL_WATCHDOG_PID)"
}
