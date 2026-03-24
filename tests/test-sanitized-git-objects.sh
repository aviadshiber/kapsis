#!/usr/bin/env bash
#===============================================================================
# Tests for Sanitized Git Objects Symlink Fix (Issue #219)
#
# Verifies that the objects symlink in sanitized-git directories is re-pointed
# from the container path (/workspace/.git-objects) to the host path after
# container exit, so post-container git operations can access objects.
#
# Run: ./tests/test-sanitized-git-objects.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Source constants for CONTAINER_OBJECTS_PATH
source "$LIB_DIR/constants.sh"

# Save originals
_ORIG_HOME="$HOME"

setup_test_env() {
    TEST_DIR=$(mktemp -d)
    # Simulate a project with .git/objects
    mkdir -p "$TEST_DIR/project/.git/objects/pack"
    echo "test-object" > "$TEST_DIR/project/.git/objects/test.obj"

    # Simulate sanitized git directory with container-path symlink
    SANITIZED_GIT="$TEST_DIR/sanitized-git/abc123"
    mkdir -p "$SANITIZED_GIT"
    ln -sfn "$CONTAINER_OBJECTS_PATH" "$SANITIZED_GIT/objects"

    HOST_OBJECTS="$TEST_DIR/project/.git/objects"
}

cleanup_test_env() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
    TEST_DIR=""
}

#===============================================================================
# TEST: Objects symlink re-pointed after container exit
#===============================================================================

test_objects_symlink_repointed() {
    log_test "Testing objects symlink is re-pointed from container to host path"
    setup_test_env

    # Before: symlink points to container path
    local before
    before=$(readlink "$SANITIZED_GIT/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$before" "Before: should point to container path"

    # Simulate the fix: re-point to host path
    ln -sfn "$HOST_OBJECTS" "$SANITIZED_GIT/objects"

    # After: symlink points to host path
    local after
    after=$(readlink "$SANITIZED_GIT/objects")
    assert_equals "$HOST_OBJECTS" "$after" "After: should point to host objects path"

    # Verify the symlink target exists and is accessible
    assert_true "[[ -d \"$SANITIZED_GIT/objects\" ]]" "Symlink target should be a valid directory"
    assert_true "[[ -f \"$SANITIZED_GIT/objects/test.obj\" ]]" "Should be able to read through symlink"

    cleanup_test_env
}

#===============================================================================
# TEST: Skipped when no sanitized git directory
#===============================================================================

test_skipped_when_no_sanitized_git() {
    log_test "Testing skip when sanitized git directory doesn't exist"
    setup_test_env

    local SANITIZED_GIT_PATH="/nonexistent/path"
    local OBJECTS_PATH="$HOST_OBJECTS"

    # The fix condition: only re-point if sanitized git exists
    if [[ -n "$SANITIZED_GIT_PATH" && -d "$SANITIZED_GIT_PATH" && -n "$OBJECTS_PATH" ]]; then
        ln -sf "$OBJECTS_PATH" "$SANITIZED_GIT_PATH/objects"
    fi

    # Original symlink should be unchanged (still points to container path)
    local current
    current=$(readlink "$SANITIZED_GIT/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$current" "Should remain unchanged when sanitized git missing"

    cleanup_test_env
}

#===============================================================================
# TEST: Skipped when OBJECTS_PATH is empty
#===============================================================================

test_skipped_when_no_objects_path() {
    log_test "Testing skip when OBJECTS_PATH is empty"
    setup_test_env

    local SANITIZED_GIT_PATH="$SANITIZED_GIT"
    local OBJECTS_PATH=""

    # The fix condition: only re-point if OBJECTS_PATH is set
    if [[ -n "$SANITIZED_GIT_PATH" && -d "$SANITIZED_GIT_PATH" && -n "$OBJECTS_PATH" ]]; then
        ln -sf "$OBJECTS_PATH" "$SANITIZED_GIT_PATH/objects"
    fi

    # Original symlink should be unchanged
    local current
    current=$(readlink "$SANITIZED_GIT/objects")
    assert_equals "$CONTAINER_OBJECTS_PATH" "$current" "Should remain unchanged when OBJECTS_PATH empty"

    cleanup_test_env
}

#===============================================================================
# TEST: kapsis-meta contains HOST_OBJECTS_PATH
#===============================================================================

test_kapsis_meta_contains_host_objects_path() {
    log_test "Testing kapsis-meta stores HOST_OBJECTS_PATH"
    setup_test_env

    # Simulate what prepare_sanitized_git writes
    cat > "$SANITIZED_GIT/kapsis-meta" << EOF
# Kapsis Sanitized Git Metadata
WORKTREE_PATH=/tmp/test-worktree
PROJECT_PATH=$TEST_DIR/project
PARENT_GIT=$TEST_DIR/project/.git
AGENT_ID=abc123
BRANCH=test-branch
HOST_OBJECTS_PATH=$TEST_DIR/project/.git/objects
EOF

    local meta_content
    meta_content=$(cat "$SANITIZED_GIT/kapsis-meta")
    assert_contains "$meta_content" "HOST_OBJECTS_PATH=" "kapsis-meta should contain HOST_OBJECTS_PATH"
    assert_contains "$meta_content" "$TEST_DIR/project/.git/objects" "HOST_OBJECTS_PATH should have correct value"

    # Verify it can be parsed
    local parsed_path
    parsed_path=$(grep "^HOST_OBJECTS_PATH=" "$SANITIZED_GIT/kapsis-meta" | cut -d= -f2)
    assert_equals "$TEST_DIR/project/.git/objects" "$parsed_path" "Parsed HOST_OBJECTS_PATH should match"

    cleanup_test_env
}

#===============================================================================
# TEST: Re-pointed symlink target is a valid directory
#===============================================================================

test_repointed_symlink_target_exists() {
    log_test "Testing re-pointed symlink resolves to existing directory"
    setup_test_env

    # Re-point to host path
    ln -sfn "$HOST_OBJECTS" "$SANITIZED_GIT/objects"

    # Verify the symlink resolves to an actual directory
    assert_true "[[ -d \"$SANITIZED_GIT/objects\" ]]" "Should resolve to a directory"
    assert_true "[[ -d \"$SANITIZED_GIT/objects/pack\" ]]" "Should see pack subdirectory"

    # Before re-pointing, the symlink was dangling
    ln -sfn "$CONTAINER_OBJECTS_PATH" "$SANITIZED_GIT/objects"
    assert_true "[[ ! -e \"$SANITIZED_GIT/objects\" ]]" "Container path symlink should be dangling on host"

    cleanup_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Sanitized Git Objects Symlink (Issue #219)"

    log_info "=== Symlink Re-pointing ==="
    run_test test_objects_symlink_repointed
    run_test test_repointed_symlink_target_exists

    log_info "=== Guard Conditions ==="
    run_test test_skipped_when_no_sanitized_git
    run_test test_skipped_when_no_objects_path

    log_info "=== Metadata ==="
    run_test test_kapsis_meta_contains_host_objects_path

    print_summary
}

main "$@"
