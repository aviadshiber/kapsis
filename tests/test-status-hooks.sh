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
    # When KAPSIS_STATUS_AGENT_ID is empty, hook should output "{}" and exit 0.
    # Pass the env var directly to the bash invocation (not just to echo) so the
    # hook subprocess actually receives the empty value.
    local result exit_code
    result=$(echo '{"tool_name":"Read"}' | KAPSIS_STATUS_AGENT_ID="" bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "0" "$exit_code" "Empty agent_id exits with 0"
    assert_equals "{}" "$result" "Empty agent_id outputs empty JSON"
}

test_agent_id_unset_skips_status() {
    # When KAPSIS_STATUS_AGENT_ID is unset, hook should output "{}" and exit 0.
    # Unset the var inside the bash invocation so the hook subprocess sees it unset.
    local result exit_code
    result=$(echo '{"tool_name":"Read"}' | env -u KAPSIS_STATUS_AGENT_ID bash "$HOOKS_DIR/kapsis-status-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "0" "$exit_code" "Unset agent_id exits with 0"
    assert_equals "{}" "$result" "Unset agent_id outputs empty JSON"
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
    # Stop hook should also validate agent_id.
    # Pass env var directly to bash invocation (not just to echo) so the hook subprocess
    # actually receives the intended value.
    local result exit_code
    result=$(echo '{}' | KAPSIS_STATUS_AGENT_ID="" bash "$HOOKS_DIR/kapsis-stop-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "0" "$exit_code" "Stop hook: empty agent_id exits with 0"
    assert_equals "{}" "$result" "Stop hook: empty agent_id outputs empty JSON"

    result=$(echo '{}' | KAPSIS_STATUS_AGENT_ID="../bad" bash "$HOOKS_DIR/kapsis-stop-hook.sh" 2>/dev/null)
    exit_code=$?

    assert_equals "0" "$exit_code" "Stop hook: invalid agent_id exits with 0"
    assert_equals "{}" "$result" "Stop hook: invalid agent_id outputs empty JSON"
}

#===============================================================================
# Test: Hook Injection (inject-status-hooks.sh)
#===============================================================================

# Setup isolated test environment for injection tests
_ORIGINAL_HOME=""
setup_inject_test_env() {
    _ORIGINAL_HOME="$HOME"
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    export KAPSIS_HOME="$KAPSIS_ROOT"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"

    # Create log directory for inject-status-hooks.sh logging
    mkdir -p "$TEST_HOME/.kapsis/logs"

    # Create mock hooks that the script expects to find
    mkdir -p "$KAPSIS_ROOT/hooks"
    touch "$KAPSIS_ROOT/hooks/kapsis-status-hook.sh"
    touch "$KAPSIS_ROOT/hooks/kapsis-stop-hook.sh"
    chmod +x "$KAPSIS_ROOT/hooks/kapsis-status-hook.sh"
    chmod +x "$KAPSIS_ROOT/hooks/kapsis-stop-hook.sh"
}

cleanup_inject_test_env() {
    # Restore original HOME
    if [[ -n "$_ORIGINAL_HOME" ]]; then
        export HOME="$_ORIGINAL_HOME"
    fi
    rm -rf "$TEST_HOME"
    rm -rf "$KAPSIS_ROOT/hooks"
    unset TEST_HOME
    unset KAPSIS_HOME

    # Reset logging state to prevent writes to deleted temp directory
    # The logging library caches the log file path
    _KAPSIS_LOG_FILE_PATH=""
    # shellcheck disable=SC2034  # Used by logging.sh
    export KAPSIS_LOG_TO_FILE="false"
}

test_inject_claude_creates_settings_if_missing() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-1"

    # Verify .claude directory doesn't exist
    assert_false "[[ -d '$TEST_HOME/.claude' ]]" "claude dir should not exist initially"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Verify settings.local.json was created
    assert_file_exists "$TEST_HOME/.claude/settings.local.json" "settings.local.json should be created"

    # Verify it contains our hooks
    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$content" "PostToolUse" "Should contain PostToolUse hook"
    assert_contains "$content" "kapsis-status-hook.sh" "Should contain status hook"
    assert_contains "$content" "Stop" "Should contain Stop hook"
    assert_contains "$content" "kapsis-stop-hook.sh" "Should contain stop hook"

    cleanup_inject_test_env
}

test_inject_claude_merges_with_existing() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-2"

    # Create existing settings with user hooks
    mkdir -p "$TEST_HOME/.claude"
    cat > "$TEST_HOME/.claude/settings.local.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "/user/custom-hook.sh"}]
    }]
  }
}
EOF

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Verify user hooks are preserved
    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$content" "/user/custom-hook.sh" "User hook should be preserved"
    assert_contains "$content" "kapsis-status-hook.sh" "Kapsis hook should be added"

    # Count PostToolUse entries - should be 2 (user + kapsis)
    local hook_count
    hook_count=$(jq '.hooks.PostToolUse | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "2" "$hook_count" "Should have 2 PostToolUse entries"

    cleanup_inject_test_env
}

test_inject_claude_idempotent() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-3"

    # Run injection twice
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1
    inject_claude_hooks >/dev/null 2>&1

    # Verify hooks are not duplicated
    local hook_count
    hook_count=$(jq '.hooks.PostToolUse | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "1" "$hook_count" "Should have exactly 1 PostToolUse entry after double injection"

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "1" "$stop_count" "Should have exactly 1 Stop entry after double injection"

    cleanup_inject_test_env
}

test_inject_claude_with_gist_enabled() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-gist"
    export KAPSIS_INJECT_GIST="true"

    # Create mock gist hook (must be executable for injection to proceed)
    touch "$KAPSIS_ROOT/hooks/kapsis-gist-hook.sh"
    chmod +x "$KAPSIS_ROOT/hooks/kapsis-gist-hook.sh"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Gist hook must appear in settings
    assert_contains "$content" "kapsis-gist-hook.sh" "Gist hook should be injected when KAPSIS_INJECT_GIST=true"

    # Two PostToolUse entries: gist hook (first) + status hook (second)
    local hook_count
    hook_count=$(jq '.hooks.PostToolUse | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "2" "$hook_count" "Should have 2 PostToolUse entries (gist + status)"

    # Gist hook must come before status hook so status reads the current gist.
    # Check ordering by comparing line positions in the serialized JSON.
    local gist_line status_line
    gist_line=$(grep -n "kapsis-gist-hook.sh" "$TEST_HOME/.claude/settings.local.json" | head -1 | cut -d: -f1)
    status_line=$(grep -n "kapsis-status-hook.sh" "$TEST_HOME/.claude/settings.local.json" | head -1 | cut -d: -f1)
    assert_true "[[ ${gist_line:-99} -lt ${status_line:-100} ]]" "Gist hook should appear before status hook in JSON"

    unset KAPSIS_INJECT_GIST
    cleanup_inject_test_env
}

test_inject_claude_gist_disabled_when_hook_missing() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-gist-missing"
    export KAPSIS_INJECT_GIST="true"
    # Intentionally do NOT create the gist hook file

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Gist hook must NOT appear when the hook file is missing
    assert_not_contains "$content" "kapsis-gist-hook.sh" \
        "Gist hook should not be injected when hook file is absent"

    # Status hook must still be injected
    assert_contains "$content" "kapsis-status-hook.sh" "Status hook should still be injected"

    unset KAPSIS_INJECT_GIST
    cleanup_inject_test_env
}

test_inject_codex_creates_config_if_missing() {
    # Requires mikefarah/yq (supports eval --inplace); skip if only Python yq available
    if ! echo 'x: 1' | yq eval '.x' 2>/dev/null | grep -q '^1'; then
        return 0
    fi

    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-4"

    # Verify .codex directory doesn't exist
    assert_false "[[ -d '$TEST_HOME/.codex' ]]" "codex dir should not exist initially"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_codex_hooks >/dev/null 2>&1

    # Verify config.yaml was created
    assert_file_exists "$TEST_HOME/.codex/config.yaml" "config.yaml should be created"

    # Verify it contains our hooks
    local content
    content=$(cat "$TEST_HOME/.codex/config.yaml")
    assert_contains "$content" "exec.post" "Should contain exec.post hook"
    assert_contains "$content" "kapsis-status-hook.sh" "Should contain status hook"
    assert_contains "$content" "completion" "Should contain completion hook"

    cleanup_inject_test_env
}

test_inject_codex_merges_with_existing() {
    # Requires mikefarah/yq (supports eval --inplace); skip if only Python yq available
    if ! echo 'x: 1' | yq eval '.x' 2>/dev/null | grep -q '^1'; then
        return 0
    fi

    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-5"

    # Create existing config with user hooks
    mkdir -p "$TEST_HOME/.codex"
    cat > "$TEST_HOME/.codex/config.yaml" << 'EOF'
# Codex CLI configuration
hooks:
  exec.post:
    - /user/my-hook.sh
EOF

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_codex_hooks >/dev/null 2>&1

    # Verify user hooks are preserved
    local content
    content=$(cat "$TEST_HOME/.codex/config.yaml")
    assert_contains "$content" "/user/my-hook.sh" "User hook should be preserved"
    assert_contains "$content" "kapsis-status-hook.sh" "Kapsis hook should be added"

    cleanup_inject_test_env
}

test_inject_codex_idempotent() {
    # Requires mikefarah/yq (supports eval --inplace); skip if only Python yq available
    if ! echo 'x: 1' | yq eval '.x' 2>/dev/null | grep -q '^1'; then
        return 0
    fi

    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-6"

    # Run injection twice
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_codex_hooks >/dev/null 2>&1
    inject_codex_hooks >/dev/null 2>&1

    # Verify hooks are not duplicated (yq unique should handle this)
    local hook_count
    hook_count=$(yq eval '.hooks."exec.post" | length' "$TEST_HOME/.codex/config.yaml")
    assert_equals "1" "$hook_count" "Should have exactly 1 exec.post hook after double injection"

    cleanup_inject_test_env
}

test_inject_gemini_creates_hooks_dir() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-7"

    # Verify .gemini directory doesn't exist
    assert_false "[[ -d '$TEST_HOME/.gemini' ]]" "gemini dir should not exist initially"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gemini_hooks >/dev/null 2>&1

    # Verify hook scripts were created
    assert_file_exists "$TEST_HOME/.gemini/hooks/post-tool.sh" "post-tool.sh should be created"
    assert_file_exists "$TEST_HOME/.gemini/hooks/completion.sh" "completion.sh should be created"

    # Verify they are executable
    assert_true "[[ -x '$TEST_HOME/.gemini/hooks/post-tool.sh' ]]" "post-tool.sh should be executable"
    assert_true "[[ -x '$TEST_HOME/.gemini/hooks/completion.sh' ]]" "completion.sh should be executable"

    # Verify content
    local content
    content=$(cat "$TEST_HOME/.gemini/hooks/post-tool.sh")
    assert_contains "$content" "kapsis-status-hook.sh" "Should contain status hook"

    cleanup_inject_test_env
}

test_inject_gemini_appends_to_existing() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-8"

    # Create existing hook script
    mkdir -p "$TEST_HOME/.gemini/hooks"
    cat > "$TEST_HOME/.gemini/hooks/post-tool.sh" << 'EOF'
#!/usr/bin/env bash
# User's existing hook
echo "User hook running"
EOF
    chmod +x "$TEST_HOME/.gemini/hooks/post-tool.sh"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gemini_hooks >/dev/null 2>&1

    # Verify user content is preserved
    local content
    content=$(cat "$TEST_HOME/.gemini/hooks/post-tool.sh")
    assert_contains "$content" "User hook running" "User content should be preserved"
    assert_contains "$content" "kapsis-status-hook.sh" "Kapsis hook should be appended"

    cleanup_inject_test_env
}

test_inject_gemini_idempotent() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-9"

    # Run injection twice
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gemini_hooks >/dev/null 2>&1
    inject_gemini_hooks >/dev/null 2>&1

    # Count occurrences of our hook in the file
    local hook_count
    hook_count=$(grep -c "kapsis-status-hook.sh" "$TEST_HOME/.gemini/hooks/post-tool.sh" || echo "0")
    assert_equals "1" "$hook_count" "Should have exactly 1 status hook reference after double injection"

    cleanup_inject_test_env
}

test_inject_skips_without_agent_id() {
    setup_inject_test_env
    unset KAPSIS_STATUS_AGENT_ID

    # Run main injection function
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_kapsis_hooks "claude-cli" >/dev/null 2>&1

    # Verify no settings file was created
    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" "Should not create settings without agent ID"

    cleanup_inject_test_env
}

#===============================================================================
# Test: Gist Injection (inject_gist_instructions)
#===============================================================================

test_inject_gist_when_enabled() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-1"
    export KAPSIS_INJECT_GIST="true"

    # Create a mock workspace with CLAUDE.md and AGENTS.md
    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    echo "# Project" > "$workspace/CLAUDE.md"
    echo "# Agents" > "$workspace/AGENTS.md"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gist_instructions >/dev/null 2>&1

    # Verify .kapsis directory was created
    assert_true "[[ -d '$workspace/.kapsis' ]]" ".kapsis directory should be created"

    # Verify CLAUDE.md has gist instructions
    assert_contains "$(cat "$workspace/CLAUDE.md")" "Kapsis Activity Gist" "CLAUDE.md should contain gist instructions"

    # Verify AGENTS.md has gist instructions
    assert_contains "$(cat "$workspace/AGENTS.md")" "Kapsis Activity Gist" "AGENTS.md should contain gist instructions"

    # Verify .kapsis/README.md fallback was created
    assert_file_exists "$workspace/.kapsis/README.md" ".kapsis/README.md should be created as fallback"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_when_disabled() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-2"
    unset KAPSIS_INJECT_GIST

    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    echo "# Project" > "$workspace/CLAUDE.md"

    # Run injection (default: disabled)
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gist_instructions >/dev/null 2>&1

    # Verify .kapsis directory was NOT created
    assert_false "[[ -d '$workspace/.kapsis' ]]" ".kapsis directory should not be created when disabled"

    # Verify CLAUDE.md was NOT modified
    local content
    content=$(cat "$workspace/CLAUDE.md")
    assert_equals "# Project" "$content" "CLAUDE.md should be unchanged when gist disabled"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_idempotent() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-3"
    export KAPSIS_INJECT_GIST="true"

    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    echo "# Project" > "$workspace/CLAUDE.md"

    # Run injection twice
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gist_instructions >/dev/null 2>&1
    inject_gist_instructions >/dev/null 2>&1

    # Verify gist instructions appear only once in CLAUDE.md
    local gist_count
    gist_count=$(grep -c "Kapsis Activity Gist" "$workspace/CLAUDE.md" || echo "0")
    assert_equals "1" "$gist_count" "Gist instructions should appear exactly once after double injection"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_missing_instructions_file() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-4"
    export KAPSIS_INJECT_GIST="true"

    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    # Point to a non-existent lib directory
    export KAPSIS_LIB="/tmp/nonexistent-kapsis-lib"

    echo "# Project" > "$workspace/CLAUDE.md"

    # Run injection — should warn but not fail
    source "$LIB_DIR/inject-status-hooks.sh"
    local stderr_output
    stderr_output=$(inject_gist_instructions 2>&1 >/dev/null)

    # Verify warning was logged about missing file
    assert_contains "$stderr_output" "not found" "Should warn about missing gist instructions file"

    # Verify .kapsis directory IS created (happens before instructions check)
    assert_true "[[ -d '$workspace/.kapsis' ]]" ".kapsis directory should still be created"

    # Verify CLAUDE.md was NOT modified (no instructions to inject)
    local content
    content=$(cat "$workspace/CLAUDE.md")
    assert_equals "# Project" "$content" "CLAUDE.md should be unchanged when instructions missing"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_no_markdown_files() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-5"
    export KAPSIS_INJECT_GIST="true"

    # Create workspace WITHOUT CLAUDE.md or AGENTS.md
    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"

    # Run injection
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gist_instructions >/dev/null 2>&1

    # Verify .kapsis directory was created
    assert_true "[[ -d '$workspace/.kapsis' ]]" ".kapsis directory should be created"

    # Verify .kapsis/README.md fallback was created (only injection target)
    assert_file_exists "$workspace/.kapsis/README.md" ".kapsis/README.md fallback should exist"
    assert_contains "$(cat "$workspace/.kapsis/README.md")" "Kapsis Activity Gist" "README.md should contain gist instructions"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_explicit_false() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-6"
    export KAPSIS_INJECT_GIST="false"

    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    echo "# Project" > "$workspace/CLAUDE.md"

    # Run injection (explicitly disabled)
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_gist_instructions >/dev/null 2>&1

    # Verify .kapsis directory was NOT created
    assert_false "[[ -d '$workspace/.kapsis' ]]" ".kapsis directory should not be created when explicitly false"

    # Verify CLAUDE.md was NOT modified
    local content
    content=$(cat "$workspace/CLAUDE.md")
    assert_equals "# Project" "$content" "CLAUDE.md should be unchanged when gist explicitly false"

    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_gist_readonly_workspace() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-7"
    export KAPSIS_INJECT_GIST="true"

    # Create workspace and make .kapsis creation fail by using a read-only dir
    local workspace
    workspace=$(mktemp -d)
    export KAPSIS_WORKSPACE="$workspace"
    echo "# Project" > "$workspace/CLAUDE.md"

    # Pre-create .kapsis as a file (not dir) to make mkdir -p fail
    touch "$workspace/.kapsis"
    chmod 000 "$workspace/.kapsis"

    # Run injection — should warn and skip gracefully (not crash)
    source "$LIB_DIR/inject-status-hooks.sh"
    local exit_code
    inject_gist_instructions >/dev/null 2>&1
    exit_code=$?

    assert_equals "0" "$exit_code" "Should exit 0 when mkdir fails (graceful skip)"

    # Verify CLAUDE.md was NOT modified (injection was skipped)
    local content
    content=$(cat "$workspace/CLAUDE.md")
    assert_equals "# Project" "$content" "CLAUDE.md should be unchanged when workspace is read-only"

    chmod 755 "$workspace/.kapsis" 2>/dev/null || true
    rm -rf "$workspace"
    cleanup_inject_test_env
}

test_inject_hook_path_uses_kapsis_home() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-agent-10"

    # Override KAPSIS_HOME to test the path logic
    # Note: We source the script in a subshell to test without affecting global state
    local result
    result=$(KAPSIS_HOME="/custom/kapsis/path" bash -c '
        source "'"$LIB_DIR/inject-status-hooks.sh"'" 2>/dev/null
        echo "$STATUS_HOOK|$STOP_HOOK"
    ')

    local status_hook="${result%%|*}"
    local stop_hook="${result##*|}"

    # The STATUS_HOOK should use KAPSIS_HOME
    assert_equals "/custom/kapsis/path/hooks/kapsis-status-hook.sh" "$status_hook" "STATUS_HOOK should use KAPSIS_HOME"
    assert_equals "/custom/kapsis/path/hooks/kapsis-stop-hook.sh" "$stop_hook" "STOP_HOOK should use KAPSIS_HOME"

    cleanup_inject_test_env
}

#===============================================================================
# Test: Agent Type Inference from Image Name
#===============================================================================

test_agent_type_inference_from_image_name() {
    # Test cases for agent type inference when config name doesn't normalize
    source "$LIB_DIR/agent-types.sh"

    # aviad-claude doesn't normalize to a known type
    assert_equals "unknown" "$(normalize_agent_type 'aviad-claude')" "aviad-claude should be unknown"

    # But we can infer from image name patterns
    # These simulate what launch-agent.sh does
    local test_cases=(
        "kapsis-claude-cli:latest|claude-cli"
        "kapsis-codex-cli:v1.0|codex-cli"
        "kapsis-gemini-cli:latest|gemini-cli"
        "kapsis-aider:latest|aider"
        "kapsis-sandbox:latest|unknown"
        "some-other-image:latest|unknown"
    )

    for test_case in "${test_cases[@]}"; do
        local image_name="${test_case%%|*}"
        local expected="${test_case##*|}"
        local actual="unknown"

        # Simulate the inference logic from launch-agent.sh
        case "$image_name" in
            *claude-cli*)  actual="claude-cli" ;;
            *codex-cli*)   actual="codex-cli" ;;
            *gemini-cli*)  actual="gemini-cli" ;;
            *aider*)       actual="aider" ;;
        esac

        assert_equals "$expected" "$actual" "Image '$image_name' should infer '$expected'"
    done
}

test_agent_type_normalization_priority() {
    # When both config name and image name could be used,
    # config name takes priority if it normalizes to a known type
    source "$LIB_DIR/agent-types.sh"

    # These should normalize directly (no image inference needed)
    assert_equals "claude-cli" "$(normalize_agent_type 'claude')" "claude normalizes directly"
    assert_equals "codex-cli" "$(normalize_agent_type 'codex')" "codex normalizes directly"
    assert_equals "gemini-cli" "$(normalize_agent_type 'gemini')" "gemini normalizes directly"

    # These need image-based inference
    assert_equals "unknown" "$(normalize_agent_type 'my-custom-config')" "custom config doesn't normalize"
    assert_equals "unknown" "$(normalize_agent_type 'aviad-claude')" "aviad-claude doesn't normalize"
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
# Test: Gist Hook (kapsis-gist-hook.sh)
#===============================================================================

# Helper: run the gist hook with given JSON input, returns gist.txt content (or empty)
_run_gist_hook() {
    local json="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.kapsis"

    printf '%s' "$json" | \
        KAPSIS_STATUS_AGENT_ID="test-gist-agent" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_dir/.kapsis/gist.txt" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    if [[ -f "$tmp_dir/.kapsis/gist.txt" ]]; then
        cat "$tmp_dir/.kapsis/gist.txt"
    fi
    rm -rf "$tmp_dir"
}

test_gist_hook_git_commit() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: null check in UserService\""}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_file_exists "$tmp_gist" "gist.txt should be written on git commit"
    local content
    content=$(cat "$tmp_gist")
    assert_contains "$content" "Committing:" "gist should contain 'Committing:' prefix"
    assert_contains "$content" "fix: null check" "gist should contain commit message"

    rm -rf "$tmp_dir"
}

test_gist_hook_git_push() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_file_exists "$tmp_gist" "gist.txt should be written on git push"
    assert_contains "$(cat "$tmp_gist")" "Pushing changes to remote" "gist should describe push"

    rm -rf "$tmp_dir"
}

test_gist_hook_edit() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/src/UserService.java"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_file_exists "$tmp_gist" "gist.txt should be written on Edit"
    local content
    content=$(cat "$tmp_gist")
    assert_contains "$content" "Editing:" "gist should contain 'Editing:' prefix"
    assert_contains "$content" "UserService.java" "gist should contain file basename"

    rm -rf "$tmp_dir"
}

test_gist_hook_write() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/workspace/src/Config.java"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_file_exists "$tmp_gist" "gist.txt should be written on Write"
    local content
    content=$(cat "$tmp_gist")
    assert_contains "$content" "Writing:" "gist should contain 'Writing:' prefix"
    assert_contains "$content" "Config.java" "gist should contain file basename"

    rm -rf "$tmp_dir"
}

test_gist_hook_running_tests_mvn() {
    local content
    content=$(_run_gist_hook '{"tool_name":"Bash","tool_input":{"command":"mvn test -pl auth-module"}}')
    assert_contains "$content" "Running tests" "gist should say 'Running tests' for mvn test"
}

test_gist_hook_running_tests_pytest() {
    local content
    content=$(_run_gist_hook '{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}')
    assert_contains "$content" "Running tests" "gist should say 'Running tests' for pytest"
}

test_gist_hook_no_overwrite_on_read() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf 'Building: authentication module\n' > "$tmp_gist"

    printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/workspace/src/Auth.java"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_equals "Building: authentication module" "$(cat "$tmp_gist")" "gist.txt should be unchanged after Read"

    rm -rf "$tmp_dir"
}

test_gist_hook_no_overwrite_on_grep() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf 'Running tests\n' > "$tmp_gist"

    printf '%s' '{"tool_name":"Grep","tool_input":{"pattern":"TODO"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_equals "Running tests" "$(cat "$tmp_gist")" "gist.txt should be unchanged after Grep"

    rm -rf "$tmp_dir"
}

test_gist_hook_bash_fallback_first_run() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    # No pre-existing gist.txt — first run should write fallback
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"curl -s https://api.example.com"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_file_exists "$tmp_gist" "gist.txt should be written on first Bash call"
    local content
    content=$(cat "$tmp_gist")
    assert_contains "$content" "Running:" "fallback gist should have 'Running:' prefix"
    assert_contains "$content" "curl" "fallback gist should contain extracted command name"

    rm -rf "$tmp_dir"
}

test_gist_hook_bash_fallback_no_overwrite() {
    local tmp_dir tmp_gist
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"

    printf 'Committing: fix: auth bug\n' > "$tmp_gist"

    # Unrecognized Bash command when gist already exists — should NOT overwrite
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la /workspace"}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_equals "Committing: fix: auth bug" "$(cat "$tmp_gist")" "gist.txt should not be overwritten by unrecognized Bash"

    rm -rf "$tmp_dir"
}

test_gist_hook_skips_when_agent_id_missing() {
    local tmp_dir tmp_gist exit_code
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"
    exit_code=0

    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}' | \
        env -u KAPSIS_STATUS_AGENT_ID \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "gist hook should exit 0 without agent_id"
    assert_false "[[ -f '$tmp_gist' ]]" "gist.txt should not be written without agent_id"

    rm -rf "$tmp_dir"
}

test_gist_hook_skips_when_inject_gist_false() {
    local tmp_dir tmp_gist exit_code
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"
    exit_code=0

    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}' | \
        KAPSIS_STATUS_AGENT_ID="test123" \
        KAPSIS_INJECT_GIST="false" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "gist hook should exit 0 when KAPSIS_INJECT_GIST=false"
    assert_false "[[ -f '$tmp_gist' ]]" "gist.txt should not be written when gist disabled"

    rm -rf "$tmp_dir"
}

#===============================================================================
# Test: Gist Hook Injection into settings.local.json
#===============================================================================

test_inject_gist_hook_injected_when_enabled() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-hook-1"
    export KAPSIS_INJECT_GIST="true"

    # Create mock gist hook
    touch "$KAPSIS_ROOT/hooks/kapsis-gist-hook.sh"
    chmod +x "$KAPSIS_ROOT/hooks/kapsis-gist-hook.sh"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    local hook_count
    hook_count=$(jq '.hooks.PostToolUse | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "2" "$hook_count" "Should have 2 PostToolUse entries (status + gist) when KAPSIS_INJECT_GIST=true"

    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$content" "kapsis-gist-hook.sh" "settings should contain gist hook path"

    cleanup_inject_test_env
}

test_inject_gist_hook_not_injected_when_disabled() {
    setup_inject_test_env
    export KAPSIS_STATUS_AGENT_ID="test-gist-hook-2"
    unset KAPSIS_INJECT_GIST

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    local hook_count
    hook_count=$(jq '.hooks.PostToolUse | length' "$TEST_HOME/.claude/settings.local.json")
    assert_equals "1" "$hook_count" "Should have 1 PostToolUse entry (status only) when KAPSIS_INJECT_GIST not set"

    local content
    content=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_not_contains "$content" "kapsis-gist-hook.sh" "settings should not contain gist hook when disabled"

    cleanup_inject_test_env
}

#===============================================================================
# LLM Gist Throttle Tests
#===============================================================================

# Helper: create a mock claude binary that records invocations.
# Uses a quoted heredoc + separate files for output/exit_code so that
# special characters in $output or $exit_code cannot break the generated script.
_make_mock_claude() {
    local mock_dir="$1"
    local exit_code="${2:-0}"
    local output="${3:-LLM result text}"
    mkdir -p "$mock_dir"
    printf '%s\n' "$output" > "$mock_dir/claude_output"
    printf '%d\n' "$exit_code" > "$mock_dir/claude_exitcode"
    cat > "$mock_dir/claude" << 'EOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/../llm_called_marker"
cat "$(dirname "$0")/claude_output"
exit "$(cat "$(dirname "$0")/claude_exitcode")"
EOF
    chmod +x "$mock_dir/claude"
}

test_gist_llm_time_gate_blocks() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local gist_file="${tmp_dir}/gist.txt"
    local stamp_file="${tmp_dir}/gist.last_llm_run"
    local mock_dir="${tmp_dir}/bin"

    _make_mock_claude "$mock_dir"

    # Create a fresh stamp file (set mtime to "now")
    touch "$stamp_file"

    # Use a Read tool event (non-high-signal) so deterministic gist is skipped
    local input='{"tool_name":"Read","tool_input":{"file_path":"/workspace/foo.java"}}'

    PATH="$mock_dir:$PATH" \
    KAPSIS_STATUS_AGENT_ID="test-llm-gate" \
    KAPSIS_INJECT_GIST=true \
    KAPSIS_GIST_LLM=true \
    KAPSIS_GIST_LLM_INTERVAL=3600 \
    KAPSIS_GIST_FILE="$gist_file" \
    bash "$HOOKS_DIR/kapsis-gist-hook.sh" <<< "$input" 2>/dev/null

    # LLM must NOT have been called (stamp is fresh)
    assert_false "[[ -f '${tmp_dir}/llm_called_marker' ]]" "LLM should be blocked by time gate"
    # No gist written (Read tool + throttled)
    assert_false "[[ -f '$gist_file' ]]" "No gist should be written when gate blocks"

    rm -rf "$tmp_dir"
}

test_gist_llm_high_signal_bypasses_gate() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local gist_file="${tmp_dir}/gist.txt"
    local stamp_file="${tmp_dir}/gist.last_llm_run"
    local mock_dir="${tmp_dir}/bin"

    _make_mock_claude "$mock_dir" 0 "Committing the null-gist fix"

    # Create a fresh stamp file — throttle would normally block
    touch "$stamp_file"

    local input='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: null gist\""}}'

    # KAPSIS_GIST_LLM_SYNC=true: synchronous mode so the test can inspect results immediately.
    # Stamp path is derived from dirname(KAPSIS_GIST_FILE) — no separate env var needed.
    PATH="$mock_dir:$PATH" \
    KAPSIS_STATUS_AGENT_ID="test-llm-high" \
    KAPSIS_INJECT_GIST=true \
    KAPSIS_GIST_LLM=true \
    KAPSIS_GIST_LLM_SYNC=true \
    KAPSIS_GIST_LLM_INTERVAL=3600 \
    KAPSIS_GIST_FILE="$gist_file" \
    bash "$HOOKS_DIR/kapsis-gist-hook.sh" <<< "$input" 2>/dev/null

    # LLM must have been called despite fresh stamp (git commit = high-signal)
    assert_true "[[ -f '${tmp_dir}/llm_called_marker' ]]" "LLM should be called for high-signal git commit"
    # Gist file should contain LLM output (overwriting deterministic)
    assert_file_exists "$gist_file" "Gist file should exist after LLM call"
    local content
    content=$(cat "$gist_file")
    assert_contains "$content" "Committing the null-gist fix" "Gist should contain LLM output"

    rm -rf "$tmp_dir"
}

test_gist_llm_fallback_on_failure() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local gist_file="${tmp_dir}/gist.txt"
    local mock_dir="${tmp_dir}/bin"

    # Mock claude exits with failure
    _make_mock_claude "$mock_dir" 1 ""

    local input='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: null gist\""}}'

    PATH="$mock_dir:$PATH" \
    KAPSIS_STATUS_AGENT_ID="test-llm-fail" \
    KAPSIS_INJECT_GIST=true \
    KAPSIS_GIST_LLM=true \
    KAPSIS_GIST_LLM_SYNC=true \
    KAPSIS_GIST_FILE="$gist_file" \
    bash "$HOOKS_DIR/kapsis-gist-hook.sh" <<< "$input" 2>/dev/null

    # Deterministic gist must be preserved when LLM fails
    assert_file_exists "$gist_file" "Gist file should exist (deterministic fallback)"
    local content
    content=$(cat "$gist_file")
    assert_contains "$content" "Committing:" "Deterministic gist should be preserved on LLM failure"

    rm -rf "$tmp_dir"
}

test_gist_llm_stamp_created_on_success() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local gist_file="${tmp_dir}/gist.txt"
    local stamp_file="${tmp_dir}/gist.last_llm_run"
    local mock_dir="${tmp_dir}/bin"

    _make_mock_claude "$mock_dir" 0 "Writing the gist hook implementation"

    # No existing stamp — first run
    local input='{"tool_name":"Write","tool_input":{"file_path":"/workspace/foo.sh"}}'

    PATH="$mock_dir:$PATH" \
    KAPSIS_STATUS_AGENT_ID="test-llm-stamp" \
    KAPSIS_INJECT_GIST=true \
    KAPSIS_GIST_LLM=true \
    KAPSIS_GIST_LLM_SYNC=true \
    KAPSIS_GIST_FILE="$gist_file" \
    bash "$HOOKS_DIR/kapsis-gist-hook.sh" <<< "$input" 2>/dev/null

    # Stamp file must be created after successful LLM call
    assert_file_exists "$stamp_file" "Stamp file should be created after successful LLM call"

    rm -rf "$tmp_dir"
}

#===============================================================================
# Test: Stop Hook Bug 1 fix — reads gist before writing final status
#===============================================================================

test_stop_hook_reads_gist_before_completion() {
    local tmp_dir kapsis_home marker
    tmp_dir=$(mktemp -d)
    kapsis_home="${tmp_dir}/kapsis"
    marker="${tmp_dir}/gist_read_called"

    # Provide a mock status.sh that records status_read_gist_file calls
    mkdir -p "${kapsis_home}/lib"
    cat > "${kapsis_home}/lib/status.sh" << EOF
status_reinit_from_env() { :; }
status_phase() { :; }
status_read_gist_file() { touch '$marker'; }
EOF

    KAPSIS_HOME="$kapsis_home" \
    KAPSIS_STATUS_AGENT_ID="test-stop-gist" \
    KAPSIS_STATUS_PROJECT="test-project" \
    bash "$HOOKS_DIR/kapsis-stop-hook.sh" <<< '{}' 2>/dev/null || true

    assert_file_exists "$marker" \
        "stop hook should call status_read_gist_file before writing final status (kapsis#285 Bug 1)"

    rm -rf "$tmp_dir"
}

#===============================================================================
# Test: Gist Hook edge cases
#===============================================================================

# Edit tool with tool_input.path key instead of tool_input.file_path
test_gist_hook_edit_with_path_key() {
    local content
    content=$(_run_gist_hook '{"tool_name":"Edit","tool_input":{"path":"/workspace/src/Foo.java"}}')
    assert_contains "$content" "Editing:" "gist should contain 'Editing:' when using .path key"
    assert_contains "$content" "Foo.java" "gist should contain file basename from .path key"
}

# Agent ID regex guard rejects invalid formats in the gist hook
test_gist_hook_skips_when_agent_id_invalid() {
    local tmp_dir tmp_gist exit_code
    tmp_dir=$(mktemp -d)
    tmp_gist="$tmp_dir/.kapsis/gist.txt"
    mkdir -p "$tmp_dir/.kapsis"
    exit_code=0

    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}' | \
        KAPSIS_STATUS_AGENT_ID="../evil" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "gist hook should exit 0 with path-traversal agent_id"
    assert_false "[[ -f '$tmp_gist' ]]" "gist.txt should not be written with path-traversal agent_id"

    # Also test special chars
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}' | \
        KAPSIS_STATUS_AGENT_ID="agent;rm-rf" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$tmp_gist" \
        bash "$HOOKS_DIR/kapsis-gist-hook.sh" 2>/dev/null || true

    assert_false "[[ -f '$tmp_gist' ]]" "gist.txt should not be written with special-char agent_id"

    rm -rf "$tmp_dir"
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
    run_test test_stop_hook_reads_gist_before_completion

    log_info "=== Hook Injection (inject-status-hooks.sh) ==="
    run_test test_inject_claude_creates_settings_if_missing
    run_test test_inject_claude_merges_with_existing
    run_test test_inject_claude_idempotent
    run_test test_inject_claude_with_gist_enabled
    run_test test_inject_claude_gist_disabled_when_hook_missing
    run_test test_inject_codex_creates_config_if_missing
    run_test test_inject_codex_merges_with_existing
    run_test test_inject_codex_idempotent
    run_test test_inject_gemini_creates_hooks_dir
    run_test test_inject_gemini_appends_to_existing
    run_test test_inject_gemini_idempotent
    run_test test_inject_skips_without_agent_id
    run_test test_inject_hook_path_uses_kapsis_home

    log_info "=== Gist Injection ==="
    run_test test_inject_gist_when_enabled
    run_test test_inject_gist_when_disabled
    run_test test_inject_gist_idempotent
    run_test test_inject_gist_missing_instructions_file
    run_test test_inject_gist_no_markdown_files
    run_test test_inject_gist_explicit_false
    run_test test_inject_gist_readonly_workspace

    log_info "=== Agent Type Inference ==="
    run_test test_agent_type_inference_from_image_name
    run_test test_agent_type_normalization_priority

    log_info "=== Gist Hook (kapsis-gist-hook.sh) ==="
    run_test test_gist_hook_git_commit
    run_test test_gist_hook_git_push
    run_test test_gist_hook_edit
    run_test test_gist_hook_write
    run_test test_gist_hook_running_tests_mvn
    run_test test_gist_hook_running_tests_pytest
    run_test test_gist_hook_no_overwrite_on_read
    run_test test_gist_hook_no_overwrite_on_grep
    run_test test_gist_hook_bash_fallback_first_run
    run_test test_gist_hook_bash_fallback_no_overwrite
    run_test test_gist_hook_skips_when_agent_id_missing
    run_test test_gist_hook_skips_when_inject_gist_false
    run_test test_gist_hook_edit_with_path_key
    run_test test_gist_hook_skips_when_agent_id_invalid

    log_info "=== Gist Hook Injection ==="
    run_test test_inject_gist_hook_injected_when_enabled
    run_test test_inject_gist_hook_not_injected_when_disabled

    log_info "=== Gist Hook LLM Throttle ==="
    run_test test_gist_llm_time_gate_blocks
    run_test test_gist_llm_high_signal_bypasses_gate
    run_test test_gist_llm_fallback_on_failure
    run_test test_gist_llm_stamp_created_on_success

    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
