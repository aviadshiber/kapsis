#!/usr/bin/env bash
#===============================================================================
# Test: Unknown Agent Error
#
# Verifies that using an unknown agent name produces a helpful error message
# with available agents listed.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_unknown_agent_error() {
    log_test "Testing error on unknown agent"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent nonexistent --task "test" 2>&1) || exit_code=$?

    # Should fail
    assert_not_equals 0 "$exit_code" "Should exit with non-zero code"

    # Should show error
    assert_contains "$output" "Unknown agent" "Should mention unknown agent"
    assert_contains "$output" "nonexistent" "Should show the invalid agent name"
}

test_unknown_agent_shows_available() {
    log_test "Testing that error shows available agents"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent foobar --task "test" 2>&1) || true

    # Should list available agents
    assert_contains "$output" "claude" "Should list claude as available"
    assert_contains "$output" "codex" "Should list codex as available"
    assert_contains "$output" "aider" "Should list aider as available"
    assert_contains "$output" "interactive" "Should list interactive as available"
}

test_unknown_agent_suggests_config() {
    log_test "Testing that error suggests --config alternative"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent invalid --task "test" 2>&1) || true

    # Should suggest using --config
    assert_contains "$output" "--config" "Should suggest using --config flag"
}

test_similar_agent_typo() {
    log_test "Testing typo in agent name"

    local output
    local exit_code=0

    # Common typos
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent cloude --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on typo"
    assert_contains "$output" "Unknown agent" "Should show unknown agent error"
}

test_empty_agent_name() {
    log_test "Testing empty agent name"

    local output
    local exit_code=0

    # This might fail during argument parsing
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent "" --task "test" 2>&1) || exit_code=$?

    # Should not succeed
    assert_not_equals 0 "$exit_code" "Should fail on empty agent name"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Unknown Agent Error Handling"

    # Setup
    setup_test_project

    # Run tests
    run_test test_unknown_agent_error
    run_test test_unknown_agent_shows_available
    run_test test_unknown_agent_suggests_config
    run_test test_similar_agent_typo
    run_test test_empty_agent_name

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
