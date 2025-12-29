#!/usr/bin/env bash
#===============================================================================
# Gemini CLI Adapter for Kapsis Status Hooks
#
# Parses Google Gemini CLI's hook JSON format and extracts relevant fields
# for status tracking.
#
# Gemini CLI Hook Format (tool_call):
# {
#   "event": "tool_call",
#   "function_call": {
#     "name": "execute_code",
#     "args": {
#       "code": "ls -la",
#       "language": "bash"
#     }
#   },
#   "result": "..."
# }
#
# Gemini CLI Hook Format (completion):
# {
#   "event": "completion",
#   "status": "success",
#   "message": "Task completed"
# }
#===============================================================================

# Parse Gemini CLI hook input and return normalized JSON
# Arguments:
#   $1 - Raw JSON input from Gemini CLI hook
# Returns:
#   Normalized JSON with: tool_name, command, file_path, result
parse_gemini_hook_input() {
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

event = data.get('event', '')
tool_name = 'unknown'
command = ''
file_path = ''
result_preview = ''

# Handle tool_call events
if event == 'tool_call':
    func_call = data.get('function_call', {})
    func_name = func_call.get('name', '')
    args = func_call.get('args', {})

    # Map Gemini function names to standard tool names
    name_map = {
        'execute_code': 'Bash',
        'run_command': 'Bash',
        'shell': 'Bash',
        'read_file': 'Read',
        'view_file': 'Read',
        'write_file': 'Write',
        'create_file': 'Write',
        'edit_file': 'Edit',
        'modify_file': 'Edit',
        'search_files': 'Grep',
        'find_files': 'Glob',
        'list_files': 'Glob',
    }

    tool_name = name_map.get(func_name, func_name)

    # Extract command for execution tools
    if tool_name == 'Bash':
        command = args.get('code', args.get('command', args.get('script', '')))

    # Extract file path for file tools
    if tool_name in ['Read', 'Write', 'Edit', 'Grep', 'Glob']:
        file_path = args.get('path', args.get('file_path', args.get('filename', '')))

    result_preview = str(data.get('result', ''))[:200]

# Handle completion events
elif event == 'completion':
    tool_name = 'Stop'
    result_preview = data.get('message', data.get('status', ''))

output = {
    'tool_name': tool_name,
    'command': command,
    'file_path': file_path,
    'result_preview': result_preview,
    'event': event,
    'status': data.get('status', '')
}

print(json.dumps(output))
" <<< "$input" 2>/dev/null || echo '{"tool_name": "unknown", "command": "", "file_path": ""}'
}

# Check if this is a Gemini CLI hook input
is_gemini_hook_input() {
    local input="$1"

    # Gemini hooks have 'event' field or 'function_call' structure
    if echo "$input" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if 'event' in data or 'function_call' in data:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get supported hook types for Gemini CLI
get_gemini_hook_types() {
    echo "tool_call completion error"
}

# Get Gemini CLI hooks directory path
get_gemini_hooks_dir() {
    echo "${HOME}/.gemini/hooks"
}

# Generate Gemini CLI hook script
generate_gemini_hook_script() {
    local hook_script="$1"

    cat << 'EOF'
#!/usr/bin/env bash
# Gemini CLI hook wrapper for Kapsis status tracking
# This script is called by Gemini CLI for tool_call events

EOF
    echo "exec \"$hook_script\""
}

# Generate Gemini CLI completion hook script
generate_gemini_completion_hook() {
    local hook_script="$1"

    cat << 'EOF'
#!/usr/bin/env bash
# Gemini CLI completion hook for Kapsis status tracking

EOF
    echo "exec \"${hook_script%/*}/kapsis-stop-hook.sh\""
}
