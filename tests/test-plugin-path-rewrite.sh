#!/usr/bin/env bash
#===============================================================================
# Tests for Plugin Path Rewriting (Issue #217)
#
# Verifies that host-absolute installPath values in installed_plugins.json
# are rewritten to container HOME during container startup.
#
# Run: ./tests/test-plugin-path-rewrite.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Save original values to restore after each test
_ORIG_HOME="$HOME"

setup_test_home() {
    TEST_HOME=$(mktemp -d)
    mkdir -p "$TEST_HOME/.claude/plugins"
}

cleanup_test_home() {
    HOME="$_ORIG_HOME"
    [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
    TEST_HOME=""
    unset KAPSIS_HOST_HOME 2>/dev/null || true
    unset KAPSIS_AGENT_TYPE 2>/dev/null || true
    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED 2>/dev/null || true
}

#===============================================================================
# TEST: Basic Path Rewriting
#===============================================================================

test_rewrites_install_paths() {
    log_test "Testing basic macOS host path rewrite"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "sync-plugins@marketplace": [
      {
        "scope": "user",
        "installPath": "/Users/hostuser/.claude/plugins/cache/marketplace/sync-plugins/1.0.0",
        "version": "1.0.0",
        "installedAt": "2026-03-18T03:55:37.887Z"
      }
    ],
    "other-plugin@marketplace": [
      {
        "scope": "user",
        "installPath": "/Users/hostuser/.claude/plugins/cache/marketplace/other-plugin/2.0.0",
        "version": "2.0.0",
        "installedAt": "2026-03-19T10:00:00.000Z"
      }
    ]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_not_contains "$result" "/Users/hostuser" "Host path should be replaced"
    assert_contains "$result" "$TEST_HOME/.claude/plugins/cache" "Container path should be present"
    assert_contains "$result" "sync-plugins" "Plugin name should be preserved"
    assert_contains "$result" "other-plugin" "Other plugin name should be preserved"
    assert_contains "$result" '"version": 2' "Version field should be preserved"

    cleanup_test_home
}

test_rewrites_linux_host_paths() {
    log_test "Testing Linux host path rewrite"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "my-plugin@source": [
      {
        "scope": "user",
        "installPath": "/home/linuxuser/.claude/plugins/cache/source/my-plugin/1.0.0",
        "version": "1.0.0"
      }
    ]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/home/linuxuser"
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_not_contains "$result" "/home/linuxuser" "Linux host path should be replaced"
    assert_contains "$result" "$TEST_HOME/.claude/plugins/cache" "Container path should be present"

    cleanup_test_home
}

#===============================================================================
# TEST: Edge Cases
#===============================================================================

test_no_host_home_env_skips() {
    log_test "Testing skip when KAPSIS_HOST_HOME not set"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "plugin@source": [{"installPath": "/Users/foo/.claude/plugins/cache/source/plugin/1.0.0"}]
  }
}
EOF

    HOME="$TEST_HOME"
    unset KAPSIS_HOST_HOME 2>/dev/null || true
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should return 0 when KAPSIS_HOST_HOME not set"

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_contains "$result" "/Users/foo" "Paths should remain unchanged"

    cleanup_test_home
}

test_no_plugins_file_skips() {
    log_test "Testing skip when no plugins file exists"
    setup_test_home

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-cli"

    rm -f "$TEST_HOME/.claude/plugins/installed_plugins.json"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should return 0 when no plugins file exists"

    cleanup_test_home
}

test_same_home_skips() {
    log_test "Testing skip when host HOME matches container HOME"
    setup_test_home

    # Write JSON with TEST_HOME as the path (simulating same HOME)
    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << EOF
{
  "version": 2,
  "plugins": {
    "plugin@source": [{"installPath": "$TEST_HOME/.claude/plugins/cache/source/plugin/1.0.0"}]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="$TEST_HOME"
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should return 0 when homes match"

    cleanup_test_home
}

test_skips_non_claude_agents() {
    log_test "Testing skip for non-Claude agents"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "plugin@source": [{"installPath": "/Users/hostuser/.claude/plugins/cache/source/plugin/1.0.0"}]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="codex-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should skip non-Claude agents"

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_contains "$result" "/Users/hostuser" "Paths should not be changed for non-Claude"

    cleanup_test_home
}

test_preserves_non_installpath_fields() {
    log_test "Testing that non-installPath fields are preserved"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "plugin@source": [
      {
        "scope": "user",
        "installPath": "/Users/hostuser/.claude/plugins/cache/source/plugin/1.0.0",
        "version": "1.0.0",
        "installedAt": "2026-03-18T03:55:37.887Z",
        "lastUpdated": "2026-03-18T03:55:37.887Z",
        "gitCommitSha": "abc123def456"
      }
    ]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-code"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_contains "$result" '"scope": "user"' "scope field should be preserved"
    assert_contains "$result" '"version": "1.0.0"' "version field should be preserved"
    assert_contains "$result" '"installedAt"' "installedAt field should be preserved"
    assert_contains "$result" '"gitCommitSha": "abc123def456"' "gitCommitSha should be preserved"

    cleanup_test_home
}

test_no_plugins_key_in_json() {
    log_test "Testing JSON with no plugins key"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should handle JSON with no plugins key"

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_contains "$result" '"version": 2' "Version should be preserved"

    cleanup_test_home
}

test_all_claude_variants() {
    log_test "Testing all Claude agent type variants"

    local agent_type
    for agent_type in claude claude-cli claude-code; do
        setup_test_home

        cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "plugin@source": [{"installPath": "/Users/hostuser/.claude/plugins/cache/source/plugin/1.0.0"}]
  }
}
EOF

        HOME="$TEST_HOME"
        export KAPSIS_HOST_HOME="/Users/hostuser"
        export KAPSIS_AGENT_TYPE="$agent_type"

        unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
        source "$LIB_DIR/rewrite-plugin-paths.sh"
        rewrite_plugin_paths

        local result
        result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
        assert_not_contains "$result" "/Users/hostuser" "[$agent_type] Host path should be replaced"
        assert_contains "$result" "$TEST_HOME/.claude/plugins/cache" "[$agent_type] Container path should be present"

        cleanup_test_home
    done
}

test_multi_version_plugin_entries() {
    log_test "Testing multi-version plugin entries (array with >1 entry)"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "my-plugin@source": [
      {
        "scope": "user",
        "installPath": "/Users/hostuser/.claude/plugins/cache/source/my-plugin/1.0.0",
        "version": "1.0.0"
      },
      {
        "scope": "user",
        "installPath": "/Users/hostuser/.claude/plugins/cache/source/my-plugin/2.0.0",
        "version": "2.0.0"
      }
    ]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-cli"

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths

    local result
    result=$(cat "$TEST_HOME/.claude/plugins/installed_plugins.json")
    assert_not_contains "$result" "/Users/hostuser" "Both version paths should be replaced"
    assert_contains "$result" "$TEST_HOME/.claude/plugins/cache/source/my-plugin/1.0.0" "v1.0.0 path should be rewritten"
    assert_contains "$result" "$TEST_HOME/.claude/plugins/cache/source/my-plugin/2.0.0" "v2.0.0 path should be rewritten"

    cleanup_test_home
}

test_sets_claude_home_env() {
    log_test "Testing CLAUDE_HOME is exported after rewrite"
    setup_test_home

    cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" << 'EOF'
{
  "version": 2,
  "plugins": {
    "plugin@source": [{"installPath": "/Users/hostuser/.claude/plugins/cache/source/plugin/1.0.0"}]
  }
}
EOF

    HOME="$TEST_HOME"
    export KAPSIS_HOST_HOME="/Users/hostuser"
    export KAPSIS_AGENT_TYPE="claude-cli"
    unset CLAUDE_HOME 2>/dev/null || true

    unset _KAPSIS_REWRITE_PLUGIN_PATHS_LOADED
    source "$LIB_DIR/rewrite-plugin-paths.sh"
    rewrite_plugin_paths

    assert_equals "$TEST_HOME/.claude" "$CLAUDE_HOME" "CLAUDE_HOME should be set to container .claude dir"

    cleanup_test_home
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Plugin Path Rewrite (Issue #217)"

    log_info "=== Basic Path Rewriting ==="
    run_test test_rewrites_install_paths
    run_test test_rewrites_linux_host_paths

    log_info "=== Edge Cases ==="
    run_test test_no_host_home_env_skips
    run_test test_no_plugins_file_skips
    run_test test_same_home_skips
    run_test test_skips_non_claude_agents
    run_test test_preserves_non_installpath_fields
    run_test test_no_plugins_key_in_json
    run_test test_all_claude_variants
    run_test test_multi_version_plugin_entries
    run_test test_sets_claude_home_env

    print_summary
}

main "$@"
