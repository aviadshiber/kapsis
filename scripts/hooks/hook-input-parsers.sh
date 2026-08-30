#!/usr/bin/env bash
#===============================================================================
# Kapsis Hook Input Parsers
#
# Canonical, sourceable per-agent PostToolUse payload parsers. This is the ONE
# place per-agent hook payloads are normalized; the status hook
# (kapsis-status-hook.sh) sources this module and dispatches by $KAPSIS_AGENT_TYPE.
# The unit tests source it directly.
#
# Each parser normalizes an agent's hook payload to a flat JSON envelope:
#   {"tool_name": "...", "command": "...", "file_path": "..."}
#
# This module is sourced, never executed — no main guard.
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_HOOK_PARSERS_LOADED:-}" ]] && return 0
_KAPSIS_HOOK_PARSERS_LOADED=1

#===============================================================================
# JSON Parsing Helper
#===============================================================================

# Extract a field from JSON using python3 (always available in container).
# Supports nested keys like 'tool_input.command'. $field is always a trusted
# literal supplied by this module's parsers (never attacker-controlled).
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
# Per-Agent Parsers
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

# Parse Codex CLI hook input.
# Codex (>=0.15x) delivers a Claude-Code-compatible payload on stdin (same field
# names: tool_name, tool_input.command, tool_input.file_path, tool_response), so we
# reuse the Claude parser. ONE value differs: codex reports ALL file edits with
# tool_name "apply_patch" (not Write/Edit), which the Claude parser would leave
# uncategorized ("other", weight 1) instead of "implementing" (weight 5). Normalize
# it to "Edit" so category, status message, and decision logging all work. (Its
# tool_input is a patch blob, not {file_path}, so per-file granularity isn't available.)
parse_codex_input() {
    local input="$1"
    local tool_name
    tool_name=$(json_get "$input" "tool_name" "unknown")
    if [[ "$tool_name" == "apply_patch" ]]; then
        # Re-label apply_patch -> Edit for the Claude parser + downstream mapping.
        input=$(echo "$input" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    d['tool_name'] = 'Edit'
    print(json.dumps(d))
except Exception:
    print('$input')
" 2>/dev/null) || true
    fi
    parse_claude_input "$input"
}

# Parse Gemini CLI hook input.
# NOTE: Gemini hooks do NOT fire in Kapsis's headless (`gemini -p`) mode, so this
# parser is effectively unused there — Gemini status comes from the instruction-based
# gist path. It is kept correct for the interactive case only. Gemini's AfterTool
# payload uses Claude-compatible envelope fields (tool_name, tool_input) but
# snake_case built-in tool names (run_shell_command / write_file / read_file / ...).
parse_gemini_input() {
    local input="$1"

    local tool_name
    tool_name=$(json_get "$input" "tool_name" "unknown")

    local command=""
    local file_path=""
    case "$tool_name" in
        run_shell_command|execute_code|run_command)
            tool_name="Bash"
            command=$(json_get "$input" "tool_input.command" "")
            [[ -z "$command" ]] && command=$(json_get "$input" "tool_input.code" "")
            ;;
        read_file|read_many_files|view_file)
            tool_name="Read"
            file_path=$(json_get "$input" "tool_input.file_path" "")
            [[ -z "$file_path" ]] && file_path=$(json_get "$input" "tool_input.path" "")
            ;;
        write_file|replace|edit_file)
            tool_name="Edit"
            file_path=$(json_get "$input" "tool_input.file_path" "")
            [[ -z "$file_path" ]] && file_path=$(json_get "$input" "tool_input.path" "")
            ;;
        search_file_content|glob|grep)
            tool_name="Grep"
            ;;
    esac

    echo "{\"tool_name\": \"$tool_name\", \"command\": \"$command\", \"file_path\": \"$file_path\"}"
}
