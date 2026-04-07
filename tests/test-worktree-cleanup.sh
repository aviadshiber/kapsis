#!/usr/bin/env bash
#===============================================================================
# Test: Worktree Auto-Cleanup (Fix #169)
#
# Verifies automatic worktree cleanup behavior:
# - Worktrees are removed after agent completion (default)
# - --keep-worktree preserves worktrees
# - gc_stale_worktrees cleans completed agent worktrees
#
# These tests do NOT require containers — they test worktree-manager
# functions directly against a temporary git repository.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST HELPERS
#===============================================================================

# Create a minimal worktree for cleanup testing (no container needed)
setup_cleanup_test() {
    local agent_id="$1"

    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    CLEANUP_WORKTREE_PATH="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Create worktree
    create_worktree "$TEST_PROJECT" "$agent_id" "feature/cleanup-test-${agent_id}" >/dev/null
}

teardown_cleanup_test() {
    local agent_id="$1"

    # Force remove if still exists
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh" 2>/dev/null || true
    cleanup_worktree "$TEST_PROJECT" "$agent_id" 2>/dev/null || true
}

#===============================================================================
# TEST CASES
#===============================================================================

test_cleanup_worktree_removes_worktree() {
    log_test "Testing cleanup_worktree removes worktree directory"

    local agent_id="cleanup-rm-$$"
    setup_cleanup_test "$agent_id"

    # Worktree should exist
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before cleanup"

    # Run cleanup
    cleanup_worktree "$TEST_PROJECT" "$agent_id"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "Worktree should be removed after cleanup"
        return 1
    fi

    return 0
}

test_gc_cleans_stale_completed_worktrees() {
    log_test "Testing gc_stale_worktrees cleans completed agent worktrees"

    local agent_id="gc-complete-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")

    # Create a status file marking this agent as complete
    local status_dir="${HOME}/.kapsis/status"
    mkdir -p "$status_dir"
    local status_file="${status_dir}/kapsis-${project_name}-${agent_id}.json"
    echo '{"phase": "complete", "agent_id": "'"$agent_id"'"}' > "$status_file"

    # Worktree should exist before GC
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before GC"

    # Run GC
    gc_stale_worktrees "$TEST_PROJECT"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "GC should have removed completed agent's worktree"
        rm -f "$status_file"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Cleanup status file
    rm -f "$status_file"
    return 0
}

test_gc_preserves_running_worktrees() {
    log_test "Testing gc_stale_worktrees preserves running agent worktrees"

    local agent_id="gc-running-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")

    # Create a status file marking this agent as running (not complete)
    local status_dir="${HOME}/.kapsis/status"
    mkdir -p "$status_dir"
    local status_file="${status_dir}/kapsis-${project_name}-${agent_id}.json"
    echo '{"phase": "running", "agent_id": "'"$agent_id"'"}' > "$status_file"

    # Run GC
    gc_stale_worktrees "$TEST_PROJECT"

    # Worktree should still exist (agent is running)
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC should preserve running agent's worktree"

    # Cleanup
    rm -f "$status_file"
    teardown_cleanup_test "$agent_id"
}

test_keep_worktree_preserves_worktree() {
    log_test "Testing --keep-worktree preserves worktree (simulated post-container path)"

    local agent_id="keep-wt-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Simulate the post_container_worktree cleanup decision with KEEP_WORKTREE=true
    # This mirrors the actual if/else in launch-agent.sh post_container_worktree()
    local KEEP_WORKTREE=true
    local EXIT_CODE=0
    if [[ "$KEEP_WORKTREE" == "true" ]] || [[ "$EXIT_CODE" -ne 0 ]]; then
        : # Preserve — no cleanup (matches production code path)
    else
        cleanup_worktree "$TEST_PROJECT" "$agent_id"
        prune_worktrees "$TEST_PROJECT"
    fi

    assert_dir_exists "$worktree_path" "Worktree should exist when keep-worktree is true"

    # Cleanup for next test
    teardown_cleanup_test "$agent_id"
}

test_default_cleanup_removes_worktree() {
    log_test "Testing default behavior removes worktree (simulated post-container path)"

    local agent_id="default-rm-$$"
    setup_cleanup_test "$agent_id"

    local project_name
    project_name=$(basename "$TEST_PROJECT")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

    # Simulate the default KEEP_WORKTREE=false path
    cleanup_worktree "$TEST_PROJECT" "$agent_id"
    prune_worktrees "$TEST_PROJECT"

    if [[ -d "$worktree_path" ]]; then
        log_fail "Worktree should be removed when keep-worktree is false (default)"
        return 1
    fi

    return 0
}

test_gc_handles_no_status_dir() {
    log_test "Testing gc_stale_worktrees handles missing status directory"

    # Use a temporary project path whose status files won't exist
    # This avoids moving the real ~/.kapsis/status directory (which could
    # affect other running agents)
    local fake_project
    fake_project=$(mktemp -d)
    mkdir -p "$fake_project/.git"
    git -C "$fake_project" init --quiet

    # GC should return 0 without errors (no matching status files)
    local exit_code=0
    gc_stale_worktrees "$fake_project" 2>/dev/null || exit_code=$?

    rm -rf "$fake_project"

    assert_equals "0" "$exit_code" "GC should succeed with no matching status files"
}

#===============================================================================
# BRANCH CLEANUP TESTS (Fix #183)
#===============================================================================

test_cleanup_branch_deletes_agent_branch() {
    log_test "Testing cleanup_branch deletes a merged agent branch"

    local branch_name="ai-agent/test-delete-$$"

    cd "$TEST_PROJECT"
    git checkout -b "$branch_name" 2>/dev/null
    git checkout - 2>/dev/null

    # Verify branch exists
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        log_fail "Branch should exist before cleanup"
        return 1
    fi

    # Disable require_pushed for this test (local-only branch)
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
        cleanup_branch "$TEST_PROJECT" "$branch_name"

    # Verify branch is gone
    if git rev-parse --verify "$branch_name" &>/dev/null 2>&1; then
        log_fail "Branch should be deleted after cleanup_branch"
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    return 0
}

test_cleanup_branch_preserves_protected() {
    log_test "Testing cleanup_branch preserves protected branches"

    cd "$TEST_PROJECT"
    local branch_name="main"

    # main is in the default protected list — cleanup_branch should skip it
    local exit_code=0
    cleanup_branch "$TEST_PROJECT" "$branch_name" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for protected branch"
}

test_cleanup_branch_preserves_checked_out() {
    log_test "Testing cleanup_branch preserves branch checked out in worktree"

    local agent_id="branch-checkout-$$"
    local branch_name="feature/checked-out-test-${agent_id}"

    # Create a worktree with this branch (making it checked out)
    setup_cleanup_test "$agent_id"

    cd "$TEST_PROJECT"

    # Try to delete the branch that's checked out in the worktree
    local exit_code=0
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
        cleanup_branch "$TEST_PROJECT" "feature/cleanup-test-${agent_id}" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for checked-out branch"

    teardown_cleanup_test "$agent_id"
}

test_cleanup_branch_preserves_unpushed() {
    log_test "Testing cleanup_branch preserves branches without remote (require_pushed=true)"

    local branch_name="ai-agent/unpushed-test-$$"

    cd "$TEST_PROJECT"
    git checkout -b "$branch_name" 2>/dev/null
    # Make a commit so the branch has content
    echo "test" > "test-unpushed-$$"
    git add "test-unpushed-$$"
    git commit -m "test commit" --quiet 2>/dev/null
    git checkout - 2>/dev/null

    # With require_pushed=true (default), should skip
    local exit_code=0
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="true" \
        cleanup_branch "$TEST_PROJECT" "$branch_name" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "cleanup_branch should return 1 (skipped) for unpushed branch"

    # Cleanup
    git branch -D "$branch_name" 2>/dev/null || true
}

test_gc_age_cleans_old_worktrees() {
    log_test "Testing gc_stale_worktrees_by_age cleans old worktrees"

    local agent_id="gc-age-old-$$"
    setup_cleanup_test "$agent_id"

    # Backdate the worktree directory to 8 days ago (older than default 7-day TTL)
    local old_time=$(($(date +%s) - 8 * 24 * 3600))
    touch -t "$(date -r "$old_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old_time" +%Y%m%d%H%M.%S 2>/dev/null)" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || {
        # Fallback: try GNU touch
        touch -d "@$old_time" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || true
    }

    # Run age-based GC with 168h (7 days) max age
    KAPSIS_CLEANUP_BRANCH_ENABLED="false" \
        gc_stale_worktrees_by_age "$TEST_PROJECT" 168 "false"

    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "GC-age should have removed worktree older than 7 days"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    return 0
}

test_gc_age_preserves_recent_worktrees() {
    log_test "Testing gc_stale_worktrees_by_age preserves recent worktrees"

    local agent_id="gc-age-new-$$"
    setup_cleanup_test "$agent_id"

    # Worktree was just created, should be preserved
    KAPSIS_CLEANUP_BRANCH_ENABLED="false" \
        gc_stale_worktrees_by_age "$TEST_PROJECT" 168 "false"

    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC-age should preserve recent worktree"

    teardown_cleanup_test "$agent_id"
}

test_gc_age_zero_disables() {
    log_test "Testing gc_stale_worktrees_by_age disabled when max_age_hours=0"

    local agent_id="gc-age-zero-$$"
    setup_cleanup_test "$agent_id"

    # Backdate the worktree
    local old_time=$(($(date +%s) - 30 * 24 * 3600))
    touch -t "$(date -r "$old_time" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old_time" +%Y%m%d%H%M.%S 2>/dev/null)" "$CLEANUP_WORKTREE_PATH" 2>/dev/null || true

    # With max_age_hours=0, cleanup should be disabled
    gc_stale_worktrees_by_age "$TEST_PROJECT" 0 "false"

    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "GC-age should be disabled when max_age_hours=0"

    teardown_cleanup_test "$agent_id"
}

test_cleanup_worktree_with_branch_deletion() {
    log_test "Testing cleanup_worktree with delete_branch=true"

    local agent_id="wt-branch-del-$$"
    local branch_name="feature/cleanup-test-${agent_id}"
    setup_cleanup_test "$agent_id"

    # Verify both worktree and branch exist
    assert_dir_exists "$CLEANUP_WORKTREE_PATH" "Worktree should exist before cleanup"

    cd "$TEST_PROJECT"
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        log_fail "Branch should exist before cleanup"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Cleanup with branch deletion (require_pushed=false, add test prefix for local test)
    KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="false" \
    KAPSIS_CLEANUP_BRANCH_PREFIXES="ai-agent/|kapsis/|feature/cleanup-test" \
        cleanup_worktree "$TEST_PROJECT" "$agent_id" "true"

    # Worktree should be gone
    if [[ -d "$CLEANUP_WORKTREE_PATH" ]]; then
        log_fail "Worktree should be removed"
        teardown_cleanup_test "$agent_id"
        return 1
    fi

    # Branch should be gone
    cd "$TEST_PROJECT"
    if git rev-parse --verify "$branch_name" &>/dev/null 2>&1; then
        log_fail "Branch should be deleted when delete_branch=true"
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    return 0
}

test_cleanup_worktrees_flag_accepted() {
    log_test "Testing --worktrees flag is accepted by kapsis-cleanup.sh (Fix #220)"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
    local content
    content=$(cat "$cleanup_script")

    # Verify the flag is handled in the arg parser
    assert_contains "$content" "--worktrees)" "Arg parser should handle --worktrees"
    assert_contains "$content" "CLEAN_WORKTREES=true" "Should set CLEAN_WORKTREES=true"

    # Verify --worktrees --dry-run does NOT print "Unknown option"
    local output
    local exit_code=0
    output=$("$cleanup_script" --worktrees --dry-run 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "--worktrees should not cause exit 1"

    if echo "$output" | grep -q "Unknown option"; then
        log_fail "--worktrees should not trigger 'Unknown option' error"
        return 1
    fi

    return 0
}

test_cleanup_volumes_and_worktrees_combined() {
    log_test "Testing --volumes --worktrees combined flags work (Fix #220)"

    local cleanup_script="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

    # This is the exact reproduction case from issue #220
    local exit_code=0
    local output
    output=$("$cleanup_script" --volumes --worktrees --dry-run 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" "--volumes --worktrees should not cause exit 1"

    if echo "$output" | grep -q "Unknown option"; then
        log_fail "--volumes --worktrees should not trigger 'Unknown option' error"
        return 1
    fi

    return 0
}

test_cleanup_config_env_override() {
    log_test "Testing environment variables override default constants"

    # Source constants for defaults
    source "$KAPSIS_ROOT/scripts/lib/constants.sh" 2>/dev/null || true

    # Verify defaults exist
    assert_equals "168" "$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS" \
        "Default worktree max age should be 168"
    assert_equals "false" "$KAPSIS_DEFAULT_CLEANUP_BRANCH_ENABLED" \
        "Default branch cleanup should be disabled"

    # Verify env var takes precedence
    local result
    KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS=24
    result="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS}"
    assert_equals "24" "$result" "Env var should override default"
    unset KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS

    # Without env var, default should be used
    result="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-$KAPSIS_DEFAULT_CLEANUP_WORKTREE_MAX_AGE_HOURS}"
    assert_equals "168" "$result" "Default should be used when env var is unset"

    return 0
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Worktree Auto-Cleanup (Fix #169, #183)"

    # Check for jq (required by gc_stale_worktrees)
    if ! command -v jq &>/dev/null; then
        log_skip "jq not installed (required for GC tests)"
        exit 0
    fi

    # Setup
    setup_test_project
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    # Run original tests (Fix #169)
    run_test test_cleanup_worktree_removes_worktree
    run_test test_keep_worktree_preserves_worktree
    run_test test_default_cleanup_removes_worktree
    run_test test_gc_cleans_stale_completed_worktrees
    run_test test_gc_preserves_running_worktrees
    run_test test_gc_handles_no_status_dir

    # Run new tests (Fix #183)
    run_test test_cleanup_branch_deletes_agent_branch
    run_test test_cleanup_branch_preserves_protected
    run_test test_cleanup_branch_preserves_checked_out
    run_test test_cleanup_branch_preserves_unpushed
    run_test test_gc_age_cleans_old_worktrees
    run_test test_gc_age_preserves_recent_worktrees
    run_test test_gc_age_zero_disables
    run_test test_cleanup_worktree_with_branch_deletion
    run_test test_cleanup_worktrees_flag_accepted
    run_test test_cleanup_volumes_and_worktrees_combined
    run_test test_cleanup_config_env_override

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
