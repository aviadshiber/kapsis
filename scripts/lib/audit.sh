#!/usr/bin/env bash
#===============================================================================
# Kapsis - Audit Trail Library
#
# Provides tamper-evident, hash-chained JSONL audit logging for all agent
# actions inside the sandbox. Each event is cryptographically linked to the
# previous one via SHA-256, creating an immutable chain that can be verified
# after the session.
#
# Features:
#   - Hash-chained JSONL events (tamper detection)
#   - Auto-classification of event types
#   - Per-session audit files with size-based rotation
#   - TTL-based and size-based cleanup
#   - Secret sanitization in all logged data
#   - Cross-platform (macOS + Linux)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/audit.sh"
#   audit_init "agent-abc123" "my-project" "claude-cli"
#   audit_log_event "shell_command" "Bash" '{"command":"git status"}'
#   audit_finalize 0
#
# Environment Variables:
#   KAPSIS_AUDIT_ENABLED  - Enable audit logging (true|false), default: false
#   KAPSIS_AUDIT_DIR      - Audit directory, default: ~/.kapsis/audit
#===============================================================================

# shellcheck disable=SC2034
# SC2034: Variables defined here are used by scripts that source this file

# Guard against multiple sourcing
[[ -n "${_KAPSIS_AUDIT_LOADED:-}" ]] && return 0
_KAPSIS_AUDIT_LOADED=1

# Script directory for sourcing dependencies
_AUDIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$_AUDIT_LIB_DIR/logging.sh"
fi
if [[ -z "${_KAPSIS_JSON_UTILS_LOADED:-}" ]]; then
    source "$_AUDIT_LIB_DIR/json-utils.sh"
fi
if [[ -z "${_KAPSIS_COMPAT_LOADED:-}" ]]; then
    source "$_AUDIT_LIB_DIR/compat.sh"
fi
if [[ -z "${_KAPSIS_CONSTANTS_LOADED:-}" ]]; then
    source "$_AUDIT_LIB_DIR/constants.sh"
fi

#===============================================================================
# GLOBAL STATE
#===============================================================================

# Sequence counter for events in this session
_KAPSIS_AUDIT_SEQ=0

# Previous event hash (64 zeros for genesis)
_KAPSIS_AUDIT_PREV_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# Session identifier
_KAPSIS_AUDIT_SESSION_ID=""

# Current audit file path
_KAPSIS_AUDIT_FILE=""

# Initialization flag
_KAPSIS_AUDIT_INITIALIZED="false"

# Agent metadata
_KAPSIS_AUDIT_AGENT_ID=""
_KAPSIS_AUDIT_PROJECT=""
_KAPSIS_AUDIT_AGENT_TYPE=""

#===============================================================================
# INITIALIZATION
#===============================================================================

# Initialize the audit system for a new session
# Arguments:
#   $1 - Agent ID (e.g., "abc123")
#   $2 - Project name (e.g., "my-project")
#   $3 - Agent type (e.g., "claude-cli")
audit_init() {
    local agent_id="${1:-}"
    local project="${2:-}"
    local agent_type="${3:-}"

    if [[ -z "$agent_id" ]]; then
        log_warn "audit_init called without agent_id"
        return 1
    fi

    _KAPSIS_AUDIT_AGENT_ID="$agent_id"
    _KAPSIS_AUDIT_PROJECT="$project"
    _KAPSIS_AUDIT_AGENT_TYPE="$agent_type"

    # Generate session ID: timestamp-PID
    _KAPSIS_AUDIT_SESSION_ID="$(date -u +"%Y%m%d-%H%M%S")-$$"

    # Set up audit directory
    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
    mkdir -p "$audit_dir"
    chmod 700 "$audit_dir"

    # Set audit file path
    _KAPSIS_AUDIT_FILE="${audit_dir}/${agent_id}-${_KAPSIS_AUDIT_SESSION_ID}.audit.jsonl"

    # Create file with secure permissions
    touch "$_KAPSIS_AUDIT_FILE"
    chmod 600 "$_KAPSIS_AUDIT_FILE"

    # Initialize chain state
    _KAPSIS_AUDIT_PREV_HASH="0000000000000000000000000000000000000000000000000000000000000000"
    _KAPSIS_AUDIT_SEQ=0

    # Run opportunistic cleanup (non-blocking)
    audit_cleanup

    # Write genesis event
    audit_log_event "session_start" "audit_init" '{"action":"session_start"}'

    _KAPSIS_AUDIT_INITIALIZED="true"

    log_debug "Audit initialized: $_KAPSIS_AUDIT_FILE"
}

#===============================================================================
# EVENT LOGGING
#===============================================================================

# Log an audit event with hash chaining
# Arguments:
#   $1 - Event type (session_start, session_end, shell_command, tool_use,
#                    credential_access, network_activity, git_op, filesystem_op, auto)
#   $2 - Tool name (e.g., "Bash", "Read", "Write", "Edit")
#   $3 - Detail JSON (e.g., '{"command":"git status"}')
audit_log_event() {
    local event_type="${1:-tool_use}"
    local tool_name="${2:-unknown}"
    local detail_json="${3:-"{}"}"

    # Guard: must be initialized
    if [[ "$_KAPSIS_AUDIT_INITIALIZED" != "true" && "$event_type" != "session_start" ]]; then
        return 0
    fi

    # Guard: file must exist
    if [[ -z "$_KAPSIS_AUDIT_FILE" ]]; then
        return 0
    fi

    # Auto-classify if requested
    if [[ "$event_type" == "auto" ]]; then
        local command=""
        local file_path=""
        # Extract command and file_path from detail_json for classification
        command=$(json_get_string "$detail_json" "command")
        file_path=$(json_get_string "$detail_json" "file_path")
        event_type=$(_audit_classify_event "$tool_name" "$command" "$file_path")
    fi

    # Generate timestamp
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Sanitize detail_json through secret sanitization
    local sanitized_detail
    sanitized_detail=$(sanitize_secrets "$detail_json")

    # Build hash input: prev_hash + seq + timestamp + event_type + tool_name + detail
    local hash_input="${_KAPSIS_AUDIT_PREV_HASH}${_KAPSIS_AUDIT_SEQ}${timestamp}${event_type}${tool_name}${sanitized_detail}"

    # Compute SHA-256 hash
    local hash
    hash=$(printf '%s' "$hash_input" | sha256_hash)

    # Escape all string fields for JSON
    local escaped_session_id
    escaped_session_id=$(json_escape_string "$_KAPSIS_AUDIT_SESSION_ID")
    local escaped_agent_id
    escaped_agent_id=$(json_escape_string "$_KAPSIS_AUDIT_AGENT_ID")
    local escaped_agent_type
    escaped_agent_type=$(json_escape_string "$_KAPSIS_AUDIT_AGENT_TYPE")
    local escaped_project
    escaped_project=$(json_escape_string "$_KAPSIS_AUDIT_PROJECT")
    local escaped_event_type
    escaped_event_type=$(json_escape_string "$event_type")
    local escaped_tool_name
    escaped_tool_name=$(json_escape_string "$tool_name")

    # Build JSONL line
    local jsonl_line="{\"seq\":${_KAPSIS_AUDIT_SEQ},\"timestamp\":\"${timestamp}\",\"session_id\":\"${escaped_session_id}\",\"agent_id\":\"${escaped_agent_id}\",\"agent_type\":\"${escaped_agent_type}\",\"project\":\"${escaped_project}\",\"event_type\":\"${escaped_event_type}\",\"tool_name\":\"${escaped_tool_name}\",\"detail\":${sanitized_detail},\"prev_hash\":\"${_KAPSIS_AUDIT_PREV_HASH}\",\"hash\":\"${hash}\"}"

    # Append to audit file
    echo "$jsonl_line" >> "$_KAPSIS_AUDIT_FILE"

    # Update chain state
    _KAPSIS_AUDIT_PREV_HASH="$hash"
    ((_KAPSIS_AUDIT_SEQ++)) || true

    # Check if rotation is needed
    _audit_check_rotation

    # Check patterns if pattern detection is available
    if declare -f audit_check_patterns &>/dev/null; then
        audit_check_patterns "$event_type" "$tool_name" "$sanitized_detail"
    fi
}

#===============================================================================
# CHAIN VERIFICATION
#===============================================================================

# Verify the integrity of an audit chain
# Arguments:
#   $1 - Path to audit file
# Returns:
#   0 if chain is valid, 1 if chain is broken
audit_verify_chain() {
    local audit_file="${1:-$_KAPSIS_AUDIT_FILE}"

    if [[ ! -f "$audit_file" ]]; then
        log_error "Audit file not found: $audit_file"
        return 1
    fi

    local prev_hash="0000000000000000000000000000000000000000000000000000000000000000"
    local line_num=0
    local valid=true

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((line_num++)) || true

        # Extract fields from JSON line
        local seq
        seq=$(json_get_number "$line" "seq")
        local timestamp
        timestamp=$(json_get_string "$line" "timestamp")
        local event_type
        event_type=$(json_get_string "$line" "event_type")
        local tool_name
        tool_name=$(json_get_string "$line" "tool_name")
        local stored_prev_hash
        stored_prev_hash=$(json_get_string "$line" "prev_hash")
        local stored_hash
        stored_hash=$(json_get_string "$line" "hash")

        # Extract detail as raw JSON (between "detail": and ,"prev_hash")
        local detail
        # shellcheck disable=SC2001  # sed needed for backreference capture
        detail=$(echo "$line" | sed 's/.*"detail":\(.*\),"prev_hash".*/\1/')

        # Verify prev_hash chain linkage
        if [[ "$stored_prev_hash" != "$prev_hash" ]]; then
            log_error "Audit chain broken at seq $seq (line $line_num): prev_hash mismatch"
            log_error "  Expected prev_hash: $prev_hash"
            log_error "  Found prev_hash:    $stored_prev_hash"
            valid=false
            break
        fi

        # Recompute hash and verify
        local hash_input="${stored_prev_hash}${seq}${timestamp}${event_type}${tool_name}${detail}"
        local computed_hash
        computed_hash=$(printf '%s' "$hash_input" | sha256_hash)

        if [[ "$computed_hash" != "$stored_hash" ]]; then
            log_error "Audit chain broken at seq $seq (line $line_num): hash mismatch"
            log_error "  Expected hash: $computed_hash"
            log_error "  Found hash:    $stored_hash"
            valid=false
            break
        fi

        # Advance chain
        prev_hash="$stored_hash"
    done < "$audit_file"

    if [[ "$valid" == "true" ]]; then
        log_info "Audit chain verified: $line_num events in $audit_file"
        return 0
    else
        return 1
    fi
}

#===============================================================================
# FINALIZATION
#===============================================================================

# Finalize the audit session
# Arguments:
#   $1 - Exit code
#   $2 - Error message (optional)
audit_finalize() {
    local exit_code="${1:-0}"
    local error_message="${2:-}"

    if [[ "$_KAPSIS_AUDIT_INITIALIZED" != "true" ]]; then
        return 0
    fi

    local total_events="$_KAPSIS_AUDIT_SEQ"

    # Escape error message for JSON
    local escaped_error
    escaped_error=$(json_escape_string "$error_message")

    # Write session_end event
    audit_log_event "session_end" "audit_finalize" \
        "{\"action\":\"session_end\",\"exit_code\":${exit_code},\"error_message\":\"${escaped_error}\",\"total_events\":${total_events}}"

    log_info "Audit finalized: ${_KAPSIS_AUDIT_SEQ} events written to $_KAPSIS_AUDIT_FILE"
}

#===============================================================================
# ACCESSORS
#===============================================================================

# Get the current audit file path
audit_get_file() {
    echo "$_KAPSIS_AUDIT_FILE"
}

#===============================================================================
# EVENT CLASSIFICATION
#===============================================================================

# Classify an event based on tool name, command, and file path
# Arguments:
#   $1 - Tool name
#   $2 - Command (if applicable)
#   $3 - File path (if applicable)
# Returns: The classified event type via stdout
_audit_classify_event() {
    local tool_name="${1:-}"
    local command="${2:-}"
    local file_path="${3:-}"

    # Credential access: keychain/secret patterns or sensitive file paths
    if [[ "$tool_name" =~ (keychain|secret|credential) ]] || \
       [[ "$command" =~ (keychain|secret|credential|security[[:space:]]+find) ]] || \
       [[ "$file_path" =~ \.(ssh|gnupg|aws)/ ]]; then
        echo "credential_access"
        return 0
    fi

    # Network activity: curl, wget, package install, git remote ops, docker pull
    if [[ "$command" =~ ^(curl|wget)[[:space:]] ]] || \
       [[ "$command" =~ (npm[[:space:]]+install|pip[[:space:]]+install) ]] || \
       [[ "$command" =~ (git[[:space:]]+(clone|fetch|pull|push)) ]] || \
       [[ "$command" =~ (docker[[:space:]]+pull|podman[[:space:]]+pull) ]]; then
        echo "network_activity"
        return 0
    fi

    # Git operations
    if [[ "$command" =~ git[[:space:]]+(commit|push|merge|rebase|checkout|branch|add|reset|stash) ]]; then
        echo "git_op"
        return 0
    fi

    # Filesystem operations: specific tools or file commands
    if [[ "$tool_name" =~ ^(Read|Write|Edit|Glob|Grep)$ ]] || \
       [[ "$command" =~ ^(cp|mv|rm|mkdir|chmod|chown|touch)[[:space:]] ]]; then
        echo "filesystem_op"
        return 0
    fi

    # Shell command: any Bash command not classified above
    if [[ "$tool_name" == "Bash" ]]; then
        echo "shell_command"
        return 0
    fi

    # Default: generic tool use
    echo "tool_use"
}

#===============================================================================
# FILE ROTATION
#===============================================================================

# Check if the current audit file needs rotation
_audit_check_rotation() {
    [[ -z "$_KAPSIS_AUDIT_FILE" ]] && return 0
    [[ ! -f "$_KAPSIS_AUDIT_FILE" ]] && return 0

    local max_bytes=$((KAPSIS_AUDIT_MAX_FILE_SIZE_MB * 1048576))
    local current_size
    current_size=$(get_file_size "$_KAPSIS_AUDIT_FILE")

    if [[ "$current_size" -ge "$max_bytes" ]]; then
        _audit_do_rotation
    fi
}

# Perform audit file rotation
_audit_do_rotation() {
    local base_path="$_KAPSIS_AUDIT_FILE"
    local last_hash="$_KAPSIS_AUDIT_PREV_HASH"

    # Remove oldest rotated file (.3)
    [[ -f "${base_path}.3" ]] && rm -f "${base_path}.3"

    # Shift existing rotated files
    [[ -f "${base_path}.2" ]] && mv "${base_path}.2" "${base_path}.3"
    [[ -f "${base_path}.1" ]] && mv "${base_path}.1" "${base_path}.2"

    # Rotate current to .1
    [[ -f "$base_path" ]] && mv "$base_path" "${base_path}.1"

    # Start new file with secure permissions
    touch "$base_path"
    chmod 600 "$base_path"

    # Reset seq counter
    _KAPSIS_AUDIT_SEQ=0

    # Write chain_continuation genesis event referencing last hash
    audit_log_event "chain_continuation" "audit_rotate" \
        "{\"action\":\"chain_continuation\",\"previous_file\":\"${base_path}.1\",\"continued_from_hash\":\"${last_hash}\"}"

    log_debug "Audit file rotated: ${base_path}.1"
}

#===============================================================================
# CLEANUP
#===============================================================================

# Clean up old audit files (TTL-based and size-based)
# Runs in background to avoid blocking agent startup
audit_cleanup() {
    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"

    # Only run if audit directory exists
    [[ -d "$audit_dir" ]] || return 0

    # Run cleanup in background subshell (best-effort, errors suppressed)
    (
        _audit_cleanup_ttl "$audit_dir" || true
        _audit_cleanup_size "$audit_dir" || true
    ) &
}

# Delete audit files older than TTL
# Arguments:
#   $1 - Audit directory
_audit_cleanup_ttl() {
    local audit_dir="$1"
    local ttl_days="${KAPSIS_AUDIT_TTL_DAYS:-30}"
    local now
    now=$(date +%s)
    local ttl_seconds=$((ttl_days * 86400))

    # Find and check each audit file
    # Clean audit logs, rotated files, alerts, and reports
    local file
    for file in "$audit_dir"/*.audit.jsonl \
                "$audit_dir"/*.audit.jsonl.[0-9] \
                "$audit_dir"/*-alerts.jsonl \
                "$audit_dir"/*-report.txt; do
        [[ -f "$file" ]] || continue

        local mtime
        mtime=$(get_file_mtime "$file")
        [[ -z "$mtime" ]] && continue

        local age=$((now - mtime))
        if [[ "$age" -gt "$ttl_seconds" ]]; then
            rm -f "$file" 2>/dev/null || true
        fi
    done
}

# Enforce total audit directory size cap
# Arguments:
#   $1 - Audit directory
_audit_cleanup_size() {
    local audit_dir="$1"
    local max_bytes=$((KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB * 1048576))

    # Calculate total size of audit files
    local total_size=0
    local -a files_by_age=()

    local file
    # Include audit logs, rotated files, alerts, and reports
    for file in "$audit_dir"/*.audit.jsonl \
                "$audit_dir"/*.audit.jsonl.[0-9] \
                "$audit_dir"/*-alerts.jsonl \
                "$audit_dir"/*-report.txt; do
        [[ -f "$file" ]] || continue

        local size
        size=$(get_file_size "$file")
        total_size=$((total_size + size))

        local mtime
        mtime=$(get_file_mtime "$file")
        [[ -z "$mtime" ]] && mtime=0

        files_by_age+=("${mtime}:${file}")
    done

    # If under limit, nothing to do
    [[ "$total_size" -le "$max_bytes" ]] && return 0

    # Sort by mtime (oldest first) and delete until under limit
    local sorted_files
    sorted_files=$(printf '%s\n' "${files_by_age[@]}" | sort -n)

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$total_size" -le "$max_bytes" ]] && break

        local file="${entry#*:}"

        # Never delete the current session's active file
        if [[ "$file" == "$_KAPSIS_AUDIT_FILE" ]]; then
            continue
        fi

        local size
        size=$(get_file_size "$file")
        rm -f "$file" 2>/dev/null || true
        total_size=$((total_size - size))
    done <<< "$sorted_files"
}
