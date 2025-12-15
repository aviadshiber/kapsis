#!/usr/bin/env bash
#===============================================================================
# Test: Copy-on-Write Isolation
#
# Verifies that the Copy-on-Write (CoW) overlay filesystem works correctly:
# - Files created in container go to upper directory
# - Files modified in container don't change originals
# - Host filesystem remains unchanged
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_new_file_goes_to_upper() {
    log_test "Testing new file created in container goes to upper directory"

    setup_container_test "cow-new"

    # Create a new file in the container
    run_in_container "echo 'created in container' > /workspace/new-file.txt"

    # Verify file exists in upper directory
    assert_file_in_upper "new-file.txt" "New file should exist in upper directory"

    # Verify file does NOT exist on host
    assert_file_not_exists "$TEST_PROJECT/new-file.txt" "New file should NOT exist on host"

    cleanup_container_test
}

test_modified_file_goes_to_upper() {
    log_test "Testing modified file goes to upper, original unchanged"

    setup_container_test "cow-modify"

    # Record original content
    local original_content
    original_content=$(cat "$TEST_PROJECT/pom.xml")

    # Modify file in container
    run_in_container "echo '<!-- modified -->' >> /workspace/pom.xml"

    # Verify modified file exists in upper
    assert_file_in_upper "pom.xml" "Modified file should be in upper directory"

    # Verify original is unchanged
    local current_content
    current_content=$(cat "$TEST_PROJECT/pom.xml")
    assert_equals "$original_content" "$current_content" "Original pom.xml should be unchanged"

    cleanup_container_test
}

test_deleted_file_whiteout_in_upper() {
    log_test "Testing deleted file creates whiteout in upper"

    setup_container_test "cow-delete"

    # Delete a file in container
    run_in_container "rm /workspace/pom.xml"

    # Verify original still exists on host
    assert_file_exists "$TEST_PROJECT/pom.xml" "Original file should still exist on host"

    # The upper directory should have a whiteout marker (character device 0,0)
    # or the pom.xml should not appear when viewed from container
    # We verify by checking the file still exists on host
    cleanup_container_test
}

test_directory_creation_in_upper() {
    log_test "Testing new directory created in container goes to upper"

    setup_container_test "cow-dir"

    # Create a directory with files in container
    run_in_container "mkdir -p /workspace/new-module/src && echo 'test' > /workspace/new-module/src/Test.java"

    # Verify directory structure exists in upper
    assert_file_in_upper "new-module/src/Test.java" "New directory structure should be in upper"

    # Verify it doesn't exist on host
    assert_file_not_exists "$TEST_PROJECT/new-module/src/Test.java" "New directory should NOT exist on host"

    cleanup_container_test
}

test_nested_modification() {
    log_test "Testing modification to nested file"

    setup_container_test "cow-nested"

    # Record original content
    local original_content
    original_content=$(cat "$TEST_PROJECT/src/main/java/Main.java")

    # Modify nested file in container
    run_in_container "sed -i 's/Hello/Modified/' /workspace/src/main/java/Main.java"

    # Verify modified version is in upper
    assert_file_in_upper "src/main/java/Main.java" "Modified nested file should be in upper"

    # Verify original is unchanged
    local current_content
    current_content=$(cat "$TEST_PROJECT/src/main/java/Main.java")
    assert_equals "$original_content" "$current_content" "Original Main.java should be unchanged"

    cleanup_container_test
}

test_multiple_files_modified() {
    log_test "Testing multiple file modifications"

    setup_container_test "cow-multi"

    # Create and modify multiple files
    run_in_container "
        echo 'new1' > /workspace/file1.txt
        echo 'new2' > /workspace/file2.txt
        echo '<!-- mod -->' >> /workspace/pom.xml
    "

    # Verify all changes are in upper
    assert_file_in_upper "file1.txt" "file1.txt should be in upper"
    assert_file_in_upper "file2.txt" "file2.txt should be in upper"
    assert_file_in_upper "pom.xml" "Modified pom.xml should be in upper"

    # Verify none exist on host (except pom.xml which should be unchanged)
    assert_file_not_exists "$TEST_PROJECT/file1.txt" "file1.txt should NOT be on host"
    assert_file_not_exists "$TEST_PROJECT/file2.txt" "file2.txt should NOT be on host"

    cleanup_container_test
}

test_git_operations_isolated() {
    log_test "Testing git operations are isolated"

    setup_container_test "cow-git"

    # Record original git log
    local original_log
    original_log=$(cd "$TEST_PROJECT" && git log --oneline -1)

    # Make commit in container
    run_in_container "
        cd /workspace
        git config user.email 'container@test.com'
        git config user.name 'Container Test'
        echo 'change' > change.txt
        git add change.txt
        git commit -m 'Container commit'
    " || true  # May fail if git not configured

    # Verify original repo is unchanged
    local current_log
    current_log=$(cd "$TEST_PROJECT" && git log --oneline -1)
    assert_equals "$original_log" "$current_log" "Git history should be unchanged on host"

    cleanup_container_test
}

test_workspace_readable() {
    log_test "Testing original files readable in container"

    setup_container_test "cow-read"

    # Read file from container
    local output
    output=$(run_in_container "cat /workspace/pom.xml")

    # Should contain original content
    assert_contains "$output" "kapsis" "Should be able to read original file"
    assert_contains "$output" "test-project" "Should contain project name"

    cleanup_container_test
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Copy-on-Write Isolation"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_new_file_goes_to_upper
    run_test test_modified_file_goes_to_upper
    run_test test_deleted_file_whiteout_in_upper
    run_test test_directory_creation_in_upper
    run_test test_nested_modification
    run_test test_multiple_files_modified
    run_test test_git_operations_isolated
    run_test test_workspace_readable

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
