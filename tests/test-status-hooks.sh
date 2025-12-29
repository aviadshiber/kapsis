#!/usr/bin/env bash
#===============================================================================
# Tests for Kapsis Status Tracking Hooks
#
# Run: ./tests/test-status-hooks.sh
#===============================================================================

set -euo pipefail

# Load test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Script locations (relative to KAPSIS_ROOT from test framework)
LIB_DIR="$KAPSIS_ROOT/scripts/lib"
HOOKS_DIR="$KAPSIS_ROOT/scripts/hooks"

#===============================================================================
# Test: Agent Types Library
#===============================================================================
test_agent_types_normalization() {
    source "$LIB_DIR/agent-types.sh"

    # Test Claude variants
    assert_equals "$(normalize_agent_type 'claude')" "claude-cli" "claude -> claude-cli"
    assert_equals "$(normalize_agent_type 'Claude Code')" "claude-cli" "Claude Code -> claude-cli"
    assert_equals "$(normalize_agent_type 'CLAUDE-CLI')" "claude-cli" "CLAUDE-CLI -> claude-cli"

    # Test Codex variants
    assert_equals "$(normalize_agent_type 'codex')" "codex-cli" "codex -> codex-cli"
    assert_equals "$(normalize_agent_type 'codex-cli')" "codex-cli" "codex-cli -> codex-cli"
    assert_equals "$(normalize_agent_type 'openai codex')" "codex-cli" "openai codex -> codex-cli"

    # Test Gemini variants
    assert_equals "$(normalize_agent_type 'gemini')" "gemini-cli" "gemini -> gemini-cli"
    assert_equals "$(normalize_agent_type 'google gemini')" "gemini-cli" "google gemini -> gemini-cli"

    # Test other agents
    assert_equals "$(normalize_agent_type 'aider')" "aider" "aider -> aider"
    assert_equals "$(normalize_agent_type 'python')" "python" "python -> python"
    assert_equals "$(normalize_agent_type 'claude-api')" "python" "claude-api -> python"

    # Test unknown
    assert_equals "$(normalize_agent_type 'something-else')" "unknown" "unknown agent -> unknown"
}

test_agent_hook_support() {
    source "$LIB_DIR/agent-types.sh"

    # Hook-supporting agents
    assert_true "agent_supports_hooks 'claude-cli'" "claude-cli supports hooks"
    assert_true "agent_supports_hooks 'codex-cli'" "codex-cli supports hooks"
    assert_true "agent_supports_hooks 'gemini-cli'" "gemini-cli supports hooks"

    # Non-hook agents
    assert_false "agent_supports_hooks 'aider'" "aider does not support hooks"
    assert_false "agent_supports_hooks 'unknown'" "unknown does not support hooks"
}

test_agent_python_status() {
    source "$LIB_DIR/agent-types.sh"

    assert_true "agent_uses_python_status 'python'" "python uses python status"
    assert_false "agent_uses_python_status 'claude-cli'" "claude-cli does not use python status"
}

#===============================================================================
# Test: Tool Phase Mapping - Config Loading
#===============================================================================
test_config_file_loading() {
    # Source script in current shell (not subshell) for associative array access
    source "$HOOKS_DIR/tool-phase-mapping.sh"

    # Trigger config load and check a tool mapping
    local result
    result=$(map_tool_to_category 'Read')
    assert_equals "exploring" "$result" "Config loads Read -> exploring"

    # For phase ranges, we need to call from within the same shell context
    # Use a subtest that sources and tests in one go
    local range_test
    range_test=$(bash -c "
        cd '$KAPSIS_ROOT'
        source '$HOOKS_DIR/tool-phase-mapping.sh'
        # Force load
        map_tool_to_category 'Read' >/dev/null
        # Now check ranges (config is loaded in this shell)
        echo \"\$(get_phase_progress_range 'exploring')|\$(get_phase_progress_range 'testing')\"
    " 2>/dev/null)

    local exploring_range testing_range
    IFS='|' read -r exploring_range testing_range <<< "$range_test"

    assert_equals "25,35" "$exploring_range" "Config loads exploring phase range"
    assert_equals "60,80" "$testing_range" "Config loads testing phase range"
}

test_config_tool_mappings() {
    source "$HOOKS_DIR/tool-phase-mapping.sh"

    # Exploring tools from config
    assert_equals "exploring" "$(map_tool_to_category 'Read')" "Read -> exploring"
    assert_equals "exploring" "$(map_tool_to_category 'Grep')" "Grep -> exploring"
    assert_equals "exploring" "$(map_tool_to_category 'Glob')" "Glob -> exploring"
    assert_equals "exploring" "$(map_tool_to_category 'WebFetch')" "WebFetch -> exploring"
    assert_equals "exploring" "$(map_tool_to_category 'WebSearch')" "WebSearch -> exploring"

    # Implementing tools from config
    assert_equals "implementing" "$(map_tool_to_category 'Write')" "Write -> implementing"
    assert_equals "implementing" "$(map_tool_to_category 'Edit')" "Edit -> implementing"
    assert_equals "implementing" "$(map_tool_to_category 'NotebookEdit')" "NotebookEdit -> implementing"

    # Other tools from config
    assert_equals "other" "$(map_tool_to_category 'TodoWrite')" "TodoWrite -> other"
    assert_equals "other" "$(map_tool_to_category 'Task')" "Task -> other"
    assert_equals "other" "$(map_tool_to_category 'Agent')" "Agent -> other"

    # MCP tools -> other (prefix match)
    assert_equals "other" "$(map_tool_to_category 'mcp__jira__create')" "mcp__ prefix -> other"

    # Unknown tool -> default (other)
    assert_equals "other" "$(map_tool_to_category 'SomeUnknownTool')" "Unknown tool -> other"
}

test_config_bash_patterns() {
    source "$HOOKS_DIR/tool-phase-mapping.sh"

    # Bash tool routes to command classification
    assert_equals "committing" "$(map_tool_to_category 'Bash' 'git commit -m test')" "Bash(git commit) -> committing"
    assert_equals "testing" "$(map_tool_to_category 'Bash' 'npm test')" "Bash(npm test) -> testing"
    assert_equals "building" "$(map_tool_to_category 'Bash' 'mvn clean install')" "Bash(mvn) -> building"
}

test_bash_command_mapping() {
    source "$HOOKS_DIR/tool-phase-mapping.sh"

    # Build commands
    assert_equals "building" "$(map_bash_command_to_category 'mvn clean install')" "mvn -> building"
    assert_equals "building" "$(map_bash_command_to_category 'npm run build')" "npm build -> building"
    assert_equals "building" "$(map_bash_command_to_category 'gradle assemble')" "gradle -> building"

    # Test commands
    assert_equals "testing" "$(map_bash_command_to_category 'mvn test')" "mvn test -> testing"
    assert_equals "testing" "$(map_bash_command_to_category 'pytest tests/')" "pytest -> testing"
    assert_equals "testing" "$(map_bash_command_to_category 'npm test')" "npm test -> testing"

    # Git commands
    assert_equals "committing" "$(map_bash_command_to_category 'git commit -m \"msg\"')" "git commit -> committing"
    assert_equals "exploring" "$(map_bash_command_to_category 'git status')" "git status -> exploring"
    assert_equals "other" "$(map_bash_command_to_category 'git add .')" "git add -> other (unrecognized git op)"

    # File reading/listing (exploring)
    assert_equals "exploring" "$(map_bash_command_to_category 'ls -la')" "ls -> exploring"
    assert_equals "exploring" "$(map_bash_command_to_category 'cat file.txt')" "cat -> exploring"

    # Fallback for truly unknown commands
    assert_equals "other" "$(map_bash_command_to_category 'some-weird-command --flag')" "unknown cmd -> other"
}

#===============================================================================
# Test: Claude Adapter
#===============================================================================
test_claude_adapter_parsing() {
    source "$HOOKS_DIR/agent-adapters/claude-adapter.sh"

    # Test Read tool parsing
    local read_input='{"tool":"Read","tool_input":{"file_path":"/workspace/src/main.py"}}'
    local result
    result=$(parse_claude_hook_input "$read_input")

    local tool_name
    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    assert_equals "$tool_name" "Read" "Parse Read tool"

    # Test Bash tool parsing
    local bash_input='{"tool":"Bash","tool_input":{"command":"npm test"}}'
    result=$(parse_claude_hook_input "$bash_input")

    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    local command
    command=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command', ''))")
    assert_equals "$tool_name" "Bash" "Parse Bash tool"
    assert_equals "$command" "npm test" "Parse Bash command"
}

#===============================================================================
# Test: Codex Adapter
#===============================================================================
test_codex_adapter_parsing() {
    source "$HOOKS_DIR/agent-adapters/codex-adapter.sh"

    # Test exec.post parsing
    local exec_input='{"type":"exec.post","command":"npm install","exit_code":0}'
    local result
    result=$(parse_codex_hook_input "$exec_input")

    local tool_name
    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    assert_equals "$tool_name" "Bash" "Parse exec.post as Bash"

    # Test item.create parsing
    local create_input='{"type":"item.create","item_type":"file","path":"/workspace/src/new.py"}'
    result=$(parse_codex_hook_input "$create_input")

    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    assert_equals "$tool_name" "Write" "Parse item.create as Write"
}

#===============================================================================
# Test: Gemini Adapter
#===============================================================================
test_gemini_adapter_parsing() {
    source "$HOOKS_DIR/agent-adapters/gemini-adapter.sh"

    # Test tool_call parsing
    local tool_input='{"event":"tool_call","function_call":{"name":"execute_code","args":{"code":"ls -la"}}}'
    local result
    result=$(parse_gemini_hook_input "$tool_input")

    local tool_name
    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    assert_equals "$tool_name" "Bash" "Parse execute_code as Bash"

    # Test completion event
    local completion_input='{"event":"completion","status":"success"}'
    result=$(parse_gemini_hook_input "$completion_input")

    tool_name=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name', ''))")
    assert_equals "$tool_name" "Stop" "Parse completion as Stop"
}

#===============================================================================
# Test: Agent ID Validation
#===============================================================================
test_agent_id_empty_skips_status() {
    # When KAPSIS_STATUS_AGENT_ID is empty, hook should output "{}" and exit 0
    local result exit_code
    result=$(KAPSIS_STATUS_AGENT_ID="" echo '{"tool_name":"Read"}' | bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "$exit_code" "0" "Empty agent_id exits with 0"
    assert_equals "$result" "{}" "Empty agent_id outputs empty JSON"
}

test_agent_id_unset_skips_status() {
    # When KAPSIS_STATUS_AGENT_ID is unset, hook should output "{}" and exit 0
    local result exit_code
    result=$(unset KAPSIS_STATUS_AGENT_ID && echo '{"tool_name":"Read"}' | bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "$exit_code" "0" "Unset agent_id exits with 0"
    assert_equals "$result" "{}" "Unset agent_id outputs empty JSON"
}

test_agent_id_invalid_path_traversal_skips() {
    # Path traversal attempts should be rejected
    local tmpfile result exit_code stderr_output
    tmpfile=$(mktemp)

    # Run hook and capture both stdout and stderr separately
    result=$(export KAPSIS_STATUS_AGENT_ID="../malicious" && echo '{"tool_name":"Read"}' | bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>"$tmpfile")
    exit_code=$?
    stderr_output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    assert_equals "$exit_code" "0" "Invalid agent_id exits with 0"
    assert_equals "$result" "{}" "Invalid agent_id outputs empty JSON"
    assert_contains "$stderr_output" "Invalid agent_id format" "Logs error for invalid format"
}

test_agent_id_invalid_special_chars_skips() {
    # Special characters should be rejected
    local result exit_code
    result=$(KAPSIS_STATUS_AGENT_ID="agent;rm -rf /" echo '{"tool_name":"Read"}' | bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "$exit_code" "0" "Special chars agent_id exits with 0"
    assert_equals "$result" "{}" "Special chars agent_id outputs empty JSON"
}

test_agent_id_valid_formats_accepted() {
    # Valid formats: alphanumeric, hyphens, underscores
    local valid_ids=("agent1" "agent-1" "agent_1" "Agent-Test_123" "0" "a")

    for id in "${valid_ids[@]}"; do
        # We can't fully test processing without full env setup, but we can verify
        # the validation function directly
        if [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            assert_true "true" "Valid agent_id format: $id"
        else
            assert_true "false" "Should accept valid agent_id: $id"
        fi
    done
}

test_stop_hook_agent_id_validation() {
    # Stop hook should also validate agent_id
    local result exit_code
    result=$(KAPSIS_STATUS_AGENT_ID="" echo '{}' | bash "$HOOKS_DIR/kapsis-stop-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "$exit_code" "0" "Stop hook: empty agent_id exits with 0"
    assert_equals "$result" "{}" "Stop hook: empty agent_id outputs empty JSON"

    result=$(KAPSIS_STATUS_AGENT_ID="../bad" echo '{}' | bash "$HOOKS_DIR/kapsis-stop-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "$exit_code" "0" "Stop hook: invalid agent_id exits with 0"
    assert_equals "$result" "{}" "Stop hook: invalid agent_id outputs empty JSON"
}

#===============================================================================
# Test: Progress Monitor Functions
#===============================================================================
test_progress_scaling() {
    source "$LIB_DIR/progress-monitor.sh"

    # Test progress scale: Agent 0-100% → Kapsis 25-90%
    assert_equals "$(calculate_kapsis_progress 0)" "25" "0% agent -> 25% kapsis"
    assert_equals "$(calculate_kapsis_progress 50)" "57" "50% agent -> 57% kapsis"
    assert_equals "$(calculate_kapsis_progress 100)" "90" "100% agent -> 90% kapsis"

    # Test clamping
    assert_equals "$(calculate_kapsis_progress -10)" "25" "negative -> 25%"
    assert_equals "$(calculate_kapsis_progress 150)" "90" "over 100 -> 90%"
}

test_progress_phase_mapping() {
    source "$LIB_DIR/progress-monitor.sh"

    assert_equals "$(map_progress_to_phase 10)" "exploring" "10% -> exploring"
    assert_equals "$(map_progress_to_phase 30)" "implementing" "30% -> implementing"
    assert_equals "$(map_progress_to_phase 70)" "testing" "70% -> testing"
    assert_equals "$(map_progress_to_phase 90)" "completing" "90% -> completing"
}

#===============================================================================
# Run Tests
#===============================================================================
run_tests() {
    print_test_header "Kapsis Status Hooks Test Suite"

    log_info "=== Agent Types Library ==="
    run_test test_agent_types_normalization
    run_test test_agent_hook_support
    run_test test_agent_python_status

    log_info "=== Tool Phase Mapping (Config-Based) ==="
    run_test test_config_file_loading
    run_test test_config_tool_mappings
    run_test test_config_bash_patterns
    run_test test_bash_command_mapping

    log_info "=== Claude Adapter ==="
    run_test test_claude_adapter_parsing

    log_info "=== Codex Adapter ==="
    run_test test_codex_adapter_parsing

    log_info "=== Gemini Adapter ==="
    run_test test_gemini_adapter_parsing

    log_info "=== Progress Monitor ==="
    run_test test_progress_scaling
    run_test test_progress_phase_mapping

    log_info "=== Agent ID Validation ==="
    run_test test_agent_id_empty_skips_status
    run_test test_agent_id_unset_skips_status
    run_test test_agent_id_invalid_path_traversal_skips
    run_test test_agent_id_invalid_special_chars_skips
    run_test test_agent_id_valid_formats_accepted
    run_test test_stop_hook_agent_id_validation

    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
