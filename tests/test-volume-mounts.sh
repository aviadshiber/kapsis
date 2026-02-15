#!/usr/bin/env bash
#===============================================================================
# Test: Volume Mount Generation (scripts/lib/volume-mounts.sh)
#
# Unit tests for the volume mount library:
#   - generate_volume_mounts() — dispatch table
#   - generate_volume_mounts_worktree() — worktree mode
#   - generate_volume_mounts_overlay() — overlay mode
#   - add_common_volume_mounts() — shared mounts
#   - _snapshot_file() — file snapshots for race-free mounts
#   - generate_filesystem_includes() — whitelist mounts
#
# Tests the split volume-mounts that was extracted from launch-agent.sh.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source dependencies
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-volume-mounts"

source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/volume-mounts.sh"

#===============================================================================
# SETUP
#===============================================================================

setup_volume_vars() {
    VOLUME_MOUNTS=()
    SANDBOX_MODE="worktree"
    WORKTREE_PATH="/tmp/test-worktree"
    SANITIZED_GIT_PATH="/tmp/test-git-safe"
    OBJECTS_PATH="/tmp/test-objects"
    PROJECT_PATH="/tmp/test-project"
    UPPER_DIR="/tmp/test-upper"
    WORK_DIR="/tmp/test-work"
    AGENT_ID="test-001"
    DRY_RUN="true"
    KAPSIS_STATUS_DIR="/tmp/test-status"
    SPEC_FILE=""
    FILESYSTEM_INCLUDES=""
    SSH_VERIFY_HOSTS=""
    SNAPSHOT_DIR=""
    STAGED_CONFIGS=""
    SCRIPT_DIR="$KAPSIS_ROOT/scripts"
}

#===============================================================================
# DISPATCH TABLE TESTS
#===============================================================================

test_dispatch_table_has_worktree() {
    assert_equals "generate_volume_mounts_worktree" "${VOLUME_MOUNT_HANDLERS[worktree]}" \
        "Dispatch table should map worktree to handler"
}

test_dispatch_table_has_overlay() {
    assert_equals "generate_volume_mounts_overlay" "${VOLUME_MOUNT_HANDLERS[overlay]}" \
        "Dispatch table should map overlay to handler"
}

#===============================================================================
# generate_volume_mounts_worktree() TESTS
#===============================================================================

test_worktree_mounts_workspace() {
    setup_volume_vars
    SANDBOX_MODE="worktree"

    generate_volume_mounts_worktree

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${WORKTREE_PATH}:/workspace" "Should mount worktree as /workspace"
}

test_worktree_mounts_git_safe() {
    setup_volume_vars
    SANDBOX_MODE="worktree"

    generate_volume_mounts_worktree

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro" \
        "Should mount sanitized git read-only"
}

test_worktree_mounts_objects() {
    setup_volume_vars
    SANDBOX_MODE="worktree"

    generate_volume_mounts_worktree

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro" \
        "Should mount objects read-only"
}

#===============================================================================
# generate_volume_mounts_overlay() TESTS
#===============================================================================

test_overlay_mounts_workspace() {
    setup_volume_vars
    SANDBOX_MODE="overlay"

    generate_volume_mounts_overlay

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${PROJECT_PATH}:/workspace:O" \
        "Should mount project with overlay"
}

#===============================================================================
# add_common_volume_mounts() TESTS
#===============================================================================

test_common_mounts_status_dir() {
    setup_volume_vars
    VOLUME_MOUNTS=()

    add_common_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" ":/kapsis-status" "Should mount status directory"
}

test_common_mounts_maven_cache() {
    setup_volume_vars
    VOLUME_MOUNTS=()

    add_common_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "kapsis-${AGENT_ID}-m2" "Should mount Maven cache volume"
}

test_common_mounts_gradle_cache() {
    setup_volume_vars
    VOLUME_MOUNTS=()

    add_common_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "kapsis-${AGENT_ID}-gradle" "Should mount Gradle cache volume"
}

test_common_mounts_spec_file() {
    setup_volume_vars
    VOLUME_MOUNTS=()

    # Create a temporary spec file
    local tmpfile
    tmpfile=$(mktemp)
    echo "task spec" > "$tmpfile"
    SPEC_FILE="$tmpfile"

    add_common_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" ":/task-spec.md:ro" "Should mount spec file as read-only"

    rm -f "$tmpfile"
}

#===============================================================================
# generate_volume_mounts() DISPATCHER TESTS
#===============================================================================

test_dispatcher_worktree() {
    setup_volume_vars
    SANDBOX_MODE="worktree"

    generate_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${WORKTREE_PATH}:/workspace" "Dispatcher should call worktree handler"
}

test_dispatcher_overlay() {
    setup_volume_vars
    SANDBOX_MODE="overlay"

    generate_volume_mounts

    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${PROJECT_PATH}:/workspace:O" "Dispatcher should call overlay handler"
}

#===============================================================================
# _snapshot_file() TESTS
#===============================================================================

test_snapshot_dry_run() {
    setup_volume_vars
    DRY_RUN="true"

    local result
    result=$(_snapshot_file "/some/path" "relative/name")
    assert_equals "/some/path" "$result" "Dry run should return original path"
}

#===============================================================================
# GUARD TESTS
#===============================================================================

test_guard_prevents_double_source() {
    assert_equals "1" "$_KAPSIS_VOLUME_MOUNTS_LOADED" "Guard variable should be set to 1"
}

#===============================================================================
# RUN
#===============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo "TEST: Volume Mount Generation (scripts/lib/volume-mounts.sh)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Dispatch table tests
run_test test_dispatch_table_has_worktree
run_test test_dispatch_table_has_overlay

# Worktree mode tests
run_test test_worktree_mounts_workspace
run_test test_worktree_mounts_git_safe
run_test test_worktree_mounts_objects

# Overlay mode tests
run_test test_overlay_mounts_workspace

# Common mounts tests
run_test test_common_mounts_status_dir
run_test test_common_mounts_maven_cache
run_test test_common_mounts_gradle_cache
run_test test_common_mounts_spec_file

# Dispatcher tests
run_test test_dispatcher_worktree
run_test test_dispatcher_overlay

# Snapshot tests
run_test test_snapshot_dry_run

# Guard test
run_test test_guard_prevents_double_source

print_summary
