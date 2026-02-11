#!/usr/bin/env bash
#===============================================================================
# Tests for Claude Agent Config Filtering (Hook & MCP Server Whitelisting)
#
# Run: ./tests/test-filter-agent-config.sh
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
    unset KAPSIS_CLAUDE_HOOKS_INCLUDE 2>/dev/null || true
    unset KAPSIS_CLAUDE_MCP_INCLUDE 2>/dev/null || true
    unset KAPSIS_AGENT_TYPE 2>/dev/null || true
}

#===============================================================================
# Test: Hook Filtering
#===============================================================================

test_hook_include_filters_correctly() {
    setup_test_home

    # Create settings.json with multiple hooks
    cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/usr/local/bin/block-secrets.sh", "timeout": 5}]
      },
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/tmp/claude-island-state.py --socket /tmp/claude-island.sock", "timeout": 3}]
      }
    ],
    "Stop": [
      {
        "hooks": [{"type": "command", "command": "/usr/local/bin/claudeignore-cleanup.sh"}]
      }
    ]
  }
}
EOF

    # Whitelist only block-secrets and claudeignore
    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="block-secrets,claudeignore"

    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_hooks

    # Verify: block-secrets kept, claude-island-state removed, claudeignore kept
    local result
    result=$(cat "$TEST_HOME/.claude/settings.json")

    assert_contains "$result" "block-secrets" "block-secrets hook should be kept"
    assert_not_contains "$result" "claude-island-state" "claude-island-state hook should be removed"
    assert_contains "$result" "claudeignore" "claudeignore hook should be kept"

    cleanup_test_home
}

test_hook_include_empty_means_no_filter() {
    setup_test_home

    cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/usr/local/bin/some-hook.sh"}]
      }
    ]
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE=""

    # Reset source guard to re-source
    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_hooks

    local result
    result=$(cat "$TEST_HOME/.claude/settings.json")
    assert_contains "$result" "some-hook" "All hooks should pass through when include is empty"

    cleanup_test_home
}

test_hook_include_no_settings_file() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="block-secrets"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"

    # Should not fail when settings.json doesn't exist
    filter_claude_hooks
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should return 0 when no settings.json"

    cleanup_test_home
}

test_hook_include_no_hooks_key() {
    setup_test_home

    cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read", "Write"]
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="block-secrets"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_hooks

    local result
    result=$(cat "$TEST_HOME/.claude/settings.json")
    assert_contains "$result" "permissions" "Non-hook content should be preserved"
    assert_not_contains "$result" "hooks" "No hooks key should be added"

    cleanup_test_home
}

test_hook_include_removes_all_when_none_match() {
    setup_test_home

    cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/tmp/claude-island-state.py"}]
      }
    ]
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="nonexistent-hook"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_hooks

    local result
    result=$(cat "$TEST_HOME/.claude/settings.json")
    assert_not_contains "$result" "claude-island-state" "Non-matching hook should be removed"

    cleanup_test_home
}

test_hook_include_multiple_event_types() {
    setup_test_home

    cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/bin/block-secrets"}]
      },
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "/bin/unwanted-hook"}]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "/bin/validate-bash"}]
      }
    ],
    "Stop": [
      {
        "hooks": [{"type": "command", "command": "/bin/cleanup-secrets"}]
      }
    ]
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="block-secrets,validate-bash,cleanup-secrets"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_hooks

    local result
    result=$(cat "$TEST_HOME/.claude/settings.json")
    assert_contains "$result" "block-secrets" "block-secrets in PostToolUse should be kept"
    assert_not_contains "$result" "unwanted-hook" "unwanted-hook in PostToolUse should be removed"
    assert_contains "$result" "validate-bash" "validate-bash in PreToolUse should be kept"
    assert_contains "$result" "cleanup-secrets" "cleanup-secrets in Stop should be kept"

    cleanup_test_home
}

#===============================================================================
# Test: MCP Server Filtering
#===============================================================================

test_mcp_include_filters_correctly() {
    setup_test_home

    cat > "$TEST_HOME/.claude.json" << 'EOF'
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    },
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp"]
    },
    "atlassian": {
      "command": "npx",
      "args": ["@anthropic/atlassian-mcp"]
    },
    "playwright": {
      "command": "npx",
      "args": ["@anthropic/playwright-mcp"]
    }
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_MCP_INCLUDE="context7,atlassian"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_mcp_servers

    local result
    result=$(cat "$TEST_HOME/.claude.json")
    assert_contains "$result" "context7" "context7 should be kept"
    assert_contains "$result" "atlassian" "atlassian should be kept"
    assert_not_contains "$result" "chrome-devtools" "chrome-devtools should be removed"
    assert_not_contains "$result" "playwright" "playwright should be removed"

    cleanup_test_home
}

test_mcp_include_empty_means_no_filter() {
    setup_test_home

    cat > "$TEST_HOME/.claude.json" << 'EOF'
{
  "mcpServers": {
    "context7": {"command": "npx"},
    "chrome-devtools": {"command": "npx"}
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_MCP_INCLUDE=""

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_mcp_servers

    local result
    result=$(cat "$TEST_HOME/.claude.json")
    assert_contains "$result" "context7" "context7 should pass through"
    assert_contains "$result" "chrome-devtools" "chrome-devtools should pass through"

    cleanup_test_home
}

test_mcp_include_no_config_file() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_MCP_INCLUDE="context7"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"

    filter_claude_mcp_servers
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should return 0 when no .claude.json"

    cleanup_test_home
}

test_mcp_include_no_mcpservers_key() {
    setup_test_home

    cat > "$TEST_HOME/.claude.json" << 'EOF'
{
  "projects": {}
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_MCP_INCLUDE="context7"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_mcp_servers

    local result
    result=$(cat "$TEST_HOME/.claude.json")
    assert_contains "$result" "projects" "Non-MCP content should be preserved"

    cleanup_test_home
}

test_mcp_include_exact_match_only() {
    setup_test_home

    cat > "$TEST_HOME/.claude.json" << 'EOF'
{
  "mcpServers": {
    "context7": {"command": "npx"},
    "context7-extended": {"command": "npx"}
  }
}
EOF

    export HOME="$TEST_HOME"
    export KAPSIS_CLAUDE_MCP_INCLUDE="context7"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_mcp_servers

    local result
    result=$(cat "$TEST_HOME/.claude.json")
    assert_contains "$result" "context7" "Exact match context7 should be kept"
    assert_not_contains "$result" "context7-extended" "context7-extended should NOT match (exact match only)"

    cleanup_test_home
}

#===============================================================================
# Test: Entry Point (filter_claude_agent_config)
#===============================================================================

test_entry_point_skips_non_claude_agents() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="codex-cli"
    export KAPSIS_CLAUDE_HOOKS_INCLUDE="block-secrets"

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_agent_config

    # Should return successfully without doing anything
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should skip non-Claude agents"

    cleanup_test_home
}

test_entry_point_skips_when_no_filters() {
    setup_test_home

    export HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"
    unset KAPSIS_CLAUDE_HOOKS_INCLUDE 2>/dev/null || true
    unset KAPSIS_CLAUDE_MCP_INCLUDE 2>/dev/null || true

    unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
    source "$LIB_DIR/filter-agent-config.sh"
    filter_claude_agent_config

    local exit_code=$?
    assert_equals "0" "$exit_code" "Should skip when no filters configured"

    cleanup_test_home
}

test_entry_point_runs_for_claude_variants() {
    # Test that all Claude agent type variants are recognized
    for agent_type in claude claude-cli claude-code; do
        setup_test_home

        cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/bin/keep-me"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "/bin/remove-me"}]}
    ]
  }
}
EOF

        export HOME="$TEST_HOME"
        export KAPSIS_AGENT_TYPE="$agent_type"
        export KAPSIS_CLAUDE_HOOKS_INCLUDE="keep-me"

        unset _KAPSIS_FILTER_AGENT_CONFIG_LOADED
        source "$LIB_DIR/filter-agent-config.sh"
        filter_claude_agent_config

        local result
        result=$(cat "$TEST_HOME/.claude/settings.json")
        assert_contains "$result" "keep-me" "[$agent_type] Matching hook should be kept"
        assert_not_contains "$result" "remove-me" "[$agent_type] Non-matching hook should be removed"

        cleanup_test_home
    done
}

#===============================================================================
# Test Runner
#===============================================================================

run_tests() {
    print_test_header "Claude Agent Config Filtering Test Suite"

    log_info "=== Hook Whitelisting ==="
    run_test test_hook_include_filters_correctly
    run_test test_hook_include_empty_means_no_filter
    run_test test_hook_include_no_settings_file
    run_test test_hook_include_no_hooks_key
    run_test test_hook_include_removes_all_when_none_match
    run_test test_hook_include_multiple_event_types

    log_info "=== MCP Server Whitelisting ==="
    run_test test_mcp_include_filters_correctly
    run_test test_mcp_include_empty_means_no_filter
    run_test test_mcp_include_no_config_file
    run_test test_mcp_include_no_mcpservers_key
    run_test test_mcp_include_exact_match_only

    log_info "=== Entry Point ==="
    run_test test_entry_point_skips_non_claude_agents
    run_test test_entry_point_skips_when_no_filters
    run_test test_entry_point_runs_for_claude_variants

    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
