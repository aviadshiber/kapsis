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
#
# Regression test for Fix #186: Cache-tree rebuild after index sync to prevent
# stale object references that cause push failures.
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
# REGRESSION TEST: Fix #186 - Cache-tree rebuild
#===============================================================================

test_sync_index_cache_tree_rebuild() {
    log_test "sync_index_from_container: cache-tree rebuilt after sync (Fix #186)"

    setup_sync_test

    # 1. Create a real git repo with an initial commit + file
    local repo_path="$TEST_TEMP_DIR/repo"
    mkdir -p "$repo_path"
    cd "$repo_path"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "init"

    # 2. Create a worktree (simulating what Kapsis does)
    local wt_path="$TEST_TEMP_DIR/worktree"
    git worktree add -q "$wt_path" -b test-branch

    # 3. Get the worktree gitdir path
    local gitdir_content
    gitdir_content=$(cat "$wt_path/.git")
    local wt_gitdir="${gitdir_content#gitdir: }"

    # 4. Simulate sanitized git with a copy of the index
    #    This mimics prepare_sanitized_git() copying the index (worktree-manager.sh:504-506)
    local sanitized_git="$TEST_TEMP_DIR/sanitized-git"
    mkdir -p "$sanitized_git"
    cp "$wt_gitdir/index" "$sanitized_git/index"

    # 5. Create a file in the worktree (simulate agent work)
    echo "new content" > "$wt_path/new-file.txt"

    # 6. Call sync_index_from_container (this should rebuild cache-tree)
    cd "$wt_path"
    sync_index_from_container "$wt_path" "$sanitized_git"

    # 7. Verify: git fsck should report no cache-tree errors
    local fsck_output
    fsck_output=$(cd "$wt_path" && git fsck --no-dangling 2>&1 || true)
    if echo "$fsck_output" | grep -q "cache-tree"; then
        log_fail "git fsck shows cache-tree errors after sync: $fsck_output"
        cleanup_sync_test
        return 1
    fi
    log_pass "No cache-tree errors after sync"

    # 8. Verify: git add + commit works cleanly
    cd "$wt_path"
    git add -A
    local commit_output
    if ! commit_output=$(git commit -q -m "test commit" 2>&1); then
        log_fail "Commit failed after cache-tree rebuild: $commit_output"
        cleanup_sync_test
        return 1
    fi
    log_pass "Commit succeeded after cache-tree rebuild"

    # 9. Verify: git fsck clean after commit (no invalid objects)
    local post_commit_fsck
    post_commit_fsck=$(git fsck --no-dangling 2>&1 || true)
    if echo "$post_commit_fsck" | grep -q "invalid"; then
        log_fail "git fsck shows errors after commit: $post_commit_fsck"
        cleanup_sync_test
        return 1
    fi
    log_pass "Clean fsck after commit"

    # 10. Cleanup the worktree properly before removing temp dir
    cd "$repo_path"
    git worktree remove "$wt_path" 2>/dev/null || true

    cleanup_sync_test
}

#===============================================================================
# TEST CASES: validate_staged_files hardening (Task 4)
#===============================================================================

_mk_repo() {
    local r; r=$(mktemp -d)
    ( cd "$r"; git init -q; git config user.email a@b.c; git config user.name a )
    echo "$r"
}

test_reject_uppercase_kapsis_dir() {
    log_test "validate_staged_files: reject .Kapsis/ (case-insensitive)"
    local r; r=$(_mk_repo); mkdir -p "$r/.Kapsis"; echo x > "$r/.Kapsis/f"
    ( cd "$r"; git add -A -f >/dev/null 2>&1 )
    assert_command_fails "validate_staged_files '$r'" ".Kapsis/ must be rejected (case-insensitive)"
    rm -rf "$r"
}

test_reject_symlink_entry() {
    log_test "validate_staged_files: reject staged symlink (mode 120000)"
    local r; r=$(_mk_repo); ( cd "$r"; ln -s /etc/passwd link; git add -A >/dev/null 2>&1 )
    assert_command_fails "validate_staged_files '$r'" "symlink (120000) must be rejected"
    rm -rf "$r"
}

test_reject_gitlink_entry() {
    log_test "validate_staged_files: reject staged gitlink (mode 160000)"
    local r; r=$(_mk_repo)
    ( cd "$r"; git update-index --add --cacheinfo 160000,1234567890123456789012345678901234567890,sub >/dev/null 2>&1 )
    assert_command_fails "validate_staged_files '$r'" "gitlink (160000) must be rejected"
    rm -rf "$r"
}

test_accept_clean_regular_file() {
    log_test "validate_staged_files: accept a clean regular file"
    local r; r=$(_mk_repo); echo hi > "$r/normal.txt"; ( cd "$r"; git add -A >/dev/null 2>&1 )
    assert_command_succeeds "validate_staged_files '$r'" "clean regular file must pass"
    rm -rf "$r"
}

#===============================================================================
# TEST CASES: push_changes fetch-before-push (Task 5)
#===============================================================================

test_push_refuses_non_fast_forward() {
    log_test "push_changes: refuse non-fast-forward when remote advanced"
    local up; up=$(mktemp -d); ( cd "$up"; git init -q --bare -b main )
    local a; a=$(mktemp -d)
    ( cd "$a"; git init -q -b main; git config user.email a@b.c; git config user.name a
      git remote add origin "$up"; echo 1 > f; git add -A; git commit -qm base; git push -q origin main )
    # advance origin/main from another clone (real descendant, so it truly advances)
    local b; b=$(mktemp -d); git clone -q "$up" "$b"
    ( cd "$b"; git config user.email a@b.c; git config user.name a; echo 2 > f; git add -A
      git commit -qm adv; git push -q origin main )
    # 'a' makes a divergent commit on its now-stale base
    ( cd "$a"; echo 3 > g; git add -A; git commit -qm local )
    assert_command_fails "( push_changes '$a' origin main )" "divergent remote must not be blind-pushed"
    rm -rf "$up" "$a" "$b"
}

test_push_fast_forward_succeeds() {
    log_test "push_changes: fast-forward push succeeds"
    local up; up=$(mktemp -d); ( cd "$up"; git init -q --bare -b main )
    local a; a=$(mktemp -d)
    ( cd "$a"; git init -q -b main; git config user.email a@b.c; git config user.name a
      git remote add origin "$up"; echo 1 > f; git add -A; git commit -qm base; git push -q origin main
      echo 2 > f; git add -A; git commit -qm next )
    assert_command_succeeds "( push_changes '$a' origin main )" "fast-forward push should succeed"
    rm -rf "$up" "$a"
}

test_push_first_push_new_branch_succeeds() {
    # The most common kapsis case: a brand-new branch not yet on the remote. The
    # fetch of a non-existent remote branch fails, so the divergence guard must
    # SKIP (not falsely refuse) and let the first push create the branch.
    log_test "push_changes: first push of a new branch succeeds (guard skips)"
    local up; up=$(mktemp -d); ( cd "$up"; git init -q --bare -b main )
    local a; a=$(mktemp -d)
    ( cd "$a"; git init -q -b feature/new; git config user.email a@b.c; git config user.name a
      git remote add origin "$up"; echo 1 > f; git add -A; git commit -qm work )
    assert_command_succeeds "( push_changes '$a' origin feature/new )" "first push of new branch should succeed"
    # And it actually landed on the remote. cd into the bare repo first: an earlier
    # test may have left the shell cwd in a since-deleted tmp dir, which would make a
    # bare `git ls-remote` fail on "cannot access current directory" (not our bug).
    assert_command_succeeds "( cd '$up' && git ls-remote --exit-code --heads . feature/new )" "new branch exists on remote"
    rm -rf "$up" "$a"
}

#===============================================================================
# TEST CASES: post-push PR hook (Task 6)
#===============================================================================

test_post_push_hook_invoked_with_env() {
    log_test "run_post_push_hook: invoked with env, captures PR URL"
    local r; r=$(_mk_repo)
    local out; out=$(mktemp)
    local hook="printf 'BRANCH=%s SHA=%s\n' \"\$KAPSIS_REMOTE_BRANCH\" \"\$KAPSIS_PUSHED_SHA\" > $out; echo https://pr.example/1"
    PR_URL=""; _KAPSIS_PR_HOOK_STATUS=""
    run_post_push_hook "$r" "feature/x" "main" "deadbeef" "$hook"
    assert_equals "ok" "${_KAPSIS_PR_HOOK_STATUS:-}" "hook status ok"
    assert_file_contains "$out" "BRANCH=feature/x SHA=deadbeef" "hook received env"
    assert_equals "https://pr.example/1" "${PR_URL:-}" "PR_URL captured from hook stdout"
    rm -rf "$r" "$out"
}

test_post_push_hook_unset_skips() {
    log_test "run_post_push_hook: empty command => skipped"
    _KAPSIS_PR_HOOK_STATUS=""
    run_post_push_hook "/tmp" "feature/x" "main" "deadbeef" ""
    assert_equals "skipped" "${_KAPSIS_PR_HOOK_STATUS:-}" "unset hook = skipped"
}

test_post_push_hook_failure_surfaced() {
    log_test "run_post_push_hook: hook failure is surfaced, not swallowed"
    local r; r=$(_mk_repo)
    _KAPSIS_PR_HOOK_STATUS=""
    run_post_push_hook "$r" "feature/x" "main" "deadbeef" "exit 3"
    assert_matches "${_KAPSIS_PR_HOOK_STATUS:-}" "^failed:" "hook failure surfaced as failed:*"
    rm -rf "$r"
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
    log_info "Fix #186: Cache-tree rebuild after index sync"
    log_info ""

    # Run tests
    run_test test_sync_index_git_as_file
    run_test test_sync_index_git_as_directory
    run_test test_sync_index_no_git
    run_test test_sync_index_no_index_in_sanitized
    run_test test_sync_index_cache_tree_rebuild

    log_info "=== validate_staged_files hardening ==="
    run_test test_reject_uppercase_kapsis_dir
    run_test test_reject_symlink_entry
    run_test test_reject_gitlink_entry
    run_test test_accept_clean_regular_file

    log_info "=== push_changes fetch-before-push ==="
    run_test test_push_refuses_non_fast_forward
    run_test test_push_fast_forward_succeeds
    run_test test_push_first_push_new_branch_succeeds

    log_info "=== post-push PR hook ==="
    run_test test_post_push_hook_invoked_with_env
    run_test test_post_push_hook_unset_skips
    run_test test_post_push_hook_failure_surfaced

    # Print summary
    print_summary
}

main "$@"
