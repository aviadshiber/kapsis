#!/usr/bin/env bash
#===============================================================================
# Test: Post-Container Exit Code Handling (Regression test for #81)
#
# Verifies that when post_container_worktree/post_container_overlay returns
# a non-zero exit code, the final exit code and status_complete are updated
# correctly to reflect the failure.
#
# Bug #81: When container exited successfully but post-container operations
# (e.g., git push) failed, launch-agent.sh would incorrectly report success
# because it only checked EXIT_CODE and didn't capture the return value from
# post_container_* functions.
#
# This test verifies the fix ensures proper failure reporting.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_post_container_exit_code_captured() {
    log_test "Post-container exit code is captured when non-zero"

    # This test verifies that POST_EXIT_CODE is set when post_container_worktree
    # returns non-zero. We test this by examining the code structure rather than
    # executing it (since full execution requires complex setup).

    # Check that POST_EXIT_CODE=$? appears after post_container_worktree call
    if grep -A 1 'post_container_worktree$' "$LAUNCH_AGENT_SCRIPT" | grep -q 'POST_EXIT_CODE=\$?'; then
        log_info "  ✓ POST_EXIT_CODE captured for post_container_worktree"
    else
        log_fail "POST_EXIT_CODE not captured after post_container_worktree"
        return 1
    fi

    # Check that POST_EXIT_CODE=$? appears after post_container_overlay call
    if grep -A 1 'post_container_overlay$' "$LAUNCH_AGENT_SCRIPT" | grep -q 'POST_EXIT_CODE=\$?'; then
        log_info "  ✓ POST_EXIT_CODE captured for post_container_overlay"
    else
        log_fail "POST_EXIT_CODE not captured after post_container_overlay"
        return 1
    fi
}

test_final_exit_code_combines_both() {
    log_test "FINAL_EXIT_CODE combines container and post-container exit codes"

    # Verify that FINAL_EXIT_CODE is set based on both EXIT_CODE and POST_EXIT_CODE
    # The logic should be:
    # - If EXIT_CODE != 0, use EXIT_CODE
    # - Else if POST_EXIT_CODE != 0, use POST_EXIT_CODE
    # - Else use 0

    # Check for the logic that sets FINAL_EXIT_CODE when EXIT_CODE is non-zero
    if grep -q 'if \[\[ "\$EXIT_CODE" -ne 0 \]\]; then' "$LAUNCH_AGENT_SCRIPT" && \
       grep -A 1 'if \[\[ "\$EXIT_CODE" -ne 0 \]\]; then' "$LAUNCH_AGENT_SCRIPT" | grep -q 'FINAL_EXIT_CODE=\$EXIT_CODE'; then
        log_info "  ✓ FINAL_EXIT_CODE set to EXIT_CODE when container fails"
    else
        log_fail "FINAL_EXIT_CODE not properly set for container failure"
        return 1
    fi

    # Check for the logic that sets FINAL_EXIT_CODE when POST_EXIT_CODE is non-zero
    if grep -q 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]; then' "$LAUNCH_AGENT_SCRIPT" && \
       grep -A 1 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]; then' "$LAUNCH_AGENT_SCRIPT" | grep -q 'FINAL_EXIT_CODE=\$POST_EXIT_CODE'; then
        log_info "  ✓ FINAL_EXIT_CODE set to POST_EXIT_CODE when post-container fails"
    else
        log_fail "FINAL_EXIT_CODE not properly set for post-container failure"
        return 1
    fi

    # Check for the logic that sets FINAL_EXIT_CODE to 0 when both succeed
    if grep -q 'else' "$LAUNCH_AGENT_SCRIPT" | tail -1 && \
       grep -A 1 'else$' "$LAUNCH_AGENT_SCRIPT" | grep -q 'FINAL_EXIT_CODE=0'; then
        log_info "  ✓ FINAL_EXIT_CODE set to 0 when both succeed"
    else
        log_fail "FINAL_EXIT_CODE not properly set for success case"
        return 1
    fi
}

test_exit_uses_final_exit_code() {
    log_test "Script exits with FINAL_EXIT_CODE instead of EXIT_CODE"

    # Before the fix, the script would exit with $EXIT_CODE
    # After the fix, it should exit with $FINAL_EXIT_CODE

    # Check that the script exits with FINAL_EXIT_CODE
    if grep -q '^    exit \$FINAL_EXIT_CODE$' "$LAUNCH_AGENT_SCRIPT"; then
        log_info "  ✓ Script exits with FINAL_EXIT_CODE"
    else
        log_fail "Script does not exit with FINAL_EXIT_CODE"
        return 1
    fi

    # Verify that the old "exit $EXIT_CODE" pattern is not present at the end of main()
    # (it should have been replaced with "exit $FINAL_EXIT_CODE")
    if tail -50 "$LAUNCH_AGENT_SCRIPT" | grep -q '^    exit \$EXIT_CODE$'; then
        log_fail "Script still has 'exit \$EXIT_CODE' instead of 'exit \$FINAL_EXIT_CODE'"
        return 1
    fi
}

test_status_complete_called_with_post_exit_code() {
    log_test "status_complete called with correct exit code when post-container fails"

    # When POST_EXIT_CODE is non-zero, status_complete should be called with
    # POST_EXIT_CODE and a message indicating post-container failure

    # Look for the pattern where status_complete is called with POST_EXIT_CODE
    if grep -A 3 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]; then' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'status_complete.*POST_EXIT_CODE.*Post-container operations failed'; then
        log_info "  ✓ status_complete called with POST_EXIT_CODE and failure message"
    else
        log_fail "status_complete not properly called for post-container failure"
        return 1
    fi
}

test_status_complete_called_with_zero_on_success() {
    log_test "status_complete called with 0 when both container and post-container succeed"

    # When both EXIT_CODE and POST_EXIT_CODE are 0, status_complete should be
    # called with 0 and the PR_URL

    # Look for the else branch that calls status_complete with 0
    if grep -B 3 'status_complete 0 "" "\${PR_URL:-}"' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'else$'; then
        log_info "  ✓ status_complete called with 0 on success"
    else
        log_fail "status_complete not properly called for success case"
        return 1
    fi
}

test_bug_scenario_demonstration() {
    log_test "Demonstrates bug #81 scenario: container succeeds, push fails"

    # This test shows what WOULD have happened before the fix:
    # - Container exits with EXIT_CODE=0
    # - post_container_worktree fails (e.g., push fails) and returns 1
    # - Before fix: script would exit 0 (incorrectly reporting success)
    # - After fix: script should exit 1 (correctly reporting failure)

    # Simulate the scenario by checking the code logic
    local before_fix_behavior="exit with EXIT_CODE (0) regardless of post-container result"
    local after_fix_behavior="exit with POST_EXIT_CODE (1) when post-container fails"

    log_info "  Scenario: Container exits successfully (EXIT_CODE=0)"
    log_info "           But git push fails (POST_EXIT_CODE=1)"
    log_info ""
    log_info "  Before fix: Would ${before_fix_behavior}"
    log_info "  After fix:  Should ${after_fix_behavior}"
    log_info ""

    # Verify the fix is in place by checking for FINAL_EXIT_CODE logic
    if grep -q 'FINAL_EXIT_CODE=\$POST_EXIT_CODE' "$LAUNCH_AGENT_SCRIPT" && \
       grep -q 'exit \$FINAL_EXIT_CODE' "$LAUNCH_AGENT_SCRIPT"; then
        log_info "  ✓ Fix verified: FINAL_EXIT_CODE logic is present"
    else
        log_fail "Fix not found: Missing FINAL_EXIT_CODE logic"
        return 1
    fi
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    print_test_header "Post-Container Exit Code Handling (Issue #81 Regression)"

    log_info "This test verifies that launch-agent.sh correctly captures and reports"
    log_info "failures from post-container operations (e.g., git push failures)."
    log_info ""
    log_info "Bug #81: When container succeeded but post-container ops failed,"
    log_info "the script would incorrectly report success."
    log_info ""

    # Run all tests
    run_test test_post_container_exit_code_captured
    run_test test_final_exit_code_combines_both
    run_test test_exit_uses_final_exit_code
    run_test test_status_complete_called_with_post_exit_code
    run_test test_status_complete_called_with_zero_on_success
    run_test test_bug_scenario_demonstration

    # Print summary
    print_summary
}

main "$@"
