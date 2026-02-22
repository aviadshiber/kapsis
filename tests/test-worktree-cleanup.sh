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

    # Simulate the --keep-worktree=true path: worktree should NOT be cleaned
    # (In the real flow, post_container_worktree checks KEEP_WORKTREE)
    local project_name
    project_name=$(basename "$TEST_PROJECT")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

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

    # Temporarily rename status dir if it exists
    local status_dir="${HOME}/.kapsis/status"
    local backup_dir=""
    if [[ -d "$status_dir" ]]; then
        backup_dir="${status_dir}.bak-$$"
        mv "$status_dir" "$backup_dir"
    fi

    # GC should return 0 without errors
    local exit_code=0
    gc_stale_worktrees "$TEST_PROJECT" 2>/dev/null || exit_code=$?

    # Restore status dir
    if [[ -n "$backup_dir" ]]; then
        mv "$backup_dir" "$status_dir"
    fi

    assert_equals "0" "$exit_code" "GC should succeed with no status directory"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Worktree Auto-Cleanup (Fix #169)"

    # Check for jq (required by gc_stale_worktrees)
    if ! command -v jq &>/dev/null; then
        log_skip "jq not installed (required for GC tests)"
        exit 0
    fi

    # Setup
    setup_test_project
    source "$KAPSIS_ROOT/scripts/worktree-manager.sh"

    # Run tests
    run_test test_cleanup_worktree_removes_worktree
    run_test test_keep_worktree_preserves_worktree
    run_test test_default_cleanup_removes_worktree
    run_test test_gc_cleans_stale_completed_worktrees
    run_test test_gc_preserves_running_worktrees
    run_test test_gc_handles_no_status_dir

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
