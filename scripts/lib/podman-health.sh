#!/usr/bin/env bash
#===============================================================================
# podman-health.sh — Virtio-fs health probe + auto-heal (Issue #276)
#
# On macOS, the Podman VM's virtio-fs can silently degrade after host sleep/
# wake. The VM reports "running" and `podman info` succeeds, but bind mounts
# become unwritable inside containers: bash fails to open redirect files and
# the agent exits 1 before doing any work.
#
# This library adds a pre-launch check that spins up a short-lived busybox
# container against a real bind mount and verifies it is writable. When the
# probe fails, the Podman VM is restarted (if no other kapsis containers are
# running) and the probe retried.
#
# All functions are no-ops on Linux (native Podman, no virtio-fs).
#===============================================================================

[[ -n "${_KAPSIS_PODMAN_HEALTH_LOADED:-}" ]] && return 0
_KAPSIS_PODMAN_HEALTH_LOADED=1

# Expect the caller to have already sourced logging.sh, compat.sh, constants.sh.
# Fallback stubs keep this library usable from probe/test contexts.
declare -f log_info    &>/dev/null || log_info()    { echo "[INFO] $*"; }
declare -f log_warn    &>/dev/null || log_warn()    { echo "[WARN] $*" >&2; }
declare -f log_error   &>/dev/null || log_error()   { echo "[ERROR] $*" >&2; }
declare -f log_debug   &>/dev/null || log_debug()   { [[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }
declare -f log_success &>/dev/null || log_success() { echo "[OK] $*"; }
declare -f is_macos    &>/dev/null || is_macos()    { [[ "$(uname -s)" == "Darwin" ]]; }
declare -f is_linux    &>/dev/null || is_linux()    { [[ "$(uname -s)" == "Linux" ]]; }

#-------------------------------------------------------------------------------
# _vfs_timeout_cmd
#
# Returns the first available timeout binary (GNU `timeout` on Linux, `timeout`
# from coreutils / `gtimeout` on macOS). Empty string when none is installed.
#-------------------------------------------------------------------------------
_vfs_timeout_cmd() {
    if [[ -n "${_KAPSIS_TIMEOUT_CMD:-}" ]]; then
        printf '%s' "$_KAPSIS_TIMEOUT_CMD"
        return 0
    fi
    if command -v timeout &>/dev/null; then
        printf '%s' "timeout"
    elif command -v gtimeout &>/dev/null; then
        printf '%s' "gtimeout"
    else
        printf ''
    fi
}

#-------------------------------------------------------------------------------
# probe_virtio_fs_health [probe_timeout] [probe_image]
#
# Verifies that the virtio-fs bind-mount transport is functional on macOS.
# Spins up a busybox container with a host directory bind-mounted and tries
# to write+unlink a probe file under `timeout`.
#
# Args (optional):
#   $1 - probe_timeout in seconds (default: KAPSIS_VFS_PROBE_TIMEOUT or 10)
#   $2 - probe_image (default: busybox:latest, overridable for tests)
#
# Env (for tests):
#   KAPSIS_VFS_PROBE_PODMAN - override the podman binary path
#   KAPSIS_VFS_PROBE_HOST_DIR - use this host dir as the probe mount source
#                              (default: mktemp -d under $TMPDIR)
#
# Returns: 0 if virtio-fs is healthy, 1 if degraded. Always 0 on Linux.
#-------------------------------------------------------------------------------
probe_virtio_fs_health() {
    if is_linux; then
        return 0
    fi

    local probe_timeout="${1:-${KAPSIS_VFS_PROBE_TIMEOUT:-${KAPSIS_DEFAULT_VFS_PROBE_TIMEOUT:-10}}}"
    local probe_image="${2:-${KAPSIS_VFS_PROBE_IMAGE:-busybox:latest}}"
    local podman_bin="${KAPSIS_VFS_PROBE_PODMAN:-podman}"

    if ! [[ "$probe_timeout" =~ ^[0-9]+$ ]] || (( probe_timeout < 1 || probe_timeout > 120 )); then
        probe_timeout=10
    fi

    local timeout_cmd
    timeout_cmd="$(_vfs_timeout_cmd)"

    # Use a caller-supplied host dir if given (tests); otherwise create a
    # throwaway directory so the probe does not pollute ~/.kapsis/status.
    local host_dir="${KAPSIS_VFS_PROBE_HOST_DIR:-}"
    local cleanup_host_dir=""
    if [[ -z "$host_dir" ]]; then
        host_dir="$(mktemp -d 2>/dev/null || mktemp -d -t kapsis-vfs-probe)"
        cleanup_host_dir="$host_dir"
    fi

    # Remove any stale sentinel from a previous probe run.
    rm -f "$host_dir/.vfs-probe" 2>/dev/null || true

    # Probe command: touch + remove a file from the container side.
    # Any success signals virtio-fs can read and write through the bind mount.
    local probe_cmd='touch /probe/.vfs-probe && rm -f /probe/.vfs-probe'
    local rc=0

    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" "$probe_timeout" "$podman_bin" run --rm \
            -v "${host_dir}:/probe" \
            "$probe_image" \
            sh -c "$probe_cmd" >/dev/null 2>&1 || rc=$?
    else
        # No timeout binary — probe may hang on severely degraded virtio-fs.
        # Document the install hint for the user.
        log_debug "No 'timeout' binary found — probe cannot bound duration (install coreutils)"
        "$podman_bin" run --rm \
            -v "${host_dir}:/probe" \
            "$probe_image" \
            sh -c "$probe_cmd" >/dev/null 2>&1 || rc=$?
    fi

    [[ -n "$cleanup_host_dir" ]] && rm -rf "$cleanup_host_dir" 2>/dev/null || true

    if [[ $rc -eq 0 ]]; then
        log_debug "Virtio-fs probe passed (${probe_timeout}s budget)"
        return 0
    fi

    log_warn "Virtio-fs probe failed (rc=$rc, timeout=${probe_timeout}s)"
    return 1
}

#-------------------------------------------------------------------------------
# count_running_kapsis_containers
#
# Counts currently-running containers launched by kapsis. Identifies them by
# the `kapsis.managed=true` label set in launch-agent.sh, not by name prefix —
# this prevents user-created containers that happen to be named `kapsis-*`
# (test harnesses, personal projects) from falsely blocking auto-heal.
#
# Env (for tests):
#   KAPSIS_VFS_PROBE_PODMAN - override the podman binary path
#
# Prints the integer count on stdout. Prints "0" on any error.
#-------------------------------------------------------------------------------
count_running_kapsis_containers() {
    local podman_bin="${KAPSIS_VFS_PROBE_PODMAN:-podman}"
    local ids
    ids="$("$podman_bin" ps --filter 'label=kapsis.managed=true' --format '{{.ID}}' 2>/dev/null || true)"
    if [[ -z "$ids" ]]; then
        echo "0"
        return 0
    fi
    # wc -l may pad output with leading whitespace; strip it.
    local count
    count="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
    echo "${count:-0}"
}

#-------------------------------------------------------------------------------
# _podman_machine_restart
#
# Stops and starts the default Podman machine with per-command timeouts.
# Returns 0 on success, non-zero on any failure.
#-------------------------------------------------------------------------------
_podman_machine_restart() {
    local podman_bin="${KAPSIS_VFS_PROBE_PODMAN:-podman}"
    local machine="${KAPSIS_PODMAN_MACHINE:-podman-machine-default}"
    local timeout_cmd
    timeout_cmd="$(_vfs_timeout_cmd)"

    log_info "Restarting Podman VM '$machine' to recover virtio-fs"
    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" 30 "$podman_bin" machine stop "$machine" &>/dev/null || true
        "$timeout_cmd" 60 "$podman_bin" machine start "$machine" &>/dev/null || return 1
    else
        "$podman_bin" machine stop "$machine" &>/dev/null || true
        "$podman_bin" machine start "$machine" &>/dev/null || return 1
    fi
    return 0
}

#-------------------------------------------------------------------------------
# maybe_autoheal_podman_vm [probe_timeout] [max_retries] [retry_delay]
#
# Probes virtio-fs health. On failure, decides whether to auto-restart the
# Podman VM:
#   - If other kapsis containers are running:     REFUSES to restart; returns 1
#                                                 with a user-facing error so
#                                                 running work is not killed.
#   - If KAPSIS_VFS_AUTOHEAL_ENABLED=false:       REFUSES to restart; returns 1.
#   - Otherwise:                                  restarts the VM and retries
#                                                 the probe up to max_retries
#                                                 times.
#
# Returns: 0 if virtio-fs is healthy (initially or after recovery),
#          1 if degraded and recovery failed or was refused.
#-------------------------------------------------------------------------------
maybe_autoheal_podman_vm() {
    if is_linux; then
        return 0
    fi

    local probe_timeout="${1:-${KAPSIS_VFS_PROBE_TIMEOUT:-${KAPSIS_DEFAULT_VFS_PROBE_TIMEOUT:-10}}}"
    local max_retries="${2:-${KAPSIS_VFS_RECOVERY_RETRIES:-${KAPSIS_DEFAULT_VFS_RECOVERY_RETRIES:-2}}}"
    local retry_delay="${3:-${KAPSIS_VFS_RECOVERY_DELAY:-${KAPSIS_DEFAULT_VFS_RECOVERY_DELAY:-3}}}"
    local autoheal="${KAPSIS_VFS_AUTOHEAL_ENABLED:-${KAPSIS_DEFAULT_VFS_AUTOHEAL_ENABLED:-true}}"

    # Clamp retries/delay to sane bounds.
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries > 5 )); then
        max_retries=2
    fi
    if ! [[ "$retry_delay" =~ ^[0-9]+$ ]] || (( retry_delay > 30 )); then
        retry_delay=3
    fi

    # Fast path: probe once.
    if probe_virtio_fs_health "$probe_timeout"; then
        return 0
    fi

    if [[ "$autoheal" != "true" ]]; then
        log_error "Virtio-fs appears degraded and auto-heal is disabled"
        log_error "  Run manually: podman machine stop && podman machine start"
        return 1
    fi

    local running
    running="$(count_running_kapsis_containers)"
    if [[ "$running" -gt 0 ]]; then
        log_error "Virtio-fs appears degraded but $running other kapsis container(s) are running"
        log_error "  Restarting the Podman VM now would kill their work."
        log_error "  Options:"
        log_error "    1. Wait for the other agents to finish, then retry"
        log_error "    2. Stop them, then run: podman machine stop && podman machine start"
        return 1
    fi

    log_warn "Virtio-fs appears degraded — auto-restarting Podman VM (no other kapsis containers running)"
    if ! _podman_machine_restart; then
        log_error "Failed to restart Podman VM — manual recovery required"
        return 1
    fi

    local i
    for (( i=1; i<=max_retries; i++ )); do
        if (( i > 1 )); then
            sleep "$retry_delay"
        fi
        if probe_virtio_fs_health "$probe_timeout"; then
            log_success "Virtio-fs recovered after VM restart (retry $i/$max_retries)"
            return 0
        fi
        log_warn "Virtio-fs probe still failing after restart (retry $i/$max_retries)"
    done

    log_error "Virtio-fs probe still failing after VM restart and $max_retries retries"
    return 1
}
