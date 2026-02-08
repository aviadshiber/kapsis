#!/usr/bin/env bash
#===============================================================================
# Test: Post-Container Git Operations - sync_index_from_container
#
# Tests for the sync_index_from_container() function in post-container-git.sh.
# This function handles syncing the git index from a sanitized git directory
# back to the worktree's git directory.
#
# Regression test for PR #141: Fixes handling of .git as both file (worktree)
# and directory (regular repo), which previously caused "cat: .git: Is a directory".
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2034  # Variables used by sourced scripts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source dependencies for post-container-git.sh
# Note: We need to source these in the right order and suppress output
export KAPSIS_LOG_TO_FILE=false
export KAPSIS_LOG_CONSOLE=false
export KAPSIS_STATUS_ENABLED=false

source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-post-container-git"
source "$KAPSIS_ROOT/scripts/lib/status.sh"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/git-remote-utils.sh"

# Now source the file containing sync_index_from_container
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

#===============================================================================
# TEST FIXTURES
#===============================================================================

# Create a temporary test directory for each test
TEST_TEMP_DIR=""

setup_sync_test() {
    TEST_TEMP_DIR=$(mktemp -d)
    log_info "Created test temp dir: $TEST_TEMP_DIR"
}

cleanup_sync_test() {
    if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
        log_info "Cleaned up test temp dir"
    fi
    TEST_TEMP_DIR=""
}

#===============================================================================
# TEST CASES
#===============================================================================

test_sync_index_git_as_file() {
    log_test "sync_index_from_container: .git as file (worktree)"

    setup_sync_test

    local worktree_path="$TEST_TEMP_DIR/worktree"
    local sanitized_git="$TEST_TEMP_DIR/sanitized-git"
    local actual_gitdir="$TEST_TEMP_DIR/actual-gitdir"

    # Setup: Create worktree with .git file pointing to gitdir
    mkdir -p "$worktree_path"
    mkdir -p "$sanitized_git"
    mkdir -p "$actual_gitdir"

    # Create .git file with gitdir pointer (as worktrees have)
    echo "gitdir: $actual_gitdir" > "$worktree_path/.git"

    # Create index file in sanitized git directory
    echo "test-index-content" > "$sanitized_git/index"

    # Call the function
    sync_index_from_container "$worktree_path" "$sanitized_git"

    # Assert: index file was copied to the gitdir path
    assert_file_exists "$actual_gitdir/index" "Index should be copied to gitdir"
    assert_file_contains "$actual_gitdir/index" "test-index-content" "Index content should match"

    cleanup_sync_test
}

test_sync_index_git_as_directory() {
    log_test "sync_index_from_container: .git as directory (regular repo)"

    setup_sync_test

    local worktree_path="$TEST_TEMP_DIR/repo"
    local sanitized_git="$TEST_TEMP_DIR/sanitized-git"

    # Setup: Create repo with .git directory
    mkdir -p "$worktree_path/.git"
    mkdir -p "$sanitized_git"

    # Create index file in sanitized git directory
    echo "regular-repo-index" > "$sanitized_git/index"

    # Call the function
    sync_index_from_container "$worktree_path" "$sanitized_git"

    # Assert: index file was copied to .git/index
    assert_file_exists "$worktree_path/.git/index" "Index should be copied to .git/index"
    assert_file_contains "$worktree_path/.git/index" "regular-repo-index" "Index content should match"

    cleanup_sync_test
}

test_sync_index_no_git() {
    log_test "sync_index_from_container: no .git (graceful handling)"

    setup_sync_test

    local worktree_path="$TEST_TEMP_DIR/no-git"
    local sanitized_git="$TEST_TEMP_DIR/sanitized-git"

    # Setup: Create directory without .git
    mkdir -p "$worktree_path"
    mkdir -p "$sanitized_git"

    # Create index file in sanitized git directory
    echo "orphan-index" > "$sanitized_git/index"

    # Call the function - should return 0 and not fail
    local exit_code=0
    sync_index_from_container "$worktree_path" "$sanitized_git" || exit_code=$?

    # Assert: function returns 0 (no error)
    assert_equals "0" "$exit_code" "Function should return 0 for missing .git"

    # Assert: no index file created anywhere (nothing to copy to)
    assert_file_not_exists "$worktree_path/index" "No index should be created in worktree root"
    assert_file_not_exists "$worktree_path/.git" "No .git should be created"

    cleanup_sync_test
}

test_sync_index_no_index_in_sanitized() {
    log_test "sync_index_from_container: no index in sanitized-git (skip)"

    setup_sync_test

    local worktree_path="$TEST_TEMP_DIR/repo"
    local sanitized_git="$TEST_TEMP_DIR/sanitized-git"
    local actual_gitdir="$TEST_TEMP_DIR/actual-gitdir"

    # Setup: Create worktree with .git file
    mkdir -p "$worktree_path"
    mkdir -p "$sanitized_git"  # No index file
    mkdir -p "$actual_gitdir"

    echo "gitdir: $actual_gitdir" > "$worktree_path/.git"

    # Pre-create an existing index to verify it's not touched
    echo "existing-index" > "$actual_gitdir/index"

    # Call the function - should return without error and not modify anything
    local exit_code=0
    sync_index_from_container "$worktree_path" "$sanitized_git" || exit_code=$?

    # Assert: function returns 0
    assert_equals "0" "$exit_code" "Function should return 0 when no index to copy"

    # Assert: existing index is unchanged
    assert_file_contains "$actual_gitdir/index" "existing-index" "Existing index should be unchanged"

    cleanup_sync_test
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Post-Container Git: sync_index_from_container"

    log_info "Testing sync_index_from_container() function"
    log_info "This function syncs the git index from sanitized-git to the worktree's gitdir"
    log_info ""
    log_info "PR #141 fix: Handle .git as both file (worktree) and directory (regular repo)"
    log_info ""

    # Run tests
    run_test test_sync_index_git_as_file
    run_test test_sync_index_git_as_directory
    run_test test_sync_index_no_git
    run_test test_sync_index_no_index_in_sanitized

    # Print summary
    print_summary
}

main "$@"
