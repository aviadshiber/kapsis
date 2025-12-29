#!/usr/bin/env bash
#===============================================================================
# Kapsis Stop Hook - Agent Completion Hook
#
# This hook is called when an AI agent completes its execution (successfully
# or with an error). It updates the Kapsis status to reflect completion.
#
# Supported agents:
# - Claude Code: Stop hook
# - Codex CLI: completion hook
# - Gemini CLI: completion event
#
# Usage:
#   This script is called automatically by the agent's hook system.
#   It reads JSON from stdin and outputs JSON to stdout.
#===============================================================================

set -euo pipefail

# Configuration
KAPSIS_HOME="${KAPSIS_HOME:-/opt/kapsis}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate agent_id format (defense-in-depth for file path safety)
_validate_agent_id() {
    local agent_id="$1"
    [[ "$agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Validate agent_id - skip status tracking if invalid or missing
_safe_agent_id="${KAPSIS_STATUS_AGENT_ID:-}"
if [[ -z "$_safe_agent_id" ]]; then
    # No agent_id set - status tracking disabled, output empty JSON and exit
    echo "{}"
    exit 0
fi
if ! _validate_agent_id "$_safe_agent_id"; then
    echo "[KAPSIS-STOP] Error: Invalid agent_id format '$_safe_agent_id' - skipping status update" >&2
    echo "{}"
    exit 0
fi

# Source dependencies
if [[ -f "$KAPSIS_HOME/lib/status.sh" ]]; then
    source "$KAPSIS_HOME/lib/status.sh"
elif [[ -f "$SCRIPT_DIR/../lib/status.sh" ]]; then
    source "$SCRIPT_DIR/../lib/status.sh"
fi

#===============================================================================
# Logging Functions
#===============================================================================

log_debug() {
    [[ -n "${KAPSIS_DEBUG:-}" ]] && echo "[KAPSIS-STOP] DEBUG: $*" >&2
}

log_info() {
    echo "[KAPSIS-STOP] $*" >&2
}

#===============================================================================
# JSON Parsing
#===============================================================================

json_get() {
    local json="$1"
    local field="$2"
    local default="${3:-}"

    local value
    value=$(echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('$field', ''))
except:
    print('')
" 2>/dev/null) || value="$default"

    echo "${value:-$default}"
}

#===============================================================================
# Main Function
#===============================================================================

main() {
    # Read input from stdin (may be empty for some agents)
    local input
    input=$(cat) || input="{}"

    log_debug "Received stop event: ${input:0:200}..."

    # Detect agent type
    local agent_type="${KAPSIS_AGENT_TYPE:-claude-cli}"

    # Extract completion status if available
    local exit_code=""
    local error_message=""

    case "$agent_type" in
        claude|claude-cli)
            # Claude may include stop_reason
            local stop_reason
            stop_reason=$(json_get "$input" "stop_reason" "")
            if [[ "$stop_reason" == "error" ]]; then
                exit_code="1"
                error_message=$(json_get "$input" "error" "Agent stopped with error")
            fi
            ;;
        codex|codex-cli)
            exit_code=$(json_get "$input" "exit_code" "")
            error_message=$(json_get "$input" "error" "")
            ;;
        gemini|gemini-cli)
            local status
            status=$(json_get "$input" "status" "")
            if [[ "$status" == "error" || "$status" == "failed" ]]; then
                exit_code="1"
                error_message=$(json_get "$input" "error" "Agent failed")
            fi
            ;;
    esac

    # Update Kapsis status to "Agent completed execution"
    # The actual complete status will be set by post-container-git.sh after git operations
    if [[ -n "${KAPSIS_STATUS_PROJECT:-}" && -n "${KAPSIS_STATUS_AGENT_ID:-}" ]]; then
        if type status_reinit_from_env &>/dev/null; then
            status_reinit_from_env

            if [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
                status_phase "running" 85 "Agent completed with errors"
                log_info "Agent completed with error: $error_message"
            else
                status_phase "running" 85 "Agent completed execution"
                log_info "Agent completed successfully"
            fi
        fi
    fi

    # Cleanup state file
    local state_file="/tmp/kapsis-hook-state-${_safe_agent_id}.json"
    [[ -f "$state_file" ]] && rm -f "$state_file"

    # Output empty JSON (required by hook system)
    echo "{}"
}

# Run main function
main "$@"
