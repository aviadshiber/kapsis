#!/usr/bin/env bash
#===============================================================================
# Kapsis - Audit Pattern Detection Library
#
# Lightweight in-process pattern detection that runs inline in the audit hook.
# Uses bash arrays as a ring buffer (window of last 20 events) to detect
# suspicious behavioral patterns in real-time.
#
# Detected Patterns:
#   - credential_exfiltration: credential_access + network_activity within 30s
#   - mass_deletion: 5+ rm/delete operations in window
#   - sensitive_path_access: access to .ssh/, .gnupg/, .aws/, etc.
#   - unusual_commands: base64 -d, curl|sh, nc -l, python -c socket, etc.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/audit-patterns.sh"
#   # Called automatically by audit_log_event when available:
#   audit_check_patterns "shell_command" "Bash" '{"command":"rm -rf /"}'
#
# Dependencies:
#   - scripts/lib/json-utils.sh (json_escape_string, json_get_string)
#   - scripts/lib/logging.sh (log_warn, log_debug)
#   - Globals from audit.sh: _KAPSIS_AUDIT_AGENT_ID, _KAPSIS_AUDIT_SESSION_ID,
#                             _KAPSIS_AUDIT_SEQ
#===============================================================================

# shellcheck disable=SC2034
# SC2034: Variables defined here are used by scripts that source this file

# Guard against multiple sourcing
[[ -n "${_KAPSIS_AUDIT_PATTERNS_LOADED:-}" ]] && return 0
_KAPSIS_AUDIT_PATTERNS_LOADED=1

# Script directory for sourcing dependencies
_AUDIT_PATTERNS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
if [[ -z "${_KAPSIS_JSON_UTILS_LOADED:-}" ]]; then
    source "$_AUDIT_PATTERNS_LIB_DIR/json-utils.sh"
fi
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$_AUDIT_PATTERNS_LIB_DIR/logging.sh"
fi

#===============================================================================
# RING BUFFER STATE
#===============================================================================

declare -a _AUDIT_RECENT_TYPES=()       # event types
declare -a _AUDIT_RECENT_TOOLS=()       # tool names
declare -a _AUDIT_RECENT_COMMANDS=()    # commands
declare -a _AUDIT_RECENT_FILES=()       # file paths
declare -a _AUDIT_RECENT_TIMESTAMPS=()  # timestamps (epoch seconds)
_AUDIT_WINDOW_SIZE=20
_AUDIT_ALERT_COUNT=0

#===============================================================================
# PACKAGE MANAGER ALLOWLIST
#===============================================================================

# Network activity from standard package managers is excluded from
# credential_exfiltration detection (these legitimately access the network).
_AUDIT_PACKAGE_MANAGERS="npm|pip|pip3|maven|mvn|gradle|gradlew|cargo|go|yarn|pnpm|gem|composer|nuget"

#===============================================================================
# MAIN ENTRY POINT
#===============================================================================

# Check all patterns against the current event.
# Adds the event to the ring buffer and runs all pattern checks.
#
# Can be called with 3 args (from audit.sh) or 5 args (direct):
#   3-arg form: audit_check_patterns event_type tool_name detail_json
#   5-arg form: audit_check_patterns event_type tool_name command file_path timestamp
#
# Arguments:
#   $1 - Event type (shell_command, credential_access, network_activity, etc.)
#   $2 - Tool name (Bash, Read, Write, Edit, etc.)
#   $3 - Command string OR detail JSON (if only 3 args)
#   $4 - File path (if 5 args)
#   $5 - Timestamp (if 5 args)
# Returns:
#   0 if an alert was triggered, 1 if clean
audit_check_patterns() {
    local event_type="${1:-}"
    local tool_name="${2:-}"
    local command=""
    local file_path=""
    local timestamp=""

    if [[ $# -ge 5 ]]; then
        # 5-arg form: direct values
        command="${3:-}"
        file_path="${4:-}"
        timestamp="${5:-}"
    else
        # 3-arg form: extract from detail JSON
        local detail_json="${3:-"{}"}"
        command=$(json_get_string "$detail_json" "command")
        file_path=$(json_get_string "$detail_json" "file_path")
        timestamp=$(date +%s)
    fi

    # Default timestamp to now if empty
    if [[ -z "$timestamp" ]]; then
        timestamp=$(date +%s)
    fi

    # Add event to ring buffer
    _audit_buffer_add "$event_type" "$tool_name" "$command" "$file_path" "$timestamp"

    # Run all pattern checks
    local alert_triggered=1

    if _pattern_sensitive_path_access "$file_path"; then
        alert_triggered=0
    fi

    if _pattern_unusual_commands "$command"; then
        alert_triggered=0
    fi

    if _pattern_credential_exfiltration; then
        alert_triggered=0
    fi

    if _pattern_mass_deletion; then
        alert_triggered=0
    fi

    return "$alert_triggered"
}

#===============================================================================
# RING BUFFER MANAGEMENT
#===============================================================================

# Add an event to the ring buffer, evicting the oldest if at capacity.
# Arguments:
#   $1 - Event type
#   $2 - Tool name
#   $3 - Command
#   $4 - File path
#   $5 - Timestamp
_audit_buffer_add() {
    local event_type="$1"
    local tool_name="$2"
    local command="$3"
    local file_path="$4"
    local timestamp="$5"

    # If buffer is full, remove the oldest entry (index 0)
    if [[ ${#_AUDIT_RECENT_TYPES[@]} -ge $_AUDIT_WINDOW_SIZE ]]; then
        _AUDIT_RECENT_TYPES=("${_AUDIT_RECENT_TYPES[@]:1}")
        _AUDIT_RECENT_TOOLS=("${_AUDIT_RECENT_TOOLS[@]:1}")
        _AUDIT_RECENT_COMMANDS=("${_AUDIT_RECENT_COMMANDS[@]:1}")
        _AUDIT_RECENT_FILES=("${_AUDIT_RECENT_FILES[@]:1}")
        _AUDIT_RECENT_TIMESTAMPS=("${_AUDIT_RECENT_TIMESTAMPS[@]:1}")
    fi

    # Append the new event
    _AUDIT_RECENT_TYPES+=("$event_type")
    _AUDIT_RECENT_TOOLS+=("$tool_name")
    _AUDIT_RECENT_COMMANDS+=("$command")
    _AUDIT_RECENT_FILES+=("$file_path")
    _AUDIT_RECENT_TIMESTAMPS+=("$timestamp")
}

#===============================================================================
# PATTERN: CREDENTIAL EXFILTRATION
#===============================================================================

# Checks if the ring buffer contains both credential_access and network_activity
# within 30 seconds of each other. Excludes standard package managers from the
# network side (npm, pip, maven, gradle, cargo, go).
#
# Returns: 0 if alert triggered, 1 if clean
_pattern_credential_exfiltration() {
    local cred_timestamp=""
    local cred_index=""
    local net_timestamp=""
    local net_index=""

    local i
    for i in "${!_AUDIT_RECENT_TYPES[@]}"; do
        local etype="${_AUDIT_RECENT_TYPES[$i]}"
        local ts="${_AUDIT_RECENT_TIMESTAMPS[$i]}"
        local cmd="${_AUDIT_RECENT_COMMANDS[$i]}"

        if [[ "$etype" == "credential_access" ]]; then
            cred_timestamp="$ts"
            cred_index="$i"
        fi

        if [[ "$etype" == "network_activity" ]]; then
            # Exclude standard package managers
            if [[ "$cmd" =~ ^(${_AUDIT_PACKAGE_MANAGERS})[[:space:]] ]]; then
                continue
            fi
            net_timestamp="$ts"
            net_index="$i"
        fi
    done

    # Need both events
    if [[ -z "$cred_timestamp" || -z "$net_timestamp" ]]; then
        return 1
    fi

    # Check if within 30 seconds of each other
    local delta
    if [[ "$cred_timestamp" -gt "$net_timestamp" ]]; then
        delta=$((cred_timestamp - net_timestamp))
    else
        delta=$((net_timestamp - cred_timestamp))
    fi

    if [[ "$delta" -le 30 ]]; then
        _audit_alert "credential_exfiltration" "HIGH" \
            "Credential access followed by network activity within ${delta}s" \
            "$cred_index" "$net_index"
        return 0
    fi

    return 1
}

#===============================================================================
# PATTERN: MASS DELETION
#===============================================================================

# Counts rm -rf, rm -r, find -delete, and shred operations in the ring buffer.
# Triggers on 5 or more. Excludes single-file rm (without -r/-rf) and
# rm of files in /tmp.
#
# Returns: 0 if alert triggered, 1 if clean
_pattern_mass_deletion() {
    local delete_count=0
    local trigger_indices=""

    local i
    for i in "${!_AUDIT_RECENT_COMMANDS[@]}"; do
        local cmd="${_AUDIT_RECENT_COMMANDS[$i]}"
        local file="${_AUDIT_RECENT_FILES[$i]}"

        [[ -z "$cmd" ]] && continue

        # Skip rm of files in /tmp
        if [[ "$cmd" =~ ^rm[[:space:]] && "$file" =~ ^/tmp/ ]]; then
            continue
        fi

        # Match destructive deletion commands
        if [[ "$cmd" =~ rm[[:space:]]+-[^[:space:]]*r ]] || \
           [[ "$cmd" =~ rm[[:space:]]+-rf[[:space:]] ]] || \
           [[ "$cmd" =~ find[[:space:]].*-delete ]] || \
           [[ "$cmd" =~ shred[[:space:]] ]]; then
            ((delete_count++)) || true
            if [[ -n "$trigger_indices" ]]; then
                trigger_indices="${trigger_indices},${i}"
            else
                trigger_indices="$i"
            fi
        fi
    done

    if [[ "$delete_count" -ge 5 ]]; then
        _audit_alert "mass_deletion" "MEDIUM" \
            "${delete_count} destructive delete operations detected in recent window" \
            "$trigger_indices"
        return 0
    fi

    return 1
}

#===============================================================================
# PATTERN: SENSITIVE PATH ACCESS
#===============================================================================

# Checks if file_path matches sensitive paths. This is an immediate check
# (no window needed) — any single access triggers the alert.
#
# Sensitive paths: .ssh/, .gnupg/, .aws/, .kube/, /etc/passwd, /etc/shadow
#
# Arguments:
#   $1 - File path to check
# Returns: 0 if alert triggered, 1 if clean
_pattern_sensitive_path_access() {
    local file_path="${1:-}"

    [[ -z "$file_path" ]] && return 1

    if [[ "$file_path" =~ \.ssh/ ]] || \
       [[ "$file_path" =~ \.gnupg/ ]] || \
       [[ "$file_path" =~ \.aws/ ]] || \
       [[ "$file_path" =~ \.kube/ ]] || \
       [[ "$file_path" == "/etc/passwd" ]] || \
       [[ "$file_path" == "/etc/shadow" ]]; then
        local last_idx=$((${#_AUDIT_RECENT_TYPES[@]} - 1))
        _audit_alert "sensitive_path_access" "HIGH" \
            "Access to sensitive path: ${file_path}" \
            "$last_idx"
        return 0
    fi

    return 1
}

#===============================================================================
# PATTERN: UNUSUAL COMMANDS
#===============================================================================

# Matches commands against known suspicious patterns. This is an immediate check
# (no window needed) — any single match triggers the alert.
#
# Suspicious patterns:
#   - base64 -d (decoding obfuscated payloads)
#   - curl ... | sh/bash (remote code execution)
#   - curl -v / --verbose (auth header exposure in output)
#   - nc -l / ncat (network listeners)
#   - python/python3 -c ...socket (reverse shells)
#   - eval ...base64 (obfuscated eval)
#
# Arguments:
#   $1 - Command string to check
# Returns: 0 if alert triggered, 1 if clean
_pattern_unusual_commands() {
    local command="${1:-}"

    [[ -z "$command" ]] && return 1

    local pattern_desc=""

    if [[ "$command" =~ base64[[:space:]]+-d ]] || \
       [[ "$command" =~ base64[[:space:]]+--decode ]]; then
        pattern_desc="base64 decode"
    elif [[ "$command" =~ curl.*\|.*sh ]] || \
         [[ "$command" =~ curl.*\|.*bash ]]; then
        pattern_desc="curl piped to shell"
    # Note: this must come AFTER the curl|sh/bash check above so pipe-to-shell
    # (higher severity) takes priority when both patterns match (e.g., curl -v ... | bash)
    # Matches: curl -v, curl --verbose, curl -sv, curl -kv, curl -vsSL, etc.
    elif [[ "$command" =~ curl[[:space:]].*(-v([[:space:]]|$)|--verbose) ]] || \
         [[ "$command" =~ curl[[:space:]]+-[a-zA-Z]*v([[:space:]]|$) ]] || \
         [[ "$command" =~ curl[[:space:]].*[[:space:]]-[a-zA-Z]*v([[:space:]]|$) ]]; then
        pattern_desc="verbose curl (may expose Authorization headers in output)"
    elif [[ "$command" =~ nc[[:space:]]+-l ]] || \
         [[ "$command" =~ ncat[[:space:]] ]]; then
        pattern_desc="network listener (nc/ncat)"
    elif [[ "$command" =~ python3?[[:space:]]+-c.*socket ]]; then
        pattern_desc="python socket command"
    elif [[ "$command" =~ eval.*base64 ]]; then
        pattern_desc="eval with base64"
    fi

    if [[ -n "$pattern_desc" ]]; then
        local last_idx=$((${#_AUDIT_RECENT_TYPES[@]} - 1))
        _audit_alert "unusual_commands" "CRITICAL" \
            "Suspicious command detected (${pattern_desc}): ${command}" \
            "$last_idx"
        return 0
    fi

    return 1
}

#===============================================================================
# ALERT OUTPUT
#===============================================================================

# Write an alert JSONL line to the agent's alert file.
#
# Arguments:
#   $1 - Pattern name (credential_exfiltration, mass_deletion, etc.)
#   $2 - Severity (CRITICAL, HIGH, MEDIUM, LOW)
#   $3 - Description
#   $4 - Trigger event indices (comma-separated)
#   $5 - Additional trigger index (optional, for 2-event patterns)
_audit_alert() {
    local pattern_name="$1"
    local severity="$2"
    local description="$3"
    local trigger_indices="$4"
    local trigger_index_2="${5:-}"

    # Build trigger_events array string
    local trigger_events_json
    if [[ -n "$trigger_index_2" ]]; then
        trigger_events_json="[${trigger_indices},${trigger_index_2}]"
    else
        trigger_events_json="[${trigger_indices}]"
    fi

    # Determine alert file path
    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
    local agent_id="${_KAPSIS_AUDIT_AGENT_ID:-unknown}"
    local alert_file="${audit_dir}/${agent_id}-alerts.jsonl"

    # Ensure directory exists
    mkdir -p "$audit_dir"

    # Generate timestamp
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Escape string fields
    local escaped_agent_id
    escaped_agent_id=$(json_escape_string "$agent_id")
    local escaped_session_id
    escaped_session_id=$(json_escape_string "${_KAPSIS_AUDIT_SESSION_ID:-}")
    local escaped_pattern
    escaped_pattern=$(json_escape_string "$pattern_name")
    local escaped_severity
    escaped_severity=$(json_escape_string "$severity")
    local escaped_description
    escaped_description=$(json_escape_string "$description")

    # Build JSONL line
    local jsonl_line
    jsonl_line="{\"timestamp\":\"${timestamp}\",\"agent_id\":\"${escaped_agent_id}\",\"session_id\":\"${escaped_session_id}\",\"pattern\":\"${escaped_pattern}\",\"severity\":\"${escaped_severity}\",\"description\":\"${escaped_description}\",\"trigger_events\":${trigger_events_json}}"

    # Append to alert file
    echo "$jsonl_line" >> "$alert_file"

    # Increment alert counter
    ((_AUDIT_ALERT_COUNT++)) || true

    # Log the alert
    log_warn "AUDIT ALERT [${severity}] ${pattern_name}: ${description}"
}
