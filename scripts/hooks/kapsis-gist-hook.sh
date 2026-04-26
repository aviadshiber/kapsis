#!/usr/bin/env bash
#===============================================================================
# Kapsis Gist Hook - Automatic PostToolUse gist writer
#
# Fires on every PostToolUse event. Pattern-matches the tool call to derive
# a short activity summary and writes it to /workspace/.kapsis/gist.txt,
# allowing the status pipeline (kapsis-status-hook.sh, kapsis-stop-hook.sh)
# to surface a non-null gist in the status JSON without any agent cooperation.
#
# Usage:
#   This script is called automatically by the agent's hook system.
#   It reads JSON from stdin and always exits 0 (never blocks the agent).
#
# Environment Variables:
#   KAPSIS_STATUS_AGENT_ID   - Required: Agent ID (validates hook context)
#   KAPSIS_INJECT_GIST       - Must be "true" to activate (opt-in flag)
#   KAPSIS_GIST_FILE         - Override default gist file path (for testing)
#   KAPSIS_HOME              - Kapsis installation directory (default: /opt/kapsis)
#===============================================================================

set -euo pipefail

KAPSIS_HOME="${KAPSIS_HOME:-/opt/kapsis}"

# Guard 1: Only run inside a Kapsis agent session
_safe_agent_id="${KAPSIS_STATUS_AGENT_ID:-}"
if [[ -z "$_safe_agent_id" ]]; then
    exit 0
fi
if ! [[ "$_safe_agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    exit 0
fi

# Guard 2: Only run when gist feature is enabled
if [[ "${KAPSIS_INJECT_GIST:-false}" != "true" ]]; then
    exit 0
fi

# Env-overridable gist file path (mirrors KAPSIS_GIST_FILE in status.sh)
GIST_FILE="${KAPSIS_GIST_FILE:-/workspace/.kapsis/gist.txt}"
GIST_DIR="$(dirname "$GIST_FILE")"

#===============================================================================
# JSON Parsing
#===============================================================================

# Extract a field from JSON using python3 (always available in container).
# Supports nested keys like 'tool_input.command'.
json_get() {
    local json="$1"
    local field="$2"
    local default="${3:-}"

    local value
    value=$(echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    keys = '$field'.split('.')
    result = data
    for key in keys:
        if isinstance(result, dict):
            result = result.get(key, '')
        else:
            result = ''
            break
    print(result if result is not None else '')
except Exception:
    print('')
" 2>/dev/null) || value="$default"

    echo "${value:-$default}"
}

#===============================================================================
# Main
#===============================================================================

# Read stdin (hook input from Claude Code)
input=$(cat)

# Extract tool information
tool_name=$(json_get "$input" "tool_name" "")
command=""
file_path=""

if [[ "$tool_name" == "Bash" ]]; then
    command=$(json_get "$input" "tool_input.command" "")
elif [[ "$tool_name" =~ ^(Edit|Write)$ ]]; then
    file_path=$(json_get "$input" "tool_input.file_path" "")
    [[ -z "$file_path" ]] && file_path=$(json_get "$input" "tool_input.path" "")
fi

# Derive deterministic gist from tool + input
gist=""
skip=false

case "$tool_name" in
    Bash)
        if [[ "$command" =~ git[[:space:]]+commit ]]; then
            # Extract -m message using shlex.split for robust quote handling
            msg=$(printf '%s' "$command" | python3 -c "
import shlex, sys
try:
    args = shlex.split(sys.stdin.read())
    for i, arg in enumerate(args):
        if arg in ('-m', '--message') and i + 1 < len(args):
            print(args[i + 1][:60])
            break
        elif arg.startswith('-m') and len(arg) > 2:
            print(arg[2:][:60])
            break
except Exception:
    pass
" 2>/dev/null || echo "")
            gist="Committing: ${msg:-changes}"

        elif [[ "$command" =~ git[[:space:]]+push ]]; then
            gist="Pushing changes to remote"

        elif [[ "$command" =~ (mvn|gradle)[[:space:]].*test|pytest|go[[:space:]]+test|npm[[:space:]]+test|jest ]]; then
            gist="Running tests"

        elif [[ "$command" =~ (mvn|gradle)[[:space:]].*(compile|build|package|install)|go[[:space:]]+build|npm.*(build|run[[:space:]]+build) ]]; then
            gist="Building project"

        else
            # Fallback: only write on first ever call (don't overwrite a meaningful gist)
            if [[ ! -f "$GIST_FILE" ]]; then
                first_word="${command%%[[:space:]]*}"
                first_word="${first_word##*/}"   # strip path prefix (e.g. /usr/bin/curl → curl)
                gist="Running: ${first_word:0:40}"
            else
                skip=true
            fi
        fi
        ;;

    Edit)
        [[ -n "$file_path" ]] && gist="Editing: $(basename "$file_path")"
        ;;

    Write)
        [[ -n "$file_path" ]] && gist="Writing: $(basename "$file_path")"
        ;;

    *)
        # Read, Glob, Grep, and all other tools: preserve existing gist unchanged
        skip=true
        ;;
esac

# Write deterministic gist
if [[ "$skip" != "true" && -n "$gist" ]]; then
    mkdir -p "$GIST_DIR" 2>/dev/null || true
    printf '%s\n' "$gist" > "$GIST_FILE"
fi

# ─── LLM Gist upgrade (opt-in: KAPSIS_GIST_LLM=true) ────────────────────────
if [[ "${KAPSIS_GIST_LLM:-false}" == "true" ]] && command -v claude &>/dev/null; then
    GIST_LLM_STAMP="${GIST_DIR}/gist.last_llm_run"
    GIST_LLM_INTERVAL="${KAPSIS_GIST_LLM_INTERVAL:-60}"

    # High-signal tools always bypass the throttle
    is_high_signal=false
    [[ "$tool_name" == "Bash" && "$command" =~ git[[:space:]]+commit ]] && is_high_signal=true
    [[ "$tool_name" == "Write" ]] && is_high_signal=true

    # Time gate: check stamp mtime
    should_run_llm=false
    if $is_high_signal; then
        should_run_llm=true
    elif [[ ! -f "$GIST_LLM_STAMP" ]]; then
        should_run_llm=true
    else
        last=$(stat -f %m "$GIST_LLM_STAMP" 2>/dev/null || stat -c %Y "$GIST_LLM_STAMP" 2>/dev/null || echo 0)
        now=$(date +%s)
        if (( now - last >= GIST_LLM_INTERVAL )); then should_run_llm=true; fi
    fi

    if $should_run_llm; then
        tool_result=$(json_get "$input" "tool_result" "")
        tool_input_str=$(json_get "$input" "tool_input" "")
        prompt="In one sentence (max 80 chars), what is this AI coding agent doing? Start with a verb. Be specific.
Tool: $tool_name  Input: ${tool_input_str:0:200}  Output: ${tool_result:0:400}"

        gist_llm=$(timeout 8 claude --print --model claude-haiku-4-5-20251001 <<< "$prompt" 2>/dev/null) || gist_llm=""

        if [[ -n "$gist_llm" ]]; then
            mkdir -p "$GIST_DIR" 2>/dev/null || true
            tmp=$(mktemp "${GIST_DIR}/.gist.tmp.XXXXXX" 2>/dev/null) || tmp=""
            if [[ -n "$tmp" ]]; then
                printf '%s\n' "${gist_llm:0:200}" > "$tmp"
                mv "$tmp" "$GIST_FILE"
                touch "$GIST_LLM_STAMP"
            fi
        fi
        # On failure: deterministic gist (written above) stays
    fi
fi

exit 0
