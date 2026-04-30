#!/usr/bin/env bash
#===============================================================================
# vfkit-watchdog.sh — Host-side vfkit watchdog (Issue #303)
#
# When vfkit (the macOS Podman VM hypervisor) dies mid-run, all virtio-fs
# mounts disappear. The in-container liveness probe takes ~188s to detect
# this because FUSE syscalls park the calling process in TASK_UNINTERRUPTIBLE
# (D-state) and SIGKILL cannot interrupt them. A host-side `kill -0` check
# is instantaneous, so we detect the root cause directly and bring the agent
# down within ~10s.
#
# Public API:
#   start_vfkit_watchdog <agent_id> [interval] [machine_name]
#       Spawns a backgrounded watchdog subshell. Sets _VFKIT_WATCHDOG_PID
#       (caller-readable). No-op on Linux or when disabled.
#
# Caller is responsible for cleanup:
#   if [[ -n "$_VFKIT_WATCHDOG_PID" ]]; then
#       kill "$_VFKIT_WATCHDOG_PID" 2>/dev/null || true
#       wait "$_VFKIT_WATCHDOG_PID" 2>/dev/null || true
#   fi
#===============================================================================

[[ -n "${_KAPSIS_VFKIT_WATCHDOG_LOADED:-}" ]] && return 0
_KAPSIS_VFKIT_WATCHDOG_LOADED=1

# Stubs for isolated test contexts (production has logging.sh + compat.sh sourced first).
declare -f log_warn  &>/dev/null || log_warn()  { echo "[WARN] $*" >&2; }
declare -f log_debug &>/dev/null || log_debug() { :; }
declare -f is_macos  &>/dev/null || is_macos()  { [[ "$(uname -s)" == "Darwin" ]]; }

#-------------------------------------------------------------------------------
# start_vfkit_watchdog <agent_id> [interval] [machine] [sentinel_path]
#
# Spawns a backgrounded subshell that polls the vfkit hypervisor PID via
# `kill -0`. On vfkit exit (parent still alive), writes:
#   1. The host-only sentinel file (if `sentinel_path` is provided) — this
#      is the authoritative "watchdog fired" signal. The file path must NOT
#      be bind-mounted into the container, so a compromised agent inside
#      the container cannot forge it. Callers should put the path under
#      `$TMPDIR` (host-private on macOS) or another host-only directory.
#   2. exit_code=4 + error_type=mount_failure to status.json.
#   3. SIGTERM the agent's `podman run` process via a pkill pattern
#      anchored to the AGENT_ID.
#
# Exits silently on parent death or external SIGTERM/SIGHUP — a stale
# watchdog must not SIGTERM a future agent reusing the same AGENT_ID
# (resume mode).
#
# Sets:
#   _VFKIT_WATCHDOG_PID — PID of the watchdog subshell, or empty if skipped
#-------------------------------------------------------------------------------
start_vfkit_watchdog() {
    local agent_id="${1:-}"
    local interval="${2:-${KAPSIS_VFKIT_WATCHDOG_INTERVAL:-5}}"
    local machine="${3:-${KAPSIS_PODMAN_MACHINE:-podman-machine-default}}"
    local sentinel_path="${4:-}"

    _VFKIT_WATCHDOG_PID=""

    if [[ -z "$agent_id" ]]; then
        log_warn "vfkit watchdog: missing agent_id — skipping"
        return 0
    fi
    if ! is_macos; then
        return 0
    fi
    if [[ "${KAPSIS_VFKIT_WATCHDOG_ENABLED:-true}" != "true" ]]; then
        log_debug "vfkit watchdog disabled by KAPSIS_VFKIT_WATCHDOG_ENABLED"
        return 0
    fi
    # Defense-in-depth: validate machine name before passing to pgrep regex.
    # Mirrors scripts/lib/podman-health.sh:_podman_machine_restart guard so a
    # malformed env var (e.g. ".*") cannot make the watchdog latch onto an
    # arbitrary process and silently suppress firing.
    if ! [[ "$machine" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_warn "vfkit watchdog: invalid KAPSIS_PODMAN_MACHINE value '$machine' — skipping"
        return 0
    fi
    # Validate interval — must be a positive integer to avoid `sleep` aborts.
    if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "vfkit watchdog: invalid interval '$interval' — using default 5s"
        interval=5
    fi
    # Validate AGENT_ID format (defense in depth — caller already validates).
    if ! [[ "$agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_warn "vfkit watchdog: invalid agent_id '$agent_id' — skipping"
        return 0
    fi

    local vfkit_pid
    # `pgrep -o` (oldest) is more stable than `-n` (newest) when vfkit was
    # just restarted — `-n` could pick up a transient helper still in argv.
    vfkit_pid=$(pgrep -o -f "vfkit.*${machine}" 2>/dev/null || true)
    if [[ -z "$vfkit_pid" ]]; then
        log_debug "vfkit process not found for machine '$machine' — skipping watchdog"
        return 0
    fi

    local parent_pid=$$
    (
        set +e
        # Exit silently when the parent cleanup kills us, so we never
        # double-fire after a normal agent shutdown.
        trap 'exit 0' TERM HUP INT

        # POSIX-ERE-portable boundary class. macOS BSD pkill does NOT
        # support \b, so an `\b` anchor would silently degrade to no
        # boundary at all and allow AGENT_ID prefix collisions to match.
        # `[^a-zA-Z0-9_-]` matches the space that always follows
        # `--name kapsis-${AGENT_ID}` in argv, and `$` covers EOL.
        local boundary='[^a-zA-Z0-9_-]'

        while kill -0 "$vfkit_pid" 2>/dev/null; do
            # Orphan protection: a stale watchdog (parent SIGKILLed,
            # terminal hung up) must not fire on a future agent that
            # reuses the same AGENT_ID via --agent-id resume.
            if ! kill -0 "$parent_pid" 2>/dev/null; then
                exit 0
            fi
            # Backgrounded sleep + wait so SIGTERM from the cleanup trap
            # interrupts immediately (otherwise normal-shutdown wait would
            # block up to $interval seconds).
            sleep "$interval" & wait $! 2>/dev/null
        done

        # vfkit exited. One last parent check before firing — racing
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
        status_set_error_type "mount_failure" 2>/dev/null || true
        status_complete 4 "Workspace mount lost: vfkit (PID $vfkit_pid) exited (host-side watchdog). Recovery: podman machine stop && podman machine start, then re-run." 2>/dev/null || true
        log_warn "KAPSIS_MOUNT_FAILURE[vfkit_watchdog]: vfkit (PID $vfkit_pid) exited — virtio-fs mounts lost"
        pkill -TERM -f "podman run .*--name kapsis-${agent_id}(${boundary}|\$)" 2>/dev/null || true
    ) &
    _VFKIT_WATCHDOG_PID=$!

    log_debug "vfkit watchdog active (vfkit PID: $vfkit_pid, poll: ${interval}s, watchdog PID: $_VFKIT_WATCHDOG_PID)"
}
