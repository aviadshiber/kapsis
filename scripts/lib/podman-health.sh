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
    local result=""
    if command -v timeout &>/dev/null; then
        result="timeout"
    elif command -v gtimeout &>/dev/null; then
        result="gtimeout"
    fi
    # Cache result so subsequent calls skip the command -v fork.
    _KAPSIS_TIMEOUT_CMD="$result"
    export _KAPSIS_TIMEOUT_CMD
    printf '%s' "$result"
}

#-------------------------------------------------------------------------------
# probe_virtio_fs_health [probe_timeout] [probe_image]
#
# Verifies that the virtio-fs bind-mount transport is functional on macOS.
# Spins up a minimal container (kapsis-sandbox if cached, busybox otherwise)
# with a host directory bind-mounted and tries to write+unlink a probe file
# under `timeout`. The image entrypoint is bypassed via --entrypoint sh so
# the probe does not depend on Kapsis runtime setup (dnsmasq, capabilities).
#
# Args (optional):
#   $1 - probe_timeout in seconds (default: KAPSIS_VFS_PROBE_TIMEOUT or 10)
#   $2 - probe_image (override; default: KAPSIS_VFS_PROBE_IMAGE or the
#        kapsis-sandbox image, or busybox:latest as a last resort)
#
# Env (for tests):
#   KAPSIS_VFS_PROBE_PODMAN - override the podman binary path
#   KAPSIS_VFS_PROBE_HOST_DIR - use this host dir as the probe mount source
#                              (default: mktemp -d under $TMPDIR)
#   KAPSIS_VFS_PROBE_IMAGE - override the probe image
#   KAPSIS_VFS_PROBE_SKIP_IF_MISSING - set to "false" to force a pull when
#                              the image isn't cached (default: "true", i.e.
#                              skip the probe rather than race a network pull
#                              against a potentially-degraded VM)
#
# Returns: 0 if virtio-fs is healthy OR the probe had to be skipped, 1 if
# the probe ran and the mount is degraded. Always 0 on Linux.
#-------------------------------------------------------------------------------
probe_virtio_fs_health() {
    if is_linux; then
        return 0
    fi

    local probe_timeout="${1:-${KAPSIS_VFS_PROBE_TIMEOUT:-${KAPSIS_DEFAULT_VFS_PROBE_TIMEOUT:-10}}}"
    # Default image resolution order (PR #280 review follow-up):
    #   1. explicit $2 argument
    #   2. KAPSIS_VFS_PROBE_IMAGE env var
    #   3. the kapsis-sandbox image, if already cached — always present on a
    #      host that has launched at least one agent, so no extra pull cost
    #   4. busybox:latest as a last resort (may need a pull on cold VMs)
    local probe_image="${2:-${KAPSIS_VFS_PROBE_IMAGE:-}}"
    local podman_bin="${KAPSIS_VFS_PROBE_PODMAN:-podman}"

    if [[ -z "$probe_image" ]]; then
        if "$podman_bin" image exists kapsis-sandbox:latest 2>/dev/null; then
            probe_image="kapsis-sandbox:latest"
        else
            probe_image="busybox:latest"
        fi
    fi

    if ! [[ "$probe_timeout" =~ ^[0-9]+$ ]] || (( probe_timeout < 1 || probe_timeout > 120 )); then
        probe_timeout=10
    fi

    local timeout_cmd
    timeout_cmd="$(_vfs_timeout_cmd)"

    # Image-availability gate (PR #280 review follow-up): on a cold VM,
    # `podman run <image>` will try to pull. If the VM is also degraded —
    # the very condition we're probing for — the pull may succeed while the
    # bind-mount write fails, or fail with a network error indistinguishable
    # from an fs error. Decouple by pre-checking the image and, by default,
    # skipping the probe rather than racing a pull.
    if ! "$podman_bin" image exists "$probe_image" 2>/dev/null; then
        if [[ "${KAPSIS_VFS_PROBE_SKIP_IF_MISSING:-true}" == "true" ]]; then
            log_debug "Virtio-fs probe skipped: image $probe_image not cached locally"
            return 0
        fi
        log_debug "Pulling probe image $probe_image (KAPSIS_VFS_PROBE_SKIP_IF_MISSING=false)"
        local pull_rc=0
        if [[ -n "$timeout_cmd" ]]; then
            "$timeout_cmd" "$probe_timeout" "$podman_bin" pull "$probe_image" &>/dev/null || pull_rc=$?
        else
            "$podman_bin" pull "$probe_image" &>/dev/null || pull_rc=$?
        fi
        if [[ $pull_rc -ne 0 ]]; then
            log_warn "Virtio-fs probe: failed to pull $probe_image (rc=$pull_rc) — skipping probe"
            return 0
        fi
    fi

    # Use a caller-supplied host dir if given (tests); otherwise create a
    # throwaway directory so the probe does not pollute ~/.kapsis/status.
    local host_dir="${KAPSIS_VFS_PROBE_HOST_DIR:-}"
    local cleanup_host_dir=""
    if [[ -z "$host_dir" ]]; then
        host_dir="$(mktemp -d 2>/dev/null || mktemp -d -t kapsis-vfs-probe)"
        chmod 0700 "$host_dir" 2>/dev/null || true
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
            --cap-drop=ALL --security-opt=no-new-privileges \
            --read-only --network=none \
            --entrypoint sh \
            -v "${host_dir}:/probe" \
            "$probe_image" \
            -c "$probe_cmd" >/dev/null 2>&1 || rc=$?
    else
        # No timeout binary — probe may hang on severely degraded virtio-fs.
        # Document the install hint for the user.
        log_debug "No 'timeout' binary found — probe cannot bound duration (install coreutils)"
        "$podman_bin" run --rm \
            --cap-drop=ALL --security-opt=no-new-privileges \
            --read-only --network=none \
            --entrypoint sh \
            -v "${host_dir}:/probe" \
            "$probe_image" \
            -c "$probe_cmd" >/dev/null 2>&1 || rc=$?
    fi

    if [[ -n "$cleanup_host_dir" ]]; then rm -rf "$cleanup_host_dir" 2>/dev/null || true; fi

    if [[ $rc -eq 0 ]]; then
        log_debug "Virtio-fs probe passed (${probe_timeout}s budget, image=$probe_image)"
        return 0
    fi

    log_warn "Virtio-fs probe failed (rc=$rc, timeout=${probe_timeout}s, image=$probe_image)"
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
    # printf '%s\n' adds exactly one trailing newline; wc -l therefore counts
    # all lines correctly. (Command substitution already stripped the trailing
    # newline from podman output, so '%s' would undercount the last line.)
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
    # Validate machine name to prevent command injection via crafted env var.
    if ! [[ "$machine" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "_podman_machine_restart: invalid KAPSIS_PODMAN_MACHINE value '$machine' — refusing auto-heal"
        return 1
    fi
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

    # Give virtio-fs time to initialise after VM start before the first probe.
    # `podman machine start` can return before the virtiofs transport is fully ready.
    sleep 2

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
