#!/usr/bin/env bash
#===============================================================================
# Test: Commit Failure Handling (Issue #256)
#
# Verifies that when git commit fails in post-container operations:
# 1. The error output is captured and logged (not swallowed)
# 2. Exit code 6 is used for commit failures
# 3. The worktree is preserved (not cleaned up)
# 4. Both || captures are present to prevent set -e script death
# 5. error_type field exists in status.json schema
# 6. KAPSIS_COMMIT_NO_VERIFY opt-in is supported
#
# Bug #256: Agent produced 24 file changes over ~1h42m, but git commit failed
# silently. The error was swallowed, worktree cleaned up, and caller retried
# blindly 3 times.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_AGENT_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
POST_CONTAINER_GIT="$KAPSIS_ROOT/scripts/post-container-git.sh"
STATUS_SH="$KAPSIS_ROOT/scripts/lib/status.sh"
CONSTANTS_SH="$KAPSIS_ROOT/scripts/lib/constants.sh"

# Source post-container-git.sh for behavioral tests
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

# Global variables for behavioral tests
TEST_REPO=""

setup_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-commit-${test_name}-XXXXXX")
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
}

cleanup_test_repo() {
    [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]] && rm -rf "$TEST_REPO"
    TEST_REPO=""
}

#===============================================================================
# TEST CASES
#===============================================================================

test_commit_output_captured() {
    log_test "git commit stderr/stdout is captured on failure"

    # Split into two separate checks to be robust against line reformatting

    # Check 1: git commit output is captured via 2>&1
    if grep -q 'git commit.*2>&1' "$POST_CONTAINER_GIT"; then
        log_info "  ✓ git commit output captured via 2>&1"
    else
        log_fail "git commit output not captured with 2>&1 in commit_changes()"
        return 1
    fi

    # Check 2: exit code is captured via || pattern
    if grep -q '|| _commit_exit=\$?' "$POST_CONTAINER_GIT"; then
        log_info "  ✓ git commit exit code captured via || _commit_exit"
    else
        log_fail "git commit exit code not captured with || _commit_exit"
        return 1
    fi

    # Check 3: the error output is logged, not silently discarded
    if grep -q 'log_error.*git commit failed' "$POST_CONTAINER_GIT"; then
        log_info "  ✓ Commit failure logged with log_error"
    else
        log_fail "Commit failure not logged with log_error"
        return 1
    fi
}

test_exit_code_6_constant_defined() {
    log_test "KAPSIS_EXIT_COMMIT_FAILURE=6 is defined in constants.sh"

    if grep -q 'readonly KAPSIS_EXIT_COMMIT_FAILURE=6' "$CONSTANTS_SH"; then
        log_info "  ✓ KAPSIS_EXIT_COMMIT_FAILURE=6 defined"
    else
        log_fail "KAPSIS_EXIT_COMMIT_FAILURE=6 not found in constants.sh"
        return 1
    fi
}

test_commit_failure_sets_exit_code_6() {
    log_test "FINAL_EXIT_CODE=6 when commit_status is 'failed'"

    # Verify that the POST_EXIT_CODE block checks commit_status and sets exit code 6
    if grep -A 10 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'commit_status.*==.*failed'; then
        log_info "  ✓ POST_EXIT_CODE block checks commit_status for 'failed'"
    else
        log_fail "POST_EXIT_CODE block does not check commit_status"
        return 1
    fi

    if grep -A 15 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'FINAL_EXIT_CODE=6'; then
        log_info "  ✓ FINAL_EXIT_CODE=6 set for commit failure"
    else
        log_fail "FINAL_EXIT_CODE=6 not set for commit failure"
        return 1
    fi
}

test_error_type_field_in_status() {
    log_test "error_type field exists in status.json schema"

    # Verify the error_type variable exists
    if grep -q '_KAPSIS_ERROR_TYPE=' "$STATUS_SH"; then
        log_info "  ✓ _KAPSIS_ERROR_TYPE state variable defined"
    else
        log_fail "_KAPSIS_ERROR_TYPE not defined in status.sh"
        return 1
    fi

    # Verify the setter function exists
    if grep -q 'status_set_error_type()' "$STATUS_SH"; then
        log_info "  ✓ status_set_error_type() function defined"
    else
        log_fail "status_set_error_type() not found in status.sh"
        return 1
    fi

    # Verify error_type appears in the JSON template
    if grep -q '"error_type":' "$STATUS_SH"; then
        log_info "  ✓ error_type field in JSON template"
    else
        log_fail "error_type not in JSON template"
        return 1
    fi
}

test_worktree_preserved_on_post_exit_failure() {
    log_test "Worktree cleanup condition checks post-container failure"

    # Verify the cleanup condition includes _pcg_rc check (Issue #256)
    if grep -q '_pcg_rc:-0.*-ne 0' "$LAUNCH_AGENT_SCRIPT"; then
        log_info "  ✓ Worktree cleanup condition checks _pcg_rc"
    else
        log_fail "Worktree cleanup does not check _pcg_rc"
        return 1
    fi
}

test_post_container_git_failure_caught() {
    log_test "post_container_git failure caught with || _pcg_rc"

    # Verify that post_container_git is called with || _pcg_rc=$?
    # This prevents set -e from killing post_container_worktree
    # Note: The call spans multiple lines, so we look for _pcg_rc near post_container_git
    if grep -A 15 'post_container_git \\' "$LAUNCH_AGENT_SCRIPT" | grep -q '|| _pcg_rc=\$?'; then
        log_info "  ✓ post_container_git failure caught with || _pcg_rc"
    else
        log_fail "post_container_git not caught with || _pcg_rc"
        return 1
    fi
}

test_both_error_captures_present() {
    log_test "Both || captures present (inseparable pair)"

    # CRITICAL: Both captures must be present or neither works under set -e
    # Inner: post_container_git || _pcg_rc=$?
    # Outer: post_container_worktree || POST_EXIT_CODE=$?

    local inner_ok=false
    local outer_ok=false

    if grep -A 15 'post_container_git \\' "$LAUNCH_AGENT_SCRIPT" | grep -q '|| _pcg_rc=\$?'; then
        inner_ok=true
        log_info "  ✓ Inner capture: post_container_git || _pcg_rc"
    fi

    if grep -q 'post_container_worktree || POST_EXIT_CODE' "$LAUNCH_AGENT_SCRIPT"; then
        outer_ok=true
        log_info "  ✓ Outer capture: post_container_worktree || POST_EXIT_CODE"
    fi

    if [[ "$inner_ok" == "true" ]] && [[ "$outer_ok" == "true" ]]; then
        log_info "  ✓ Both captures present (set -e safe)"
    else
        log_fail "Missing one or both || captures — set -e will kill the script on commit failure"
        [[ "$inner_ok" != "true" ]] && log_fail "  Missing: post_container_git || _pcg_rc"
        [[ "$outer_ok" != "true" ]] && log_fail "  Missing: post_container_worktree || POST_EXIT_CODE"
        return 1
    fi
}

test_no_verify_config_supported() {
    log_test "KAPSIS_COMMIT_NO_VERIFY opt-in config supported"

    if grep -q 'KAPSIS_COMMIT_NO_VERIFY' "$POST_CONTAINER_GIT"; then
        log_info "  ✓ KAPSIS_COMMIT_NO_VERIFY config option present"
    else
        log_fail "KAPSIS_COMMIT_NO_VERIFY not found in post-container-git.sh"
        return 1
    fi

    # Verify it's opt-in (defaults to false), not auto-enabled
    if grep -q 'KAPSIS_COMMIT_NO_VERIFY:-false' "$POST_CONTAINER_GIT"; then
        log_info "  ✓ Defaults to false (opt-in only)"
    else
        log_fail "KAPSIS_COMMIT_NO_VERIFY does not default to false"
        return 1
    fi
}

test_error_type_populated_for_all_exits() {
    log_test "error_type populated for all non-zero exit paths"

    # Verify status_set_error_type is called for each exit code path
    local missing=()

    grep -q 'status_set_error_type "mount_failure"' "$LAUNCH_AGENT_SCRIPT" || missing+=("mount_failure")
    grep -q 'status_set_error_type "hung_after_completion"' "$LAUNCH_AGENT_SCRIPT" || missing+=("hung_after_completion")
    grep -q 'status_set_error_type "agent_failure"' "$LAUNCH_AGENT_SCRIPT" || missing+=("agent_failure")
    grep -q 'status_set_error_type "commit_failure"' "$LAUNCH_AGENT_SCRIPT" || missing+=("commit_failure")
    grep -q 'status_set_error_type "push_failure"' "$LAUNCH_AGENT_SCRIPT" || missing+=("push_failure")
    grep -q 'status_set_error_type "uncommitted_work"' "$LAUNCH_AGENT_SCRIPT" || missing+=("uncommitted_work")

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "  ✓ All error types populated"
    else
        log_fail "Missing error_type for: ${missing[*]}"
        return 1
    fi
}

test_pcg_rc_propagated_to_caller() {
    log_test "post_container_worktree propagates _pcg_rc via return"

    # Verify that post_container_worktree() ends with 'return "$_pcg_rc"'
    # This is CRITICAL — without it, the function returns 0 implicitly
    # and the entire commit-failure detection chain is dead code.
    if grep -A 3 'Propagate post-container failure' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'return "\$_pcg_rc"'; then
        log_info "  ✓ post_container_worktree returns _pcg_rc"
    else
        log_fail "post_container_worktree does not return _pcg_rc — commit failure detection is dead code"
        return 1
    fi
}

test_commit_changes_returns_1_on_failure() {
    log_test "commit_changes() returns 1 when git commit fails (pre-commit hook rejection)"

    # Behavioral test: set up a real git repo with a pre-commit hook that
    # always rejects, add real file changes, and verify commit_changes returns 1.
    # This is the exact scenario from Issue #256.

    setup_test_repo "commit-fail"
    cd "$TEST_REPO"

    # Install a pre-commit hook that always fails
    mkdir -p .git/hooks
    cat > .git/hooks/pre-commit << 'HOOKEOF'
#!/usr/bin/env bash
echo "pre-commit hook: REJECTED (test)" >&2
exit 1
HOOKEOF
    chmod +x .git/hooks/pre-commit

    # Create real file changes (commit_changes will stage these via git add -A)
    echo "agent output" > agent-result.txt

    # Call commit_changes — git commit should fail due to hook rejection
    local exit_code=0
    commit_changes "$TEST_REPO" "feat: test commit failure" "agent-test" "" || exit_code=$?

    if [[ $exit_code -eq 1 ]]; then
        log_info "  ✓ commit_changes returned 1 on hook rejection"
    else
        log_fail "commit_changes returned $exit_code, expected 1"
        cleanup_test_repo
        return 1
    fi

    log_info "  ✓ Behavioral test: commit_changes correctly returns 1 on git commit failure"
    cleanup_test_repo
}

test_push_failure_branch_still_works() {
    log_test "Push failure path still sets FINAL_EXIT_CODE=\$POST_EXIT_CODE"

    # Verify the else branch (push failure) is present and sets the right code
    if grep -A 20 'elif \[\[ "\$POST_EXIT_CODE" -ne 0 \]\]' "$LAUNCH_AGENT_SCRIPT" | \
       grep -q 'FINAL_EXIT_CODE=\$POST_EXIT_CODE'; then
        log_info "  ✓ Push failure path sets FINAL_EXIT_CODE=\$POST_EXIT_CODE"
    else
        log_fail "Push failure path missing or broken"
        return 1
    fi
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    print_test_header "Commit Failure Handling (Issue #256 Regression)"

    log_info "This test verifies that launch-agent.sh correctly handles and reports"
    log_info "post-container commit failures, preserving agent work instead of"
    log_info "silently discarding it."
    log_info ""

    # Structure inspection tests
    run_test test_commit_output_captured
    run_test test_exit_code_6_constant_defined
    run_test test_commit_failure_sets_exit_code_6
    run_test test_error_type_field_in_status
    run_test test_worktree_preserved_on_post_exit_failure
    run_test test_post_container_git_failure_caught
    run_test test_both_error_captures_present
    run_test test_no_verify_config_supported
    run_test test_error_type_populated_for_all_exits
    run_test test_pcg_rc_propagated_to_caller
    run_test test_push_failure_branch_still_works

    # Behavioral tests (use real git repo)
    run_test test_commit_changes_returns_1_on_failure

    # Print summary
    print_summary
}

main "$@"
