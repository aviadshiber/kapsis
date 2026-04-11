#!/usr/bin/env bash
#===============================================================================
# Codex CLI Adapter for Kapsis Status Hooks
#
# Parses OpenAI Codex CLI's hook JSON format and extracts relevant fields
# for status tracking.
#
# Codex CLI Hook Format (exec.post):
# {
#   "type": "exec.post",
#   "command": "npm install",
#   "exit_code": 0,
#   "stdout": "...",
#   "stderr": "",
#   "duration_ms": 1500
# }
#
# Codex CLI Hook Format (item.*):
# {
#   "type": "item.create",
#   "item_type": "file",
#   "path": "/path/to/file.ts",
#   "content": "..."
# }
#===============================================================================

# Parse Codex CLI hook input and return normalized JSON
# Arguments:
#   $1 - Raw JSON input from Codex CLI hook
# Returns:
#   Normalized JSON with: tool_name, command, file_path, result
parse_codex_hook_input() {
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

hook_type = data.get('type', '')
tool_name = 'unknown'
command = ''
file_path = ''
result_preview = ''

# exec.pre or exec.post - command execution
if hook_type.startswith('exec'):
    tool_name = 'Bash'
    command = data.get('command', '')
    result_preview = str(data.get('stdout', ''))[:200]

# item.create - file creation
elif hook_type == 'item.create':
    item_type = data.get('item_type', '')
    if item_type == 'file':
        tool_name = 'Write'
        file_path = data.get('path', '')
    elif item_type == 'directory':
        tool_name = 'Bash'
        command = 'mkdir'
        file_path = data.get('path', '')

# item.update - file modification
elif hook_type == 'item.update':
    tool_name = 'Edit'
    file_path = data.get('path', '')

# item.delete - file deletion
elif hook_type == 'item.delete':
    tool_name = 'Bash'
    command = 'rm'
    file_path = data.get('path', '')

# item.read - file reading
elif hook_type == 'item.read':
    tool_name = 'Read'
    file_path = data.get('path', '')

output = {
    'tool_name': tool_name,
    'command': command,
    'file_path': file_path,
    'result_preview': result_preview,
    'hook_type': hook_type,
    'exit_code': data.get('exit_code', None)
}

print(json.dumps(output))
" <<< "$input" 2>/dev/null || echo '{"tool_name": "unknown", "command": "", "file_path": ""}'
}

# Check if this is a Codex CLI hook input
is_codex_hook_input() {
    local input="$1"

    # Codex hooks have 'type' field with specific prefixes
    if echo "$input" | python3 -c "
import json, sys
data = json.load(sys.stdin)
hook_type = data.get('type', '')
if hook_type.startswith(('exec.', 'item.')):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get supported hook types for Codex CLI
get_codex_hook_types() {
    echo "exec.pre exec.post item.create item.update item.delete item.read"
}

# Get Codex CLI configuration path
get_codex_config_path() {
    echo "${HOME}/.codex/config.yaml"
}

# Generate Codex CLI hook configuration YAML
generate_codex_hook_config() {
    local hook_script="$1"

    cat << EOF
# Kapsis status tracking hooks
hooks:
  exec.post:
    - $hook_script
  item.create:
    - $hook_script
  item.update:
    - $hook_script
  completion:
    - ${hook_script%/*}/kapsis-stop-hook.sh
EOF
}
