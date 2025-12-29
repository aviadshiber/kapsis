#!/usr/bin/env bash
#===============================================================================
# Claude Code Adapter for Kapsis Status Hooks
#
# Parses Claude Code's hook JSON format and extracts relevant fields
# for status tracking.
#
# Claude Code Hook Format (PostToolUse):
# {
#   "session_id": "unique-session-id",
#   "cwd": "/current/working/directory",
#   "tool_name": "Bash",
#   "tool_input": {"command": "ls -la"},
#   "tool_result": "output here",
#   "tool_use_id": "toolu_xyz"
# }
#===============================================================================

# Parse Claude Code hook input and return normalized JSON
# Arguments:
#   $1 - Raw JSON input from Claude Code hook
# Returns:
#   Normalized JSON with: tool_name, command, file_path, result
parse_claude_hook_input() {
    local input="$1"

    python3 -c "
import json
import sys

try:
    data = json.loads('''$input''')
except:
    try:
        data = json.load(sys.stdin)
    except:
        data = {}

# Claude Code hook format uses 'tool' or 'tool_name' for the tool name
tool_name = data.get('tool', data.get('tool_name', 'unknown'))
tool_input = data.get('tool_input', {})
tool_result = data.get('tool_result', data.get('result', ''))

# Extract command for Bash tool
command = ''
if tool_name == 'Bash' and isinstance(tool_input, dict):
    command = tool_input.get('command', '')

# Extract file path for file tools
file_path = ''
if tool_name in ['Read', 'Edit', 'Write', 'Glob', 'Grep'] and isinstance(tool_input, dict):
    file_path = tool_input.get('file_path', tool_input.get('path', ''))

# Truncate result for efficiency
result_preview = str(tool_result)[:200] if tool_result else ''

output = {
    'tool_name': tool_name,
    'command': command,
    'file_path': file_path,
    'result_preview': result_preview,
    'cwd': data.get('cwd', ''),
    'session_id': data.get('session_id', '')
}

print(json.dumps(output))
" <<< "$input" 2>/dev/null || echo '{"tool_name": "unknown", "command": "", "file_path": ""}'
}

# Check if this is a Claude Code hook input
is_claude_hook_input() {
    local input="$1"

    # Claude Code hooks have specific fields ('tool' or 'tool_name' and 'tool_input')
    if echo "$input" | python3 -c "
import json, sys
data = json.load(sys.stdin)
# Claude hooks have 'tool' or 'tool_name' and 'tool_input' at top level
if ('tool' in data or 'tool_name' in data) and 'tool_input' in data:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get supported hook types for Claude Code
get_claude_hook_types() {
    echo "PreToolUse PostToolUse Stop"
}

# Get Claude Code hook configuration path
get_claude_config_path() {
    echo "${HOME}/.claude/settings.local.json"
}

# Generate Claude Code hook configuration JSON
generate_claude_hook_config() {
    local hook_script="$1"

    cat << EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "$hook_script",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${hook_script%/*}/kapsis-stop-hook.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
}
