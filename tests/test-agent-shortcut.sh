#!/usr/bin/env bash
#===============================================================================
# Test: Agent Shortcut (--agent flag)
#
# Verifies that the --agent shortcut correctly resolves to config files
# and displays the agent name in output.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_agent_claude() {
    log_test "Testing --agent claude"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "CLAUDE" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/claude.yaml" "Should use claude.yaml config"
    assert_contains "$output" "ANTHROPIC_API_KEY" "Should mention required API key" || true
}

test_agent_codex() {
    log_test "Testing --agent codex"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent codex --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "CODEX" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/codex.yaml" "Should use codex.yaml config"
}

test_agent_aider() {
    log_test "Testing --agent aider"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent aider --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "AIDER" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/aider.yaml" "Should use aider.yaml config"
}

test_agent_interactive() {
    log_test "Testing --agent interactive"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent interactive --interactive --dry-run 2>&1) || true

    assert_contains "$output" "INTERACTIVE" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/interactive.yaml" "Should use interactive.yaml config"
}

test_agent_display_in_banner() {
    log_test "Testing agent name in configuration summary"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    # In dry-run mode, check config summary shows agent (banner only shows during actual launch)
    assert_contains "$output" "Agent:         CLAUDE" "Config summary should show agent name"
}

test_agent_in_config_summary() {
    log_test "Testing agent in configuration summary"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent codex --task "test" --dry-run 2>&1) || true

    # Check configuration summary shows agent
    assert_contains "$output" "Agent:" "Configuration should show Agent line"
    assert_contains "$output" "CODEX" "Configuration should show agent name"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Agent Shortcut (--agent flag)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Setup
    setup_test_project

    # Run tests
    run_test test_agent_claude
    run_test test_agent_codex
    run_test test_agent_aider
    run_test test_agent_interactive
    run_test test_agent_display_in_banner
    run_test test_agent_in_config_summary

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
