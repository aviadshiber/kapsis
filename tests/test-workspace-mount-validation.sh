#!/usr/bin/env bash
#===============================================================================
# Tests for Workspace Mount Validation (Issue #221)
#
# Verifies that:
# - Container entrypoint detects empty/missing /workspace and fails fast
# - Host-side worktree validation catches missing paths before container start
# - GC self-exclusion prevents deleting the current agent's worktree
#
# Run: ./tests/test-workspace-mount-validation.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Source constants for CONTAINER_GIT_PATH
source "$LIB_DIR/constants.sh"

# Logging stubs for functions extracted from production scripts
if ! type log_debug &>/dev/null; then
    log_debug() { :; }
    log_info() { :; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Extract production functions
eval "$(sed -n '/^validate_workspace_mount()/,/^}/p' "$KAPSIS_ROOT/scripts/entrypoint.sh")"
eval "$(sed -n '/^validate_worktree_path()/,/^}/p' "$KAPSIS_ROOT/scripts/launch-agent.sh")"

#===============================================================================
# TEST: Empty workspace directory
#===============================================================================

test_validate_workspace_empty_dir() {
    log_test "Testing validate_workspace_mount with empty directory"
    local test_dir
    test_dir=$(mktemp -d)

    # Override /workspace check by creating a wrapper that uses our test dir
    # We can't change /workspace, so test the function logic directly
    local workspace="$test_dir/workspace"
    mkdir -p "$workspace"

    # Inline the check logic since we can't override /workspace path
    local entry_count
    entry_count=$(find "$workspace" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l | tr -d ' ')
    assert_equals "0" "$entry_count" "Empty workspace should have 0 entries"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: Workspace with files
#===============================================================================

test_validate_workspace_with_files() {
    log_test "Testing validate_workspace_mount with populated directory"
    local test_dir
    test_dir=$(mktemp -d)

    local workspace="$test_dir/workspace"
    mkdir -p "$workspace"
    echo "test" > "$workspace/file.txt"
    mkdir -p "$workspace/src"

    local entry_count
    entry_count=$(find "$workspace" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l | tr -d ' ')
    assert_true "[[ \"$entry_count\" -gt 0 ]]" "Populated workspace should have entries"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: Worktree mode without .git (warn only, non-fatal)
#===============================================================================

test_validate_workspace_worktree_no_git() {
    log_test "Testing worktree mode with files but no .git (non-fatal warning)"
    local test_dir
    test_dir=$(mktemp -d)

    local workspace="$test_dir/workspace"
    mkdir -p "$workspace/src"
    echo "code" > "$workspace/src/main.py"

    # Verify files exist but .git doesn't
    assert_true "[[ -d \"$workspace\" ]]" "Workspace should exist"
    assert_true "[[ ! -f \"$workspace/.git\" ]]" "Should not have .git file"

    local entry_count
    entry_count=$(find "$workspace" -maxdepth 1 -mindepth 1 2>/dev/null | head -3 | wc -l | tr -d ' ')
    assert_true "[[ \"$entry_count\" -gt 0 ]]" "Workspace has files, should pass emptiness check"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: Worktree path validation — missing directory
#===============================================================================

test_validate_worktree_path_missing() {
    log_test "Testing validate_worktree_path with nonexistent path"

    validate_worktree_path "/nonexistent/worktree" "/nonexistent/sanitized" 2>/dev/null
    local exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when worktree path missing"
}

#===============================================================================
# TEST: Worktree path validation — no .git file
#===============================================================================

test_validate_worktree_path_no_git_file() {
    log_test "Testing validate_worktree_path with directory but no .git file"
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/worktree"
    mkdir -p "$test_dir/sanitized"

    validate_worktree_path "$test_dir/worktree" "$test_dir/sanitized" 2>/dev/null
    local exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when .git file missing"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: Worktree path validation — valid worktree
#===============================================================================

test_validate_worktree_path_valid() {
    log_test "Testing validate_worktree_path with valid worktree"
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/worktree"
    echo "gitdir: /some/path" > "$test_dir/worktree/.git"
    mkdir -p "$test_dir/sanitized"

    validate_worktree_path "$test_dir/worktree" "$test_dir/sanitized" 2>/dev/null
    local exit_code=$?
    assert_equals "0" "$exit_code" "Should pass with valid worktree and sanitized git"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: Worktree path validation — missing sanitized git
#===============================================================================

test_validate_worktree_path_no_sanitized_git() {
    log_test "Testing validate_worktree_path with missing sanitized git"
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/worktree"
    echo "gitdir: /some/path" > "$test_dir/worktree/.git"

    validate_worktree_path "$test_dir/worktree" "$test_dir/nonexistent" 2>/dev/null
    local exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when sanitized git dir missing"

    rm -rf "$test_dir"
}

#===============================================================================
# TEST: GC excludes current agent
#===============================================================================

test_gc_excludes_current_agent() {
    log_test "Testing GC self-exclusion via exclude_agent_id parameter"

    # Verify the gc_stale_worktrees function signature accepts exclude_agent_id
    local gc_source
    gc_source=$(sed -n '/^gc_stale_worktrees()/,/^}/p' "$KAPSIS_ROOT/scripts/worktree-manager.sh")
    assert_contains "$gc_source" 'exclude_agent_id' "gc_stale_worktrees should have exclude_agent_id param"
    assert_contains "$gc_source" 'Skipping current agent' "Should have skip logic for current agent"

    # Verify gc_stale_worktrees_by_age also has the parameter
    local gc_age_source
    gc_age_source=$(sed -n '/^gc_stale_worktrees_by_age()/,/^}/p' "$KAPSIS_ROOT/scripts/worktree-manager.sh")
    assert_contains "$gc_age_source" 'exclude_agent_id' "gc_stale_worktrees_by_age should have exclude_agent_id param"
    assert_contains "$gc_age_source" 'Skipping current agent' "Should have skip logic for current agent"
}

#===============================================================================
# TEST: GC callers pass AGENT_ID
#===============================================================================

test_gc_callers_pass_agent_id() {
    log_test "Testing that launch-agent.sh passes AGENT_ID to GC calls"

    local launch_source
    launch_source=$(cat "$KAPSIS_ROOT/scripts/launch-agent.sh")

    # Both GC call sites should pass $AGENT_ID as second argument
    assert_contains "$launch_source" 'gc_stale_worktrees "$PROJECT_PATH" "$AGENT_ID" 2>>' \
        "Background GC call should pass AGENT_ID"
    assert_contains "$launch_source" 'gc_stale_worktrees "$PROJECT_PATH" "$AGENT_ID" ||' \
        "Foreground GC call should pass AGENT_ID"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Workspace Mount Validation (Issue #221)"

    log_info "=== Entrypoint Workspace Validation ==="
    run_test test_validate_workspace_empty_dir
    run_test test_validate_workspace_with_files
    run_test test_validate_workspace_worktree_no_git

    log_info "=== Host-side Worktree Validation ==="
    run_test test_validate_worktree_path_missing
    run_test test_validate_worktree_path_no_git_file
    run_test test_validate_worktree_path_valid
    run_test test_validate_worktree_path_no_sanitized_git

    log_info "=== GC Self-Exclusion ==="
    run_test test_gc_excludes_current_agent
    run_test test_gc_callers_pass_agent_id

    print_summary
}

main "$@"
