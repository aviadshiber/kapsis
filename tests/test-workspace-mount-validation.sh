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

# Simulate a real agent environment: validate_workspace_mount skips when
# KAPSIS_AGENT_ID is unset (probe containers).  Unit tests must set it so the
# function exercises its validation logic.
#
# NOTE: This export applies to ALL tests in this file.  Any future test that
# needs to cover the "probe container / no KAPSIS_AGENT_ID" path must
# explicitly unset it within the test function:
#   local saved=$KAPSIS_AGENT_ID; unset KAPSIS_AGENT_ID
#   ... test ...
#   export KAPSIS_AGENT_ID="$saved"
export KAPSIS_AGENT_ID="${KAPSIS_AGENT_ID:-test-agent}"

# Helper to create a temp dir with automatic cleanup
_TEST_DIRS=()
make_test_dir() {
    local d
    d=$(mktemp -d)
    _TEST_DIRS+=("$d")
    echo "$d"
}
cleanup_test_dirs() {
    for d in "${_TEST_DIRS[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    _TEST_DIRS=()
}

#===============================================================================
# TEST: Workspace does not exist
#===============================================================================

test_validate_workspace_not_exists() {
    log_test "Testing validate_workspace_mount when directory does not exist"
    local exit_code=0
    validate_workspace_mount "overlay" "/nonexistent/workspace-$$" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when workspace dir does not exist"
}

#===============================================================================
# TEST: Empty workspace directory
#===============================================================================

test_validate_workspace_empty_dir() {
    log_test "Testing validate_workspace_mount with empty directory"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/workspace"

    local exit_code=0
    validate_workspace_mount "overlay" "$test_dir/workspace" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Empty workspace should fail validation"
}

#===============================================================================
# TEST: Workspace with files
#===============================================================================

test_validate_workspace_with_files() {
    log_test "Testing validate_workspace_mount with populated directory"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/workspace/src"
    echo "test" > "$test_dir/workspace/file.txt"

    local exit_code=0
    validate_workspace_mount "overlay" "$test_dir/workspace" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Populated workspace should pass validation"
}

#===============================================================================
# TEST: Worktree mode with .git file (no warning)
#===============================================================================

test_validate_workspace_worktree_with_git() {
    log_test "Testing worktree mode with .git file present (no warning)"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/workspace"
    echo "gitdir: /some/path" > "$test_dir/workspace/.git"
    echo "code" > "$test_dir/workspace/main.py"

    local exit_code=0
    validate_workspace_mount "worktree" "$test_dir/workspace" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Worktree with .git file should pass"
}

#===============================================================================
# TEST: Worktree mode without .git (warn only, non-fatal)
#===============================================================================

test_validate_workspace_worktree_no_git() {
    log_test "Testing worktree mode with files but no .git (non-fatal warning)"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/workspace/src"
    echo "code" > "$test_dir/workspace/src/main.py"

    # Should pass (non-fatal) but emit a warning
    local exit_code=0
    validate_workspace_mount "worktree" "$test_dir/workspace" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Worktree mode with files but no .git should still pass"
}

#===============================================================================
# TEST: Overlay mode skips git check
#===============================================================================

test_validate_workspace_overlay_no_git_check() {
    log_test "Testing overlay mode does not check for .git"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/workspace"
    echo "data" > "$test_dir/workspace/file.txt"

    local exit_code=0
    validate_workspace_mount "overlay" "$test_dir/workspace" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Overlay mode should pass without .git"
}

#===============================================================================
# TEST: Worktree path validation — missing directory
#===============================================================================

test_validate_worktree_path_missing() {
    log_test "Testing validate_worktree_path with nonexistent path"

    local exit_code=0
    validate_worktree_path "/nonexistent/worktree" "/nonexistent/sanitized" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when worktree path missing"
}

#===============================================================================
# TEST: Worktree path validation — no .git file
#===============================================================================

test_validate_worktree_path_no_git_file() {
    log_test "Testing validate_worktree_path with directory but no .git file"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/worktree"
    mkdir -p "$test_dir/sanitized"

    local exit_code=0
    validate_worktree_path "$test_dir/worktree" "$test_dir/sanitized" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when .git file missing"
}

#===============================================================================
# TEST: Worktree path validation — valid worktree
#===============================================================================

test_validate_worktree_path_valid() {
    log_test "Testing validate_worktree_path with valid worktree"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/worktree"
    echo "gitdir: /some/path" > "$test_dir/worktree/.git"
    mkdir -p "$test_dir/sanitized"

    local exit_code=0
    validate_worktree_path "$test_dir/worktree" "$test_dir/sanitized" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Should pass with valid worktree and sanitized git"
}

#===============================================================================
# TEST: Worktree path validation — missing sanitized git
#===============================================================================

test_validate_worktree_path_no_sanitized_git() {
    log_test "Testing validate_worktree_path with missing sanitized git"
    local test_dir
    test_dir=$(make_test_dir)
    mkdir -p "$test_dir/worktree"
    echo "gitdir: /some/path" > "$test_dir/worktree/.git"

    local exit_code=0
    validate_worktree_path "$test_dir/worktree" "$test_dir/nonexistent" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should fail when sanitized git dir missing"
}

#===============================================================================
# TEST: GC behavioral — excludes current agent
#===============================================================================

test_gc_excludes_current_agent() {
    log_test "Testing GC self-exclusion skips current agent's worktree"
    local test_dir
    test_dir=$(make_test_dir)

    local project_name="testproject"
    local project_path="$test_dir/$project_name"
    mkdir -p "$project_path/.git"

    # Set up worktree base and status dir
    local worktree_base="$test_dir/worktrees"
    local status_dir="$test_dir/.kapsis/status"
    mkdir -p "$worktree_base" "$status_dir"

    # Create two worktrees: "current" (to exclude) and "stale" (to clean)
    mkdir -p "$worktree_base/${project_name}-current"
    mkdir -p "$worktree_base/${project_name}-stale"

    # Create status files showing both as complete
    echo '{"phase":"complete","agent_id":"current"}' > "$status_dir/kapsis-${project_name}-current.json"
    echo '{"phase":"complete","agent_id":"stale"}' > "$status_dir/kapsis-${project_name}-stale.json"

    # Override paths for isolated test
    local orig_home="$HOME"
    KAPSIS_WORKTREE_BASE="$worktree_base"
    HOME="$test_dir"
    export KAPSIS_WORKTREE_BASE HOME

    # Source the production GC function
    eval "$(sed -n '/^gc_stale_worktrees()/,/^}/p' "$KAPSIS_ROOT/scripts/worktree-manager.sh")"

    # Stub cleanup_worktree to record which agents get cleaned
    local cleaned_agents=""
    cleanup_worktree() { cleaned_agents="${cleaned_agents} $2"; }
    prune_worktrees() { :; }
    # Stub the age-based GC to avoid side effects
    gc_stale_worktrees_by_age() { :; }

    # Run GC excluding "current"
    gc_stale_worktrees "$project_path" "current" 2>/dev/null || true

    # Restore HOME
    HOME="$orig_home"
    export HOME

    assert_contains "$cleaned_agents" "stale" "Should clean the stale agent"
    assert_not_contains "$cleaned_agents" "current" "Should NOT clean the excluded (current) agent"
}

#===============================================================================
# TEST: GC callers pass AGENT_ID
#===============================================================================

test_gc_callers_pass_agent_id() {
    log_test "Testing that launch-agent.sh passes AGENT_ID to GC calls"

    local launch_source
    launch_source=$(cat "$KAPSIS_ROOT/scripts/launch-agent.sh")

    # Both GC call sites should pass $AGENT_ID as second argument
    assert_contains "$launch_source" 'gc_stale_worktrees "$PROJECT_PATH" "$AGENT_ID"' \
        "GC calls should pass AGENT_ID"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Workspace Mount Validation (Issue #221)"

    log_info "=== Entrypoint Workspace Validation ==="
    run_test test_validate_workspace_not_exists
    run_test test_validate_workspace_empty_dir
    run_test test_validate_workspace_with_files
    run_test test_validate_workspace_worktree_with_git
    run_test test_validate_workspace_worktree_no_git
    run_test test_validate_workspace_overlay_no_git_check

    log_info "=== Host-side Worktree Validation ==="
    run_test test_validate_worktree_path_missing
    run_test test_validate_worktree_path_no_git_file
    run_test test_validate_worktree_path_valid
    run_test test_validate_worktree_path_no_sanitized_git

    log_info "=== GC Self-Exclusion ==="
    run_test test_gc_excludes_current_agent
    run_test test_gc_callers_pass_agent_id

    cleanup_test_dirs

    print_summary
}

main "$@"
