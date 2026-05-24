#!/usr/bin/env bash
#===============================================================================
# exec-channel-watchdog.sh — Host-side podman exec channel watchdog (Issue #382)
#
# Detects a silent-wedge mode that the v2.24.0 vfkit watchdog cannot catch:
# vfkit is still alive, the container is `Up`, the agent process is in
# `podman top`, but `podman exec <container> ...` hangs forever. status-sync
# stalls in lockstep (the same daemon channel is wedged), so the host sees
# `phase: running` and no exit code until a human runs `podman machine stop`.
#
# Symptom evidence (issue #382): a 37-minute "Up" container where
# `timeout 10 podman exec ... echo hello` returns rc=124. The vfkit watchdog
# does not fire (vfkit alive). The in-VM liveness probe does not fire
# (its sentinel write into /kapsis-status is what's blocked).
#
# Mechanism: every $interval seconds, run `timeout $exec_timeout podman exec
# <ctr> true`. If $threshold consecutive ticks return non-zero, treat the
# channel as dead — write the host-only sentinel, mark status.json
# `exit_code: 4` + `error_type: exec_channel_hang`, and SIGTERM the agent's
# `podman run` foreground process (analogous to vfkit-watchdog.sh).
#
# Trust model mirrors the vfkit watchdog (Issue #303 ensemble review #2):
# the override block in launch-agent.sh requires the host-only sentinel
# (under $TMPDIR, NOT bind-mounted) as the authoritative proof. status.json
# is mirrored from a named volume the container can write, so it confirms
# the watchdog's own write but is never trusted in isolation.
#
# Public API:
#   start_exec_channel_watchdog <agent_id> [container_name] [interval] \
#                               [exec_timeout] [threshold] [sentinel_path]
#       Spawns a backgrounded watchdog subshell. Sets
#       _EXEC_CHANNEL_WATCHDOG_PID (caller-readable). No-op on Linux or when
#       disabled.
#
# Caller is responsible for cleanup (same shape as vfkit-watchdog):
#   if [[ -n "$_EXEC_CHANNEL_WATCHDOG_PID" ]]; then
#       kill "$_EXEC_CHANNEL_WATCHDOG_PID" 2>/dev/null || true
#       wait "$_EXEC_CHANNEL_WATCHDOG_PID" 2>/dev/null || true
#   fi
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
#                             [exec_timeout] [threshold] [sentinel_path]
#
# interval       — seconds between probes (default 30; KAPSIS_EXEC_WATCHDOG_INTERVAL)
# exec_timeout   — seconds per probe (default 5; KAPSIS_EXEC_WATCHDOG_TIMEOUT)
# threshold      — consecutive failures before firing (default 3;
#                  KAPSIS_EXEC_WATCHDOG_THRESHOLD). With defaults: ~90s blind
#                  window from first hang to escalation. Trade-off: lower
#                  thresholds catch wedges faster but may misfire on
#                  transient daemon hiccups (network pause, image pull on
#                  another container). 3 has been chosen as a conservative
#                  default; can be lowered via env var.
# sentinel_path  — host-only file path the watchdog touches on fire. MUST
#                  be host-private (under $TMPDIR or another non-bind-mounted
#                  dir) or the trust anchor in the override block is void.
#
# Exits silently on parent death or external SIGTERM/SIGHUP — a stale
# watchdog must not fire on a future agent that reuses the same AGENT_ID
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
    local sentinel_path="${6:-}"

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
    # Same character class as vfkit-watchdog and pkill boundary class below.
    if ! [[ "$agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_warn "exec-channel watchdog: invalid agent_id '$agent_id' — skipping"
        return 0
    fi
    # Container name must be safe to pass to podman without quoting hazards.
    if ! [[ "$container_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        log_warn "exec-channel watchdog: invalid container_name '$container_name' — skipping"
        return 0
    fi
    # All three timing knobs must be positive integers.
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
        # Exit silently when the parent cleanup kills us, so we never
        # double-fire after a normal agent shutdown.
        trap 'exit 0' TERM HUP INT

        # POSIX-ERE-portable boundary class (same rationale as vfkit-watchdog.sh):
        # macOS BSD pkill does NOT support \b. `[^a-zA-Z0-9_-]` matches the
        # space that always follows `--name kapsis-${AGENT_ID}` in argv.
        local boundary='[^a-zA-Z0-9_-]'

        local failures=0
        while true; do
            # Orphan protection: a stale watchdog (parent SIGKILLed,
            # terminal hung up) must not fire on a future agent that
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
                # Recovery — reset the counter. A wedge that clears on its
                # own (transient daemon contention) must not accumulate
                # across long uptimes.
                failures=0
            else
                failures=$((failures + 1))
                log_debug "exec-channel watchdog: probe failed (${failures}/${threshold}) for ${container_name}"
                if (( failures >= threshold )); then
                    break
                fi
            fi

            # Backgrounded sleep + wait so SIGTERM from the cleanup trap
            # interrupts immediately (otherwise normal-shutdown wait would
            # block up to $interval seconds).
            sleep "$interval" & wait $! 2>/dev/null
        done

        # Threshold breached. One last parent check before firing — racing
        # with normal cleanup is fine; the trap above handles the
        # cleanup-kills-watchdog ordering.
        if ! kill -0 "$parent_pid" 2>/dev/null; then
            exit 0
        fi

        # Host-only sentinel FIRST — this is the authoritative "watchdog
        # fired" signal and is checked by the post-container override in
        # launch-agent.sh. Writing this before status_complete means the
        # override has a strong signal even if status_complete fails
        # (disk full, status disabled, etc.).
        if [[ -n "$sentinel_path" ]]; then
            : > "$sentinel_path" 2>/dev/null || true
        fi
        status_set_error_type "exec_channel_hang" 2>/dev/null || true
        status_complete 4 "Container exec channel wedged: ${threshold} consecutive 'podman exec ${container_name} true' probes timed out (>${exec_timeout}s each, host-side watchdog). vfkit alive; podman daemon exec channel hung. Recovery: podman machine stop && podman machine start, then re-run." 2>/dev/null || true
        log_warn "KAPSIS_EXEC_CHANNEL_HANG[exec_channel_watchdog]: ${threshold} consecutive podman exec timeouts on ${container_name} — daemon exec channel wedged"
        pkill -TERM -f "podman run .*--name kapsis-${agent_id}(${boundary}|\$)" 2>/dev/null || true
    ) &
    _EXEC_CHANNEL_WATCHDOG_PID=$!

    log_debug "exec-channel watchdog active (container: $container_name, poll: ${interval}s, timeout: ${exec_timeout}s, threshold: ${threshold}, watchdog PID: $_EXEC_CHANNEL_WATCHDOG_PID)"
}
