#!/usr/bin/env bash
#===============================================================================
# Test: Shared Git Operations Library (scripts/lib/git-operations.sh)
#
# Unit tests for the shared git primitives:
#   - has_git_changes() — change detection
#   - has_unpushed_commits() — unpushed commit detection
#   - git_push_refspec() — push with refspec
#   - verify_git_push() — push verification
#   - _git_ops_set_push_info() — safe status helper
#
# These functions eliminate duplication across entrypoint.sh,
# post-container-git.sh, and post-exit-git.sh.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source dependencies
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-git-operations"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/git-operations.sh"

# Test directories
TEST_REPO_DIR=""
TEST_REMOTE_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_test_repo() {
    TEST_REPO_DIR=$(mktemp -d)
    TEST_REMOTE_DIR=$(mktemp -d)

    # Setup bare "remote"
    cd "$TEST_REMOTE_DIR"
    git init --bare -q

    # Setup local repo
    cd "$TEST_REPO_DIR"
    git init -q
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    git config tag.gpgsign false

    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    git remote add origin "$TEST_REMOTE_DIR"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "$branch" 2>/dev/null
}

cleanup_test_repo() {
    cd /tmp
    [[ -n "${TEST_REPO_DIR:-}" ]] && rm -rf "$TEST_REPO_DIR"
    [[ -n "${TEST_REMOTE_DIR:-}" ]] && rm -rf "$TEST_REMOTE_DIR"
}

#===============================================================================
# has_git_changes() TESTS
#===============================================================================

test_has_git_changes_clean() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    # Clean working directory → should return 1
    local result=0
    has_git_changes || result=$?
    assert_equals "1" "$result" "Clean repo should return 1 (no changes)"

    cleanup_test_repo
}

test_has_git_changes_unstaged() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    echo "modified" > file.txt

    local result=0
    has_git_changes || result=$?
    assert_equals "0" "$result" "Unstaged changes should return 0"

    cleanup_test_repo
}

test_has_git_changes_staged() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    echo "staged" > file.txt
    git add file.txt

    local result=0
    has_git_changes || result=$?
    assert_equals "0" "$result" "Staged changes should return 0"

    cleanup_test_repo
}

test_has_git_changes_untracked() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    echo "new file" > new_file.txt

    local result=0
    has_git_changes || result=$?
    assert_equals "0" "$result" "Untracked files should return 0"

    cleanup_test_repo
}

#===============================================================================
# has_unpushed_commits() TESTS
#===============================================================================

test_has_unpushed_commits_none() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    # After initial push, no unpushed commits
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    local result=0
    has_unpushed_commits "origin" "$branch" || result=$?
    assert_equals "1" "$result" "No unpushed commits should return 1"

    cleanup_test_repo
}

test_has_unpushed_commits_exist() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    # Create a new commit without pushing
    echo "unpushed" > file.txt
    git add file.txt
    git commit -q -m "Unpushed commit"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    local result=0
    has_unpushed_commits "origin" "$branch" || result=$?
    assert_equals "0" "$result" "Unpushed commits should return 0"

    cleanup_test_repo
}

test_has_unpushed_commits_no_remote_branch() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    # Create a new local branch that doesn't exist on remote
    git checkout -q -b "new-branch"
    echo "content" > newfile.txt
    git add newfile.txt
    git commit -q -m "New branch commit"

    local result=0
    has_unpushed_commits "origin" "new-branch" || result=$?
    assert_equals "0" "$result" "New branch with commits should return 0"

    cleanup_test_repo
}

#===============================================================================
# git_push_refspec() TESTS
#===============================================================================

test_git_push_refspec_same_branch() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    echo "push me" > file.txt
    git add file.txt
    git commit -q -m "Push test"

    local result=0
    git_push_refspec "origin" "$branch" "$branch" || result=$?
    assert_equals "0" "$result" "Push with same local and remote branch should succeed"

    cleanup_test_repo
}

test_git_push_refspec_different_branch() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    echo "push me" > file.txt
    git add file.txt
    git commit -q -m "Push test"

    local result=0
    git_push_refspec "origin" "$branch" "remote-branch" || result=$?
    assert_equals "0" "$result" "Push with different remote branch name should succeed"

    cleanup_test_repo
}

#===============================================================================
# verify_git_push() TESTS
#===============================================================================

test_verify_git_push_success() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    echo "verify me" > file.txt
    git add file.txt
    git commit -q -m "Verify push test"
    git push origin "$branch" 2>/dev/null

    local result=0
    verify_git_push "origin" "$branch" || result=$?
    assert_equals "0" "$result" "Push verification should succeed when commits match"

    cleanup_test_repo
}

test_verify_git_push_mismatch() {
    setup_test_repo
    cd "$TEST_REPO_DIR"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Push current state
    echo "version 1" > file.txt
    git add file.txt
    git commit -q -m "Version 1"
    git push origin "$branch" 2>/dev/null

    # Make another local commit (not pushed)
    echo "version 2" > file.txt
    git add file.txt
    git commit -q -m "Version 2 (not pushed)"

    local result=0
    verify_git_push "origin" "$branch" || result=$?
    assert_equals "1" "$result" "Verification should fail when local != remote"

    cleanup_test_repo
}

#===============================================================================
# _git_ops_set_push_info() TESTS
#===============================================================================

test_git_ops_set_push_info_no_status() {
    # When status_set_push_info is not available, should not error
    local result=0
    _git_ops_set_push_info "success" "abc123" "abc123" || result=$?
    assert_equals "0" "$result" "Should succeed silently when status_set_push_info not available"
}

#===============================================================================
# GUARD TESTS
#===============================================================================

test_guard_prevents_double_source() {
    # The guard should already be set from our first source
    assert_equals "1" "$_KAPSIS_GIT_OPERATIONS_LOADED" "Guard variable should be set to 1"
}

#===============================================================================
# RUN
#===============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo "TEST: Shared Git Operations Library (scripts/lib/git-operations.sh)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# has_git_changes tests
run_test test_has_git_changes_clean
run_test test_has_git_changes_unstaged
run_test test_has_git_changes_staged
run_test test_has_git_changes_untracked

# has_unpushed_commits tests
run_test test_has_unpushed_commits_none
run_test test_has_unpushed_commits_exist
run_test test_has_unpushed_commits_no_remote_branch

# git_push_refspec tests
run_test test_git_push_refspec_same_branch
run_test test_git_push_refspec_different_branch

# verify_git_push tests
run_test test_verify_git_push_success
run_test test_verify_git_push_mismatch

# Helper tests
run_test test_git_ops_set_push_info_no_status
run_test test_guard_prevents_double_source

print_summary
