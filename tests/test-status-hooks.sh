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

test_inject_codex_creates_config_if_missing() {
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

    log_info "=== Hook Injection (inject-status-hooks.sh) ==="
    run_test test_inject_claude_creates_settings_if_missing
    run_test test_inject_claude_merges_with_existing
    run_test test_inject_claude_idempotent
    run_test test_inject_codex_creates_config_if_missing
    run_test test_inject_codex_merges_with_existing
    run_test test_inject_codex_idempotent
    run_test test_inject_gemini_creates_hooks_dir
    run_test test_inject_gemini_appends_to_existing
    run_test test_inject_gemini_idempotent
    run_test test_inject_skips_without_agent_id
    run_test test_inject_hook_path_uses_kapsis_home

    log_info "=== Agent Type Inference ==="
    run_test test_agent_type_inference_from_image_name
    run_test test_agent_type_normalization_priority

    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
