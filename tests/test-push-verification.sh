#!/usr/bin/env bash
#===============================================================================
# Test: Push Verification (Issue #40)
#
# Verifies push verification functionality works correctly:
# - verify_push compares local and remote HEAD
# - push_changes verifies after successful push
# - Status is updated with push verification info
# - Different exit codes for different failure modes
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

POST_CONTAINER_GIT_SCRIPT="$KAPSIS_ROOT/scripts/post-container-git.sh"
STATUS_SCRIPT="$KAPSIS_ROOT/scripts/lib/status.sh"

# Test directories
TEST_REPO_DIR=""
TEST_REMOTE_DIR=""
TEST_STATUS_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_git_test() {
    # Create isolated test directories
    TEST_REPO_DIR=$(mktemp -d)
    TEST_REMOTE_DIR=$(mktemp -d)
    TEST_STATUS_DIR=$(mktemp -d)

    # Setup "remote" bare repository
    cd "$TEST_REMOTE_DIR"
    git init --bare -q

    # Setup local repository that tracks the remote
    cd "$TEST_REPO_DIR"
    git init -q
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    # Disable signing for test commits
    git config commit.gpgsign false
    git config tag.gpgsign false

    # Create initial commit
    echo "initial content" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    # Add remote and push
    git remote add origin "$TEST_REMOTE_DIR"
    git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || {
        # Handle default branch name differences
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD)
        git push -u origin "$branch" 2>/dev/null
    }

    # Configure status directory
    export KAPSIS_STATUS_DIR="$TEST_STATUS_DIR"
    export KAPSIS_STATUS_ENABLED="true"

    # Reset status library state
    unset _KAPSIS_STATUS_LOADED 2>/dev/null || true
    unset _KAPSIS_STATUS_INITIALIZED 2>/dev/null || true

    # Source libraries
    source "$STATUS_SCRIPT"
    source "$POST_CONTAINER_GIT_SCRIPT"

    # Initialize status for tests
    status_init "test-project" "1" "" "worktree" ""

    log_info "Git test setup complete"
    log_info "  Local repo: $TEST_REPO_DIR"
    log_info "  Remote repo: $TEST_REMOTE_DIR"
}

cleanup_git_test() {
    if [[ -n "$TEST_REPO_DIR" && -d "$TEST_REPO_DIR" ]]; then
        rm -rf "$TEST_REPO_DIR"
    fi
    if [[ -n "$TEST_REMOTE_DIR" && -d "$TEST_REMOTE_DIR" ]]; then
        rm -rf "$TEST_REMOTE_DIR"
    fi
    if [[ -n "$TEST_STATUS_DIR" && -d "$TEST_STATUS_DIR" ]]; then
        rm -rf "$TEST_STATUS_DIR"
    fi
    TEST_REPO_DIR=""
    TEST_REMOTE_DIR=""
    TEST_STATUS_DIR=""
}

#===============================================================================
# TEST CASES: verify_push function
#===============================================================================

test_verify_push_success() {
    log_test "verify_push returns 0 when local and remote match"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Local and remote are in sync after setup
    local result=0
    verify_push "$TEST_REPO_DIR" "origin" || result=$?

    assert_equals 0 "$result" "verify_push should return 0 when in sync"

    # Check status was updated
    assert_equals "success" "$_KAPSIS_PUSH_STATUS" "Push status should be success"
    assert_not_equals "" "$_KAPSIS_LOCAL_COMMIT" "Local commit should be set"
    assert_not_equals "" "$_KAPSIS_REMOTE_COMMIT" "Remote commit should be set"
    assert_equals "$_KAPSIS_LOCAL_COMMIT" "$_KAPSIS_REMOTE_COMMIT" "Commits should match"

    cleanup_git_test
}

test_verify_push_failure_commits_mismatch() {
    log_test "verify_push returns 1 when commits don't match"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create a local commit that hasn't been pushed
    echo "new content" > new_file.txt
    git add new_file.txt
    git commit -q -m "Unpushed commit"

    # Now local is ahead of remote
    local result=0
    verify_push "$TEST_REPO_DIR" "origin" 2>/dev/null || result=$?

    assert_equals 1 "$result" "verify_push should return 1 when out of sync"

    # Check status was updated
    assert_equals "failed" "$_KAPSIS_PUSH_STATUS" "Push status should be failed"
    assert_not_equals "" "$_KAPSIS_LOCAL_COMMIT" "Local commit should be set"

    cleanup_git_test
}

test_verify_push_auto_detects_branch() {
    log_test "verify_push auto-detects current branch"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Don't specify branch, let it auto-detect
    local result=0
    verify_push "$TEST_REPO_DIR" "origin" "" || result=$?

    assert_equals 0 "$result" "verify_push should work with auto-detected branch"
    assert_equals "success" "$_KAPSIS_PUSH_STATUS" "Push status should be success"

    cleanup_git_test
}

#===============================================================================
# TEST CASES: has_changes function
#===============================================================================

test_has_changes_with_modifications() {
    log_test "has_changes returns 0 when there are uncommitted changes"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create uncommitted changes
    echo "modified" >> file.txt

    local result=0
    has_changes "$TEST_REPO_DIR" || result=$?

    assert_equals 0 "$result" "has_changes should return 0 (true) with modifications"

    cleanup_git_test
}

test_has_changes_clean() {
    log_test "has_changes returns 1 when working directory is clean"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Working directory should be clean after setup
    local result=0
    has_changes "$TEST_REPO_DIR" || result=$?

    assert_equals 1 "$result" "has_changes should return 1 (false) when clean"

    cleanup_git_test
}

test_has_changes_with_untracked() {
    log_test "has_changes returns 0 with untracked files"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create untracked file
    echo "new file" > untracked.txt

    local result=0
    has_changes "$TEST_REPO_DIR" || result=$?

    assert_equals 0 "$result" "has_changes should return 0 (true) with untracked files"

    cleanup_git_test
}

#===============================================================================
# TEST CASES: commit_changes function
#===============================================================================

test_commit_changes_creates_commit() {
    log_test "commit_changes creates a commit"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create changes to commit
    echo "new content" > new_file.txt
    local before_commit
    before_commit=$(git rev-parse HEAD)

    commit_changes "$TEST_REPO_DIR" "Test commit message" "test-agent" >/dev/null 2>&1

    local after_commit
    after_commit=$(git rev-parse HEAD)

    assert_not_equals "$before_commit" "$after_commit" "HEAD should change after commit"

    # Check commit message
    local commit_msg
    commit_msg=$(git log -1 --format="%s")
    assert_contains "$commit_msg" "Test commit message" "Commit message should be present"

    cleanup_git_test
}

#===============================================================================
# TEST CASES: push_changes with verification
#===============================================================================

test_push_changes_verifies_success() {
    log_test "push_changes verifies push and returns 0 on success"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create and commit a change
    echo "push test" > push_test.txt
    git add push_test.txt
    git commit -q -m "Test push"

    # Push with verification
    local result=0
    push_changes "$TEST_REPO_DIR" "origin" >/dev/null 2>&1 || result=$?

    assert_equals 0 "$result" "push_changes should return 0 on successful push"
    assert_equals "success" "$_KAPSIS_PUSH_STATUS" "Push status should be success"

    cleanup_git_test
}

#===============================================================================
# TEST CASES: Integration with post_container_git
#===============================================================================

test_post_container_git_no_push_sets_skipped() {
    log_test "post_container_git without --push sets status to skipped"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create changes
    echo "no push test" > no_push_test.txt

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Run with do_push=false (push disabled, should result in skipped status)
    post_container_git "$TEST_REPO_DIR" "$branch" "Test commit" "origin" "false" "test-agent" >/dev/null 2>&1

    assert_equals "skipped" "$_KAPSIS_PUSH_STATUS" "Push status should be skipped"
    assert_not_equals "" "$_KAPSIS_LOCAL_COMMIT" "Local commit should be recorded"

    cleanup_git_test
}

test_post_container_git_updates_status() {
    log_test "post_container_git updates status with push info"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Create changes
    echo "status update test" > status_test.txt

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Run the full workflow
    post_container_git "$TEST_REPO_DIR" "$branch" "Test commit" "origin" "false" "test-agent" >/dev/null 2>&1

    # Verify status file has push info
    local status_file="$TEST_STATUS_DIR/kapsis-test-project-1.json"
    assert_file_exists "$status_file" "Status file should exist"

    local content
    content=$(cat "$status_file")

    # Check that push_status is in the output (should be success or unverified)
    if echo "$content" | grep -q '"push_status":'; then
        log_info "  Push status field present in status file"
    else
        log_fail "Push status field missing from status file"
        cleanup_git_test
        return 1
    fi

    cleanup_git_test
}

#===============================================================================
# TEST CASES: Exit codes
#===============================================================================

test_verify_push_exit_codes() {
    log_test "verify_push returns correct exit codes"

    setup_git_test

    cd "$TEST_REPO_DIR"

    # Test success case (in sync)
    local result=0
    verify_push "$TEST_REPO_DIR" "origin" || result=$?
    assert_equals 0 "$result" "Should return 0 when in sync"

    # Create unpushed commit
    echo "unpushed" > unpushed.txt
    git add unpushed.txt
    git commit -q -m "Unpushed"

    # Test failure case (out of sync)
    result=0
    verify_push "$TEST_REPO_DIR" "origin" 2>/dev/null || result=$?
    assert_equals 1 "$result" "Should return 1 when out of sync"

    cleanup_git_test
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Push Verification (Issue #40)"

    # verify_push function tests
    run_test test_verify_push_success
    run_test test_verify_push_failure_commits_mismatch
    run_test test_verify_push_auto_detects_branch

    # has_changes function tests
    run_test test_has_changes_with_modifications
    run_test test_has_changes_clean
    run_test test_has_changes_with_untracked

    # commit_changes function tests
    run_test test_commit_changes_creates_commit

    # push_changes with verification tests
    run_test test_push_changes_verifies_success

    # Integration tests
    run_test test_post_container_git_no_push_sets_skipped
    run_test test_post_container_git_updates_status

    # Exit code tests
    run_test test_verify_push_exit_codes

    # Summary
    print_summary
}

main "$@"
