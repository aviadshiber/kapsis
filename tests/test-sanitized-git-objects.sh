#!/usr/bin/env bash
#===============================================================================
# Tests for Sanitized Git Objects Symlink Fix (Issue #219)
#
# Verifies that the objects symlink in sanitized-git directories is re-pointed
# from the container path (/workspace/.git-objects) to the host path after
# container exit, so post-container git operations can access objects.
#
# Tests exercise the production repoint_sanitized_git_objects() function
# sourced from launch-agent.sh.
#
# Run: ./tests/test-sanitized-git-objects.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Source constants for CONTAINER_OBJECTS_PATH
source "$LIB_DIR/constants.sh"

# Source the production function we're testing
# repoint_sanitized_git_objects() is defined in launch-agent.sh
# We need logging stubs since launch-agent.sh expects them
if ! type log_debug &>/dev/null; then
    log_debug() { :; }
    log_warn() { echo "[WARN] $*" >&2; }
fi
# Extract just the function from launch-agent.sh
eval "$(sed -n '/^repoint_sanitized_git_objects()/,/^}/p' "$KAPSIS_ROOT/scripts/launch-agent.sh")"

setup_test_env() {
    TEST_DIR=$(mktemp -d)
    # Simulate a project with .git/objects
    mkdir -p "$TEST_DIR/project/.git/objects/pack"
    echo "test-object" > "$TEST_DIR/project/.git/objects/test.obj"

    # Simulate sanitized git directory with container-path symlink
    mkdir -p "$TEST_DIR/sanitized-git/abc123"
    ln -sfn "$CONTAINER_OBJECTS_PATH" "$TEST_DIR/sanitized-git/abc123/objects"
}

cleanup_test_env() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
    TEST_DIR=""
}

#===============================================================================
# TEST: Basic path re-pointing via production function
#===============================================================================

test_repoint_via_production_function() {
    log_test "Testing repoint_sanitized_git_objects() re-points symlink"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"

    # Before: symlink points to container path
    local before
    before=$(readlink "$sanitized/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$before" "Before: should point to container path"

    # Call production function
    repoint_sanitized_git_objects "$sanitized" "$host_objects"

    # After: symlink points to host path
    local after
    after=$(readlink "$sanitized/objects")
    assert_equals "$host_objects" "$after" "After: should point to host objects path"

    # Verify the symlink target exists and is accessible
    assert_true "[[ -d \"$sanitized/objects\" ]]" "Symlink target should be a valid directory"
    assert_true "[[ -f \"$sanitized/objects/test.obj\" ]]" "Should be able to read through symlink"

    cleanup_test_env
}

#===============================================================================
# TEST: Skip when sanitized git directory doesn't exist
#===============================================================================

test_skip_when_no_sanitized_git() {
    log_test "Testing skip when sanitized git directory doesn't exist"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"

    # Call production function with nonexistent sanitized git
    repoint_sanitized_git_objects "/nonexistent/path" "$TEST_DIR/project/.git/objects"

    # Original symlink should be unchanged
    local current
    current=$(readlink "$sanitized/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$current" "Should remain unchanged when sanitized git missing"

    cleanup_test_env
}

#===============================================================================
# TEST: Skip when objects_path is empty
#===============================================================================

test_skip_when_no_objects_path() {
    log_test "Testing skip when objects_path is empty"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"

    # Call production function with empty objects path
    repoint_sanitized_git_objects "$sanitized" ""

    # Original symlink should be unchanged (no kapsis-meta fallback)
    local current
    current=$(readlink "$sanitized/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$current" "Should remain unchanged when objects_path empty"

    cleanup_test_env
}

#===============================================================================
# TEST: Fallback to kapsis-meta when objects_path empty
#===============================================================================

test_fallback_to_kapsis_meta() {
    log_test "Testing fallback to HOST_OBJECTS_PATH from kapsis-meta"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"

    # Write kapsis-meta with HOST_OBJECTS_PATH
    cat > "$sanitized/kapsis-meta" << EOF
# Kapsis Sanitized Git Metadata
WORKTREE_PATH=/tmp/test-worktree
PROJECT_PATH=$TEST_DIR/project
PARENT_GIT=$TEST_DIR/project/.git
AGENT_ID=abc123
BRANCH=test-branch
HOST_OBJECTS_PATH=$host_objects
EOF

    # Call production function with empty objects_path — should fall back to kapsis-meta
    repoint_sanitized_git_objects "$sanitized" ""

    local after
    after=$(readlink "$sanitized/objects")
    assert_equals "$host_objects" "$after" "Should fall back to HOST_OBJECTS_PATH from kapsis-meta"

    cleanup_test_env
}

#===============================================================================
# TEST: kapsis-meta contains HOST_OBJECTS_PATH (production write)
#===============================================================================

test_kapsis_meta_written_by_production() {
    log_test "Testing prepare_sanitized_git writes HOST_OBJECTS_PATH to kapsis-meta"

    # Verify the production source contains the HOST_OBJECTS_PATH line
    local wm_source="$KAPSIS_ROOT/scripts/worktree-manager.sh"
    local grep_result
    grep_result=$(grep "HOST_OBJECTS_PATH=" "$wm_source" 2>/dev/null || echo "")
    assert_contains "$grep_result" "HOST_OBJECTS_PATH=" "worktree-manager.sh should write HOST_OBJECTS_PATH"
    assert_contains "$grep_result" '.git/objects' "HOST_OBJECTS_PATH should reference .git/objects"
}

#===============================================================================
# TEST: Container path symlink is dangling on host
#===============================================================================

test_container_symlink_is_dangling() {
    log_test "Testing container path symlink is dangling on host"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"

    # The container path should not exist on the host
    assert_true "[[ ! -e \"$sanitized/objects\" ]]" "Container path symlink should be dangling on host"
    assert_true "[[ -L \"$sanitized/objects\" ]]" "Should still be a symlink (just dangling)"

    cleanup_test_env
}

#===============================================================================
# TEST: Objects symlink absent (fresh sanitized-git dir)
#===============================================================================

test_repoint_when_symlink_absent() {
    log_test "Testing re-point when objects symlink doesn't exist yet"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"

    # Remove the symlink entirely
    rm -f "$sanitized/objects"
    assert_true "[[ ! -e \"$sanitized/objects\" ]]" "Symlink should not exist"

    # Call production function — should create the symlink
    repoint_sanitized_git_objects "$sanitized" "$host_objects"

    local after
    after=$(readlink "$sanitized/objects")
    assert_equals "$host_objects" "$after" "Should create new symlink to host objects"

    cleanup_test_env
}

#===============================================================================
# TEST: Idempotent re-point (already correct)
#===============================================================================

test_repoint_idempotent() {
    log_test "Testing re-point is safe when symlink already correct"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"

    # Set up symlink already pointing to host path
    ln -sfn "$host_objects" "$sanitized/objects"

    # Call production function — should be a no-op
    repoint_sanitized_git_objects "$sanitized" "$host_objects"

    local after
    after=$(readlink "$sanitized/objects")
    assert_equals "$host_objects" "$after" "Should remain pointing to host objects"
    assert_true "[[ -d \"$sanitized/objects\" ]]" "Should still resolve to directory"

    cleanup_test_env
}

#===============================================================================
# TEST: Real directory (not symlink) is not replaced
#===============================================================================

test_skip_when_objects_is_real_directory() {
    log_test "Testing skip when objects is a real directory (not symlink)"
    setup_test_env

    local sanitized="$TEST_DIR/sanitized-git/abc123"
    local host_objects="$TEST_DIR/project/.git/objects"

    # Replace symlink with a real directory
    rm -f "$sanitized/objects"
    mkdir -p "$sanitized/objects"
    echo "real-file" > "$sanitized/objects/real.obj"

    # Call production function — should skip (not a symlink)
    repoint_sanitized_git_objects "$sanitized" "$host_objects"

    # Should still be a real directory, not a symlink
    assert_true "[[ -d \"$sanitized/objects\" ]]" "Should still be a directory"
    assert_true "[[ ! -L \"$sanitized/objects\" ]]" "Should NOT be a symlink"
    assert_true "[[ -f \"$sanitized/objects/real.obj\" ]]" "Original contents should be preserved"

    cleanup_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Sanitized Git Objects Symlink (Issue #219)"

    log_info "=== Symlink Re-pointing ==="
    run_test test_repoint_via_production_function
    run_test test_container_symlink_is_dangling
    run_test test_repoint_when_symlink_absent
    run_test test_repoint_idempotent

    log_info "=== Guard Conditions ==="
    run_test test_skip_when_no_sanitized_git
    run_test test_skip_when_no_objects_path
    run_test test_skip_when_objects_is_real_directory

    log_info "=== Metadata ==="
    run_test test_kapsis_meta_written_by_production
    run_test test_fallback_to_kapsis_meta

    print_summary
}

main "$@"
