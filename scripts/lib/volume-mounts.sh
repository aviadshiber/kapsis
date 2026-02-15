#!/usr/bin/env bash
#===============================================================================
# Kapsis - Volume Mount Generation
#
# Generates volume mount arrays for container launch using dispatch tables.
# Handles worktree and overlay sandbox modes with common shared mounts.
#
# Extracted from launch-agent.sh to comply with single-responsibility
# and 80-line function limits.
#
# Dependencies (must be sourced before this file):
#   - scripts/lib/logging.sh (log_debug, log_info, log_warn, log_success)
#   - scripts/lib/compat.sh (expand_path_vars, ensure_dir)
#
# Reads globals: SANDBOX_MODE, WORKTREE_PATH, SANITIZED_GIT_PATH,
#   CONTAINER_GIT_PATH, OBJECTS_PATH, CONTAINER_OBJECTS_PATH,
#   PROJECT_PATH, UPPER_DIR, WORK_DIR, AGENT_ID, DRY_RUN,
#   KAPSIS_STATUS_DIR, SPEC_FILE, FILESYSTEM_INCLUDES, SSH_VERIFY_HOSTS,
#   SNAPSHOT_DIR, STAGED_CONFIGS, SCRIPT_DIR
#
# Writes globals: VOLUME_MOUNTS[@], STAGED_CONFIGS, SSH_KNOWN_HOSTS_FILE,
#   SNAPSHOT_DIR
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_VOLUME_MOUNTS_LOADED:-}" ]] && return 0
readonly _KAPSIS_VOLUME_MOUNTS_LOADED=1

# Dispatch table for volume mount generation by sandbox mode
declare -A VOLUME_MOUNT_HANDLERS=(
    ["worktree"]="generate_volume_mounts_worktree"
    ["overlay"]="generate_volume_mounts_overlay"
)

#===============================================================================
# MAIN DISPATCHER
# Uses dispatch table to select volume mount generator
#===============================================================================
generate_volume_mounts() {
    local handler="${VOLUME_MOUNT_HANDLERS[${SANDBOX_MODE}]:-}"
    if [[ -n "$handler" ]]; then
        "$handler"
    else
        log_error "Unknown sandbox mode for volume mounts: $SANDBOX_MODE"
        exit 1
    fi
}

#===============================================================================
# WORKTREE VOLUME MOUNTS
#===============================================================================
generate_volume_mounts_worktree() {
    VOLUME_MOUNTS=()

    # Mount worktree directly (no overlay needed!)
    VOLUME_MOUNTS+=("-v" "${WORKTREE_PATH}:/workspace")

    # Mount sanitized git at $CONTAINER_GIT_PATH, replacing the worktree's .git file
    VOLUME_MOUNTS+=("-v" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro")

    # Mount objects directory read-only
    VOLUME_MOUNTS+=("-v" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro")

    # Add common mounts (status, caches, spec, filesystem includes, SSH)
    add_common_volume_mounts
}

#===============================================================================
# OVERLAY VOLUME MOUNTS (legacy)
#===============================================================================
generate_volume_mounts_overlay() {
    VOLUME_MOUNTS=()

    # Project with CoW overlay
    VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")

    # Add common mounts (status, caches, spec, filesystem includes, SSH)
    add_common_volume_mounts
}

#===============================================================================
# COMMON VOLUME MOUNTS (shared by all modes)
#===============================================================================
add_common_volume_mounts() {
    # Status reporting directory
    local status_dir="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"
    ensure_dir "$status_dir"
    VOLUME_MOUNTS+=("-v" "${status_dir}:/kapsis-status")

    # Maven repository (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-m2:/home/developer/.m2/repository")

    # Gradle cache (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-gradle:/home/developer/.gradle")

    # GE workspace (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-ge:/home/developer/.m2/.gradle-enterprise")

    # Spec file (if provided)
    if [[ -n "$SPEC_FILE" ]]; then
        SPEC_FILE_ABS="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
        VOLUME_MOUNTS+=("-v" "${SPEC_FILE_ABS}:/task-spec.md:ro")
    fi

    # Filesystem whitelist from config
    generate_filesystem_includes

    # SSH known_hosts for verified git remotes
    generate_ssh_known_hosts
    if [[ -n "$SSH_KNOWN_HOSTS_FILE" ]]; then
        VOLUME_MOUNTS+=("-v" "${SSH_KNOWN_HOSTS_FILE}:/etc/ssh/ssh_known_hosts:ro")
    fi
}

#===============================================================================
# FILESYSTEM INCLUDES
# Uses staging-and-copy pattern for home directory files:
# 1. Mount host files to /kapsis-staging/<name> (read-only)
# 2. Entrypoint copies to container $HOME (writable)
# Snapshots regular files to prevent torn reads (issue #164).
#===============================================================================
STAGED_CONFIGS=""

# _snapshot_file <host_path> <relative_name>
# Creates a point-in-time snapshot of a host file for race-free bind mounting.
# Prevents torn reads when host processes actively write to files.
# Returns: path to snapshot (or original path on failure as fallback)
_snapshot_file() {
    local host_path="$1"
    local relative_name="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$host_path"
        return 0
    fi

    local snapshot_path="${SNAPSHOT_DIR}/${relative_name}"
    mkdir -p "$(dirname "$snapshot_path")" 2>/dev/null || true

    if cp -p "$host_path" "$snapshot_path" 2>/dev/null; then
        echo "$snapshot_path"
    else
        log_warn "Snapshot failed for ${host_path}, falling back to live mount"
        echo "$host_path"
    fi
}

# _mount_staged_path <expanded_path> <original_path>
# Handles a single filesystem include entry from the config.
_mount_staged_path() {
    local expanded_path="$1"
    local path="$2"
    local staging_dir="/kapsis-staging"

    # Home directory paths: use staging-and-copy pattern
    # shellcheck disable=SC2016  # Intentional: matching literal $HOME text
    if [[ "$path" == "~"* ]] || [[ "$path" == *'$HOME'* ]] || [[ "$path" == *'${HOME}'* ]] || [[ "$expanded_path" == "$HOME"* ]]; then
        local relative_path="${expanded_path#"$HOME"/}"
        local staging_path="${staging_dir}/${relative_path}"

        # Snapshot regular files to prevent torn reads (issue #164)
        local mount_source="$expanded_path"
        if [[ -f "$expanded_path" ]]; then
            mount_source=$(_snapshot_file "$expanded_path" "$relative_path")
            log_debug "Snapshot: ${expanded_path} -> ${mount_source}"
        fi

        VOLUME_MOUNTS+=("-v" "${mount_source}:${staging_path}:ro")
        log_debug "Staged for copy: ${mount_source} -> ${staging_path}"

        if [[ -n "$STAGED_CONFIGS" ]]; then
            STAGED_CONFIGS="${STAGED_CONFIGS},${relative_path}"
        else
            STAGED_CONFIGS="${relative_path}"
        fi
    else
        # Non-home absolute paths: snapshot files, mount directly (read-only)
        local mount_source="$expanded_path"
        if [[ -f "$expanded_path" ]]; then
            mount_source=$(_snapshot_file "$expanded_path" "absolute${expanded_path}")
            log_debug "Snapshot: ${expanded_path} -> ${mount_source}"
        fi
        VOLUME_MOUNTS+=("-v" "${mount_source}:${expanded_path}:ro")
        log_debug "Direct mount (ro): ${mount_source} -> ${expanded_path}"
    fi
}

generate_filesystem_includes() {
    STAGED_CONFIGS=""

    if [[ -z "${FILESYSTEM_INCLUDES:-}" ]]; then
        return 0
    fi

    # Initialize snapshot directory in parent shell scope (issue #164)
    if [[ -z "${SNAPSHOT_DIR:-}" ]]; then
        SNAPSHOT_DIR="${HOME}/.kapsis/snapshots/${AGENT_ID}"
        if [[ "$DRY_RUN" != "true" ]]; then
            mkdir -p "$SNAPSHOT_DIR"
            log_debug "Created snapshot directory: $SNAPSHOT_DIR"
        else
            log_debug "[DRY-RUN] Would create snapshot dir: $SNAPSHOT_DIR"
        fi
    fi

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local expanded_path
        expanded_path=$(expand_path_vars "$path")

        if [[ ! -e "$expanded_path" ]]; then
            log_debug "Skipping non-existent path: ${expanded_path}"
            continue
        fi

        _mount_staged_path "$expanded_path" "$path"
    done <<< "$FILESYSTEM_INCLUDES"

    if [[ -n "$STAGED_CONFIGS" ]]; then
        log_debug "Staged configs for copy: ${STAGED_CONFIGS}"
    fi
}

#===============================================================================
# SSH KNOWN_HOSTS GENERATION
#===============================================================================
SSH_KNOWN_HOSTS_FILE=""

generate_ssh_known_hosts() {
    SSH_KNOWN_HOSTS_FILE=""

    if [[ -z "${SSH_VERIFY_HOSTS:-}" ]]; then
        log_debug "No SSH hosts to verify (ssh.verify_hosts not configured)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "[DRY-RUN] Would generate SSH known_hosts for: $SSH_VERIFY_HOSTS"
        return 0
    fi

    local ssh_keychain_script="$SCRIPT_DIR/lib/ssh-keychain.sh"
    if [[ ! -x "$ssh_keychain_script" ]]; then
        log_warn "SSH keychain script not found: $ssh_keychain_script"
        log_warn "SSH host verification skipped - container will use host's known_hosts"
        return 0
    fi

    local known_hosts_file
    known_hosts_file=$(mktemp -t kapsis-known-hosts.XXXXXX)

    log_info "Generating verified SSH known_hosts..."

    local failed_hosts=()
    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        log_debug "Verifying SSH host key: $host"
        if "$ssh_keychain_script" generate "$known_hosts_file" "$host" 2>/dev/null; then
            log_debug "  Verified: $host"
        else
            log_warn "  Failed: $host verification (run: ssh-keychain.sh add-host $host)"
            failed_hosts+=("$host")
        fi
    done <<< "$SSH_VERIFY_HOSTS"

    if [[ -s "$known_hosts_file" ]]; then
        SSH_KNOWN_HOSTS_FILE="$known_hosts_file"
        local host_count
        host_count=$(wc -l < "$known_hosts_file" | tr -d ' ')
        log_success "SSH known_hosts ready ($host_count keys verified)"
    else
        rm -f "$known_hosts_file"
        log_warn "No SSH hosts could be verified"
    fi

    if [[ ${#failed_hosts[@]} -gt 0 ]]; then
        log_warn "Failed hosts (git push may fail):"
        for host in "${failed_hosts[@]}"; do
            log_warn "  - $host (run: ./scripts/lib/ssh-keychain.sh add-host $host)"
        done
    fi
}
