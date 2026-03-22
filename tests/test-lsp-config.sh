#!/usr/bin/env bash
#===============================================================================
# Tests for LSP Server Configuration Injection
#
# Run: ./tests/test-lsp-config.sh
#===============================================================================

set -euo pipefail

# Load test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Script location
LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Temp directory for test fixtures
TEST_HOME=""

setup_test_home() {
    TEST_HOME=$(mktemp -d)
    mkdir -p "$TEST_HOME/.claude"
}

cleanup_test_home() {
    [[ -n "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
    TEST_HOME=""
    # Clean up env vars
    unset KAPSIS_LSP_SERVERS_JSON 2>/dev/null || true
    unset KAPSIS_AGENT_TYPE 2>/dev/null || true
    # Reset source guard so library can be re-sourced
    unset _KAPSIS_INJECT_LSP_CONFIG_LOADED 2>/dev/null || true
}

#===============================================================================
# Test: LSP Injection - Basic
#===============================================================================

test_lsp_injection_creates_settings_local() {
    setup_test_home

    # No settings.local.json exists yet
    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"java-functional-lsp","languages":{"java":[".java"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    assert_file_exists "$TEST_HOME/.claude/settings.local.json" "settings.local.json should be created"

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "lspServers" "Should contain lspServers key"
    assert_contains "$result" "java-functional-lsp" "Should contain the server command"
    assert_contains "$result" "extensionToLanguage" "Should have extensionToLanguage mapping"
    assert_contains "$result" '".java"' "Should map .java extension"

    cleanup_test_home
}

test_lsp_injection_merges_with_existing() {
    setup_test_home

    # Pre-existing settings.local.json with hooks (from inject-status-hooks.sh)
    cat > "$TEST_HOME/.claude/settings.local.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/opt/kapsis/hooks/kapsis-status-hook.sh"}]}
    ]
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"pyright":{"command":"pyright-langserver","args":["--stdio"],"languages":{"python":[".py",".pyi"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "hooks" "Existing hooks should be preserved"
    assert_contains "$result" "kapsis-status-hook" "Existing hook command should be preserved"
    assert_contains "$result" "lspServers" "lspServers should be added"
    assert_contains "$result" "pyright-langserver" "LSP server command should be present"

    cleanup_test_home
}

#===============================================================================
# Test: Language → Extension Mapping
#===============================================================================

test_lsp_languages_to_extension_mapping() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    # Multiple languages with multiple extensions
    export KAPSIS_LSP_SERVERS_JSON='{"ts-lsp":{"command":"typescript-language-server","args":["--stdio"],"languages":{"typescript":[".ts",".tsx"],"javascript":[".js",".jsx"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Verify inversion: languages.typescript: [".ts", ".tsx"] → extensionToLanguage: {".ts": "typescript", ".tsx": "typescript"}
    local ext_map
    ext_map=$(echo "$result" | jq -r '.lspServers["ts-lsp"].extensionToLanguage')
    assert_contains "$ext_map" '"typescript"' "Should map to typescript language"
    assert_contains "$ext_map" '"javascript"' "Should map to javascript language"

    # Check specific extension→language mappings
    local ts_lang
    ts_lang=$(echo "$result" | jq -r '.lspServers["ts-lsp"].extensionToLanguage[".ts"]')
    assert_equals "typescript" "$ts_lang" ".ts should map to typescript"

    local jsx_lang
    jsx_lang=$(echo "$result" | jq -r '.lspServers["ts-lsp"].extensionToLanguage[".jsx"]')
    assert_equals "javascript" "$jsx_lang" ".jsx should map to javascript"

    cleanup_test_home
}

#===============================================================================
# Test: Optional Fields
#===============================================================================

test_lsp_optional_fields_omitted() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    # Minimal config: only command and languages (no args, env, etc.)
    export KAPSIS_LSP_SERVERS_JSON='{"simple-lsp":{"command":"simple-lsp","languages":{"java":[".java"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Optional fields should NOT be present when not specified
    local server_json
    server_json=$(echo "$result" | jq '.lspServers["simple-lsp"]')
    assert_not_contains "$server_json" '"args"' "args should be omitted when not specified"
    assert_not_contains "$server_json" '"env"' "env should be omitted when not specified"
    assert_not_contains "$server_json" '"initializationOptions"' "initializationOptions should be omitted"
    assert_not_contains "$server_json" '"settings"' "settings should be omitted when not specified"

    # Required fields should be present
    assert_contains "$server_json" '"command"' "command should be present"
    assert_contains "$server_json" '"extensionToLanguage"' "extensionToLanguage should be present"

    cleanup_test_home
}

test_lsp_env_and_init_options() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"ts-lsp":{"command":"ts-lsp","languages":{"typescript":[".ts"]},"env":{"NODE_OPTIONS":"--max-old-space-size=4096"},"initialization_options":{"preferences":{"importModuleSpecifierPreference":"relative"}},"settings":{"typescript.format.semicolons":"insert"}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")

    # env should be passed through
    local env_val
    env_val=$(echo "$result" | jq -r '.lspServers["ts-lsp"].env.NODE_OPTIONS')
    assert_equals "--max-old-space-size=4096" "$env_val" "env should be passed through"

    # initialization_options → initializationOptions
    local init_val
    init_val=$(echo "$result" | jq -r '.lspServers["ts-lsp"].initializationOptions.preferences.importModuleSpecifierPreference')
    assert_equals "relative" "$init_val" "initialization_options should map to initializationOptions"

    # settings should be passed through
    local settings_val
    settings_val=$(echo "$result" | jq -r '.lspServers["ts-lsp"].settings."typescript.format.semicolons"')
    assert_equals "insert" "$settings_val" "settings should be passed through"

    cleanup_test_home
}

#===============================================================================
# Test: Multiple Servers
#===============================================================================

test_lsp_multiple_servers() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"java-functional-lsp","languages":{"java":[".java"]}},"pyright":{"command":"pyright-langserver","args":["--stdio"],"languages":{"python":[".py"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Both servers should be present
    local server_count
    server_count=$(echo "$result" | jq '.lspServers | keys | length')
    assert_equals "2" "$server_count" "Should have 2 LSP servers"
    assert_contains "$result" "java-functional-lsp" "Java LSP should be present"
    assert_contains "$result" "pyright-langserver" "Pyright LSP should be present"

    cleanup_test_home
}

#===============================================================================
# Test: Agent Type Handling
#===============================================================================

test_lsp_skipped_for_non_claude() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="codex-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"java-lsp","languages":{"java":[".java"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 for non-Claude agents"

    # settings.local.json should NOT be created
    assert_file_not_exists "$TEST_HOME/.claude/settings.local.json" "Should not create settings.local.json for non-Claude agents"

    cleanup_test_home
}

test_lsp_skipped_when_empty() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON="{}"

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config
    local exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when no LSP servers"

    # settings.local.json should NOT be created (nothing to inject)
    assert_file_not_exists "$TEST_HOME/.claude/settings.local.json" "Should not create settings.local.json when empty"

    cleanup_test_home
}

test_lsp_runs_for_claude_variants() {
    for agent_type in claude claude-cli claude-code; do
        setup_test_home

        export HOME="$TEST_HOME"
        export KAPSIS_AGENT_TYPE="$agent_type"
        export KAPSIS_LSP_SERVERS_JSON='{"test-lsp":{"command":"test-lsp","languages":{"test":[".test"]}}}'

        source "$LIB_DIR/inject-lsp-config.sh"
        inject_lsp_config

        local result
        result=$(cat "$TEST_HOME/.claude/settings.local.json")
        assert_contains "$result" "test-lsp" "[$agent_type] LSP server should be injected"

        cleanup_test_home
    done
}

#===============================================================================
# Test: Idempotency
#===============================================================================

test_lsp_idempotent() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"java-functional-lsp","languages":{"java":[".java"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"

    # Run injection twice
    inject_lsp_config
    local first_result
    first_result=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Reset source guard to re-source
    unset _KAPSIS_INJECT_LSP_CONFIG_LOADED
    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config

    local second_result
    second_result=$(cat "$TEST_HOME/.claude/settings.local.json")

    assert_equals "$first_result" "$second_result" "Running injection twice should produce identical output"

    # Should still have exactly one server
    local server_count
    server_count=$(echo "$second_result" | jq '.lspServers | keys | length')
    assert_equals "1" "$server_count" "Should still have exactly 1 LSP server after double injection"

    cleanup_test_home
}

#===============================================================================
# Test Runner
#===============================================================================

run_tests() {
    print_test_header "LSP Server Configuration Injection Test Suite"

    log_info "=== Basic Injection ==="
    run_test test_lsp_injection_creates_settings_local
    run_test test_lsp_injection_merges_with_existing

    log_info "=== Language Mapping ==="
    run_test test_lsp_languages_to_extension_mapping

    log_info "=== Optional Fields ==="
    run_test test_lsp_optional_fields_omitted
    run_test test_lsp_env_and_init_options

    log_info "=== Multiple Servers ==="
    run_test test_lsp_multiple_servers

    log_info "=== Agent Type Handling ==="
    run_test test_lsp_skipped_for_non_claude
    run_test test_lsp_skipped_when_empty
    run_test test_lsp_runs_for_claude_variants

    log_info "=== Idempotency ==="
    run_test test_lsp_idempotent

    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
