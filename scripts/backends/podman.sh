#!/usr/bin/env bash
#===============================================================================
# Kapsis Backend: Podman
#
# Implements the backend interface for local Podman container execution.
# This is the default backend — extracted from launch-agent.sh.
#
# Backend Interface:
#   backend_validate      - Check Podman is available and ready
#   backend_build_spec    - Build the podman run command (delegates to build_container_command)
#   backend_run           - Execute the container and capture output
#   backend_get_exit_code - Get the exit code from the last run
#   backend_cleanup       - Clean up temp files
#   backend_supports      - Check feature support
#===============================================================================

# Guard against multiple sourcing
if [[ -n "${_KAPSIS_BACKEND_PODMAN_LOADED:-}" ]]; then
    return 0
fi
readonly _KAPSIS_BACKEND_PODMAN_LOADED=1

# Backend state
_BACKEND_EXIT_CODE=1

#===============================================================================
# BACKEND INTERFACE FUNCTIONS
#===============================================================================

# Validate that Podman is available and ready
backend_validate() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "Skipping Podman checks (dry-run mode)"
        return 0
    fi

    log_debug "Checking Podman availability..."
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed or not in PATH"
        return 1
    fi
    log_debug "Podman found at: $(command -v podman)"

    # Check Podman machine is running (macOS only)
    if [[ "$(uname)" == "Darwin" ]]; then
        log_debug "Checking Podman machine status..."
        if ! podman machine inspect podman-machine-default &>/dev/null || \
           [[ "$(podman machine inspect podman-machine-default --format '{{.State}}')" != "running" ]]; then
            log_warn "Podman machine is not running. Attempting to start..."
            podman machine start podman-machine-default || {
                log_error "Failed to start Podman machine. Please run: podman machine start"
                return 1
            }
            log_success "Podman machine started"
        else
            log_debug "Podman machine is running"
        fi

        # Verify SSH tunnel is functional (Issue #255)
        # Machine may report "running" but SSH tunnel is dead after reboot/sleep.
        if declare -f _podman_ssh_probe &>/dev/null; then
            local probe_timeout="${KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_PROBE_TIMEOUT:-10}}"
            local max_retries="${KAPSIS_PREFLIGHT_SSH_RECOVERY_RETRIES:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_RETRIES:-2}}"
            local retry_delay="${KAPSIS_PREFLIGHT_SSH_RECOVERY_DELAY:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_DELAY:-3}}"

            log_debug "Probing Podman SSH tunnel..."
            if ! _podman_ssh_probe "$probe_timeout"; then
                log_warn "Podman SSH tunnel is stale. Attempting recovery (stop + start)..."
                podman machine stop podman-machine-default &>/dev/null || true
                podman machine start podman-machine-default &>/dev/null || true

                local i
                local recovered=false
                for (( i=1; i<=max_retries; i++ )); do
                    sleep "$retry_delay"
                    if _podman_ssh_probe "$probe_timeout"; then
                        recovered=true
                        break
                    fi
                    log_warn "SSH recovery retry $i/$max_retries failed"
                done

                if [[ "$recovered" == "true" ]]; then
                    log_success "Podman SSH tunnel recovered after restart"
                else
                    log_error "Podman SSH tunnel is broken. Run: podman machine stop && podman machine start"
                    return 1
                fi
            else
                log_debug "Podman SSH tunnel is functional"
            fi
        fi
    fi

    return 0
}

# Build the podman run command array
# Delegates to build_container_command() defined in launch-agent.sh
# Sets global: CONTAINER_CMD
backend_build_spec() {
    build_container_command
}

# Execute the container and capture output
# Arguments: $1 = output file path
backend_run() {
    local container_output="$1"

    set +e
    if command -v stdbuf &>/dev/null; then
        # Linux: use stdbuf for line-buffered output
        "${CONTAINER_CMD[@]}" 2>&1 | stdbuf -oL tee "$container_output"
    elif command -v gstdbuf &>/dev/null; then
        # macOS with coreutils: use gstdbuf
        "${CONTAINER_CMD[@]}" 2>&1 | gstdbuf -oL tee "$container_output"
    else
        # Fallback: regular tee (may buffer, but still works)
        "${CONTAINER_CMD[@]}" 2>&1 | tee "$container_output"
    fi
    # CRITICAL: PIPESTATUS must be captured immediately after pipeline
    # Any intervening command (even echo) will overwrite it
    _BACKEND_EXIT_CODE=${PIPESTATUS[0]}
    set -e
}

# Get the exit code from the last backend_run()
backend_get_exit_code() {
    echo "${_BACKEND_EXIT_CODE:-1}"
}

# Clean up backend-specific temp files
backend_cleanup() {
    [[ -n "${SECRETS_ENV_FILE:-}" && -f "$SECRETS_ENV_FILE" ]] && rm -f "$SECRETS_ENV_FILE"
    [[ -n "${INLINE_SPEC_FILE:-}" && -f "$INLINE_SPEC_FILE" ]] && rm -f "$INLINE_SPEC_FILE"
    [[ -n "${DNS_PIN_FILE:-}" && -f "$DNS_PIN_FILE" ]] && rm -f "$DNS_PIN_FILE"
    [[ -n "${RESOLV_CONF_FILE:-}" && -f "$RESOLV_CONF_FILE" ]] && rm -f "$RESOLV_CONF_FILE"
    # Clean up snapshot directory for filesystem includes (issue #164)
    [[ -n "${SNAPSHOT_DIR:-}" && -d "$SNAPSHOT_DIR" ]] && rm -rf "$SNAPSHOT_DIR"
}

# Check if this backend supports a given feature
# Returns: 0 if supported, 1 if not
backend_supports() {
    local feature="$1"
    case "$feature" in
        interactive|overlay|worktree|dns-filtering) return 0 ;;
        *) return 1 ;;
    esac
}
