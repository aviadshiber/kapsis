#!/usr/bin/env bash
#===============================================================================
# Kapsis Status Hook - Universal PostToolUse Hook for AI Agents
#
# This hook receives tool execution events from AI coding agents (Claude Code,
# Codex CLI, Gemini CLI) and updates the Kapsis status file with progress.
#
# Supported agents:
# - Claude Code: Receives JSON via stdin with tool_name, tool_input, tool_result
# - Codex CLI: Receives JSON via stdin with exec command and result
# - Gemini CLI: Receives JSON via stdin with tool_call information
#
# Usage:
#   This script is called automatically by the agent's hook system.
#   It reads JSON from stdin and outputs JSON to stdout.
#
# Environment Variables:
#   KAPSIS_AGENT_TYPE     - Agent type (claude-cli, codex-cli, gemini-cli)
#   KAPSIS_STATUS_PROJECT - Project name for status file
#   KAPSIS_STATUS_AGENT_ID - Agent ID for status file
#   KAPSIS_HOME           - Kapsis installation directory (default: /opt/kapsis)
#   KAPSIS_DEBUG          - Enable debug logging
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
    echo "[KAPSIS-HOOK] Error: Invalid agent_id format '$_safe_agent_id' - skipping status update" >&2
    echo "{}"
    exit 0
fi

STATE_FILE="/tmp/kapsis-hook-state-${_safe_agent_id}.json"

# Source dependencies
if [[ -f "$KAPSIS_HOME/lib/status.sh" ]]; then
    source "$KAPSIS_HOME/lib/status.sh"
elif [[ -f "$SCRIPT_DIR/../lib/status.sh" ]]; then
    source "$SCRIPT_DIR/../lib/status.sh"
fi

if [[ -f "$SCRIPT_DIR/tool-phase-mapping.sh" ]]; then
    source "$SCRIPT_DIR/tool-phase-mapping.sh"
fi

#===============================================================================
# Logging Functions
#===============================================================================

log_debug() {
    [[ -n "${KAPSIS_DEBUG:-}" ]] && echo "[KAPSIS-HOOK] DEBUG: $*" >&2
}

log_info() {
    echo "[KAPSIS-HOOK] $*" >&2
}

log_error() {
    echo "[KAPSIS-HOOK] ERROR: $*" >&2
}

#===============================================================================
# JSON Parsing Functions
#===============================================================================

# Extract a field from JSON using python3 (always available in container)
json_get() {
    local json="$1"
    local field="$2"
    local default="${3:-}"

    local value
    value=$(echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    # Handle nested fields like 'tool_input.command'
    keys = '$field'.split('.')
    result = data
    for key in keys:
        if isinstance(result, dict):
            result = result.get(key, '')
        else:
            result = ''
            break
    print(result if result is not None else '')
except Exception as e:
    print('')
" 2>/dev/null) || value="$default"

    echo "${value:-$default}"
}

#===============================================================================
# State Management
#===============================================================================

# Initialize or load hook state (tool counts, last update time)
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{
            "tool_counts": {
                "exploring": 0,
                "implementing": 0,
                "building": 0,
                "testing": 0,
                "other": 0
            },
            "last_tool": "",
            "last_update": ""
        }'
    fi
}

save_state() {
    local state="$1"
    echo "$state" > "$STATE_FILE"
}

# Update tool counts in state
increment_tool_count() {
    local state="$1"
    local category="$2"

    echo "$state" | python3 -c "
import json, sys
state = json.load(sys.stdin)
category = '$category'
if category in state.get('tool_counts', {}):
    state['tool_counts'][category] = state['tool_counts'].get(category, 0) + 1
else:
    state['tool_counts']['other'] = state['tool_counts'].get('other', 0) + 1
print(json.dumps(state))
" 2>/dev/null
}

#===============================================================================
# Agent Adapters
#===============================================================================

# Parse Claude Code hook input
parse_claude_input() {
    local input="$1"

    local tool_name
    tool_name=$(json_get "$input" "tool_name" "unknown")

    # Extract command for Bash tool
    local command=""
    if [[ "$tool_name" == "Bash" ]]; then
        command=$(json_get "$input" "tool_input.command" "")
    fi

    # Extract file path for file tools
    local file_path=""
    if [[ "$tool_name" =~ ^(Read|Edit|Write|Glob|Grep)$ ]]; then
        file_path=$(json_get "$input" "tool_input.file_path" "")
        [[ -z "$file_path" ]] && file_path=$(json_get "$input" "tool_input.path" "")
    fi

    echo "{\"tool_name\": \"$tool_name\", \"command\": \"$command\", \"file_path\": \"$file_path\"}"
}

# Parse Codex CLI hook input
parse_codex_input() {
    local input="$1"

    local tool_name="exec"
    local command
    command=$(json_get "$input" "command" "")
    [[ -z "$command" ]] && command=$(json_get "$input" "exec.command" "")

    echo "{\"tool_name\": \"$tool_name\", \"command\": \"$command\", \"file_path\": \"\"}"
}

# Parse Gemini CLI hook input
parse_gemini_input() {
    local input="$1"

    local tool_name
    tool_name=$(json_get "$input" "function_call.name" "")
    [[ -z "$tool_name" ]] && tool_name=$(json_get "$input" "tool_call.name" "unknown")

    local command=""
    local file_path=""

    # Map Gemini tool names to common patterns
    case "$tool_name" in
        execute_code|run_command)
            tool_name="Bash"
            command=$(json_get "$input" "function_call.args.code" "")
            [[ -z "$command" ]] && command=$(json_get "$input" "function_call.args.command" "")
            ;;
        read_file|view_file)
            tool_name="Read"
            file_path=$(json_get "$input" "function_call.args.path" "")
            ;;
        write_file|edit_file)
            tool_name="Edit"
            file_path=$(json_get "$input" "function_call.args.path" "")
            ;;
        search_files)
            tool_name="Grep"
            ;;
    esac

    echo "{\"tool_name\": \"$tool_name\", \"command\": \"$command\", \"file_path\": \"$file_path\"}"
}

#===============================================================================
# Progress Calculation
#===============================================================================

# Calculate progress based on tool activity
calculate_progress() {
    local state="$1"

    # Base progress (25%) + activity-based progress (up to 65%)
    local base_progress=25
    local max_progress=90

    # Get tool counts
    local exploring implementing building testing other
    exploring=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_counts',{}).get('exploring',0))" 2>/dev/null || echo 0)
    implementing=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_counts',{}).get('implementing',0))" 2>/dev/null || echo 0)
    building=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_counts',{}).get('building',0))" 2>/dev/null || echo 0)
    testing=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_counts',{}).get('testing',0))" 2>/dev/null || echo 0)
    other=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_counts',{}).get('other',0))" 2>/dev/null || echo 0)

    # Calculate activity score (weighted by importance)
    local activity_score
    activity_score=$(( exploring * 2 + implementing * 5 + building * 8 + testing * 10 + other * 1 ))

    # Cap activity contribution at 65%
    local activity_progress
    (( activity_score > 65 )) && activity_score=65
    activity_progress=$activity_score

    # Calculate final progress
    local progress
    progress=$(( base_progress + activity_progress ))
    (( progress > max_progress )) && progress=$max_progress

    echo "$progress"
}

#===============================================================================
# Decision Logging
#===============================================================================

# Log major decisions (new file creation, significant refactors)
log_decision() {
    local tool_name="$1"
    local description="$2"
    local file_path="${3:-}"

    local decisions_file="/kapsis-status/decisions-${_safe_agent_id}.json"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine if this is a major decision
    local is_major=false
    local decision_type=""

    case "$tool_name" in
        Write)
            is_major=true
            decision_type="file_creation"
            ;;
        Edit)
            # Major if significant file types
            if [[ "$file_path" =~ \.(java|py|go|ts|js|rs)$ ]]; then
                is_major=true
                decision_type="code_modification"
            fi
            ;;
        Bash)
            if [[ "$description" =~ (mvn|gradle|npm|cargo).*build|test ]]; then
                is_major=true
                decision_type="build_test"
            fi
            ;;
    esac

    if [[ "$is_major" == "true" ]]; then
        # Append to decisions file
        local decision="{\"timestamp\": \"$timestamp\", \"type\": \"$decision_type\", \"tool\": \"$tool_name\", \"description\": \"$description\"}"

        if [[ -f "$decisions_file" ]]; then
            # Append to existing decisions
            python3 -c "
import json, sys
try:
    with open('$decisions_file', 'r') as f:
        data = json.load(f)
except:
    data = {'decisions': []}
data['decisions'].append($decision)
with open('$decisions_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
        else
            echo "{\"decisions\": [$decision]}" > "$decisions_file"
        fi
    fi
}

#===============================================================================
# Main Function
#===============================================================================

main() {
    # Read input from stdin
    local input
    input=$(cat)

    log_debug "Received input: ${input:0:200}..."

    # Detect agent type
    local agent_type="${KAPSIS_AGENT_TYPE:-claude-cli}"

    # Parse input based on agent type
    local parsed
    case "$agent_type" in
        claude|claude-cli)
            parsed=$(parse_claude_input "$input")
            ;;
        codex|codex-cli)
            parsed=$(parse_codex_input "$input")
            ;;
        gemini|gemini-cli)
            parsed=$(parse_gemini_input "$input")
            ;;
        *)
            # Default to Claude format
            parsed=$(parse_claude_input "$input")
            ;;
    esac

    local tool_name command file_path
    tool_name=$(json_get "$parsed" "tool_name" "unknown")
    command=$(json_get "$parsed" "command" "")
    file_path=$(json_get "$parsed" "file_path" "")

    log_debug "Parsed: tool=$tool_name, command=${command:0:50}..., file=$file_path"

    # Map tool to category
    local category
    category=$(map_tool_to_category "$tool_name" "$command")

    log_debug "Category: $category"

    # Load and update state
    local state
    state=$(load_state)
    state=$(increment_tool_count "$state" "$category")

    # Update last tool in state
    state=$(echo "$state" | python3 -c "
import json, sys
state = json.load(sys.stdin)
state['last_tool'] = '$tool_name'
state['last_update'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
print(json.dumps(state))
" 2>/dev/null)

    save_state "$state"

    # Calculate progress
    local progress
    progress=$(calculate_progress "$state")

    # Generate status message
    local message
    case "$category" in
        exploring)
            message="Exploring codebase"
            [[ -n "$file_path" ]] && message="Reading $file_path"
            ;;
        implementing)
            message="Implementing changes"
            [[ -n "$file_path" ]] && message="Editing $file_path"
            ;;
        building)
            message="Building project"
            ;;
        testing)
            message="Running tests"
            ;;
        *)
            message="Working..."
            ;;
    esac

    # Update Kapsis status
    if [[ -n "${KAPSIS_STATUS_PROJECT:-}" && -n "${KAPSIS_STATUS_AGENT_ID:-}" ]]; then
        if type status_reinit_from_env &>/dev/null; then
            status_reinit_from_env
            status_phase "running" "$progress" "$message"
            log_debug "Updated status: running $progress% - $message"
        fi
    fi

    # Log decision if significant
    log_decision "$tool_name" "${command:-$file_path}" "$file_path"

    # Output empty JSON (required by hook system)
    echo "{}"
}

# Run main function
main "$@"
