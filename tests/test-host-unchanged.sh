#!/usr/bin/env bash
#===============================================================================
# Test: Host Unchanged
#
# Verifies that the host filesystem remains completely unchanged after
# container operations. This is the core isolation guarantee.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# SETUP
#===============================================================================

# Records checksums of all files in test project
record_file_checksums() {
    find "$TEST_PROJECT" -type f -exec md5 {} \; 2>/dev/null | sort > "$TEST_PROJECT/../checksums-before.txt"
}

# Compares current checksums with recorded ones
verify_file_checksums() {
    find "$TEST_PROJECT" -type f -exec md5 {} \; 2>/dev/null | sort > "$TEST_PROJECT/../checksums-after.txt"
    diff -q "$TEST_PROJECT/../checksums-before.txt" "$TEST_PROJECT/../checksums-after.txt" >/dev/null 2>&1
}

#===============================================================================
# TEST CASES
#===============================================================================

test_no_files_modified() {
    log_test "Testing no host files are modified"

    setup_container_test "host-nomod"
    record_file_checksums

    # Run container that modifies files
    run_in_container "
        sed -i 's/Hello/Changed/' /workspace/src/main/java/Main.java
        echo '<!-- modified -->' >> /workspace/pom.xml
    "

    # Verify no changes on host
    if verify_file_checksums; then
        cleanup_container_test
        return 0
    else
        log_fail "Host files were modified!"
        cleanup_container_test
        return 1
    fi
}

test_no_files_created() {
    log_test "Testing no files created on host"

    setup_container_test "host-nocreate"

    # Count files before
    local count_before
    count_before=$(find "$TEST_PROJECT" -type f | wc -l)

    # Create files in container
    run_in_container "
        touch /workspace/newfile1.txt
        touch /workspace/newfile2.txt
        mkdir -p /workspace/newdir
        touch /workspace/newdir/nested.txt
    "

    # Count files after
    local count_after
    count_after=$(find "$TEST_PROJECT" -type f | wc -l)

    cleanup_container_test

    assert_equals "$count_before" "$count_after" "File count should remain the same"
}

test_no_files_deleted() {
    log_test "Testing no files deleted from host"

    setup_container_test "host-nodelete"

    # Count files before
    local count_before
    count_before=$(find "$TEST_PROJECT" -type f | wc -l)

    # Delete files in container
    run_in_container "
        rm /workspace/pom.xml
        rm -rf /workspace/src
    "

    # Count files after
    local count_after
    count_after=$(find "$TEST_PROJECT" -type f | wc -l)

    cleanup_container_test

    assert_equals "$count_before" "$count_after" "File count should remain the same"
}

test_git_status_clean() {
    log_test "Testing git status remains clean on host"

    setup_container_test "host-git"

    # Make changes in container
    run_in_container "
        echo 'change' >> /workspace/pom.xml
        echo 'new file' > /workspace/newfile.txt
    "

    # Check git status on host
    cd "$TEST_PROJECT"
    local git_status
    git_status=$(git status --porcelain)
    cd - > /dev/null

    cleanup_container_test

    # Git status should be empty (no changes)
    if [[ -z "$git_status" ]]; then
        return 0
    else
        log_fail "Git status shows changes: $git_status"
        return 1
    fi
}

test_permissions_unchanged() {
    log_test "Testing file permissions unchanged on host"

    setup_container_test "host-perms"

    # Record permissions before
    local perms_before
    perms_before=$(ls -la "$TEST_PROJECT/pom.xml" | awk '{print $1}')

    # Change permissions in container
    run_in_container "chmod 777 /workspace/pom.xml" || true

    # Check permissions after
    local perms_after
    perms_after=$(ls -la "$TEST_PROJECT/pom.xml" | awk '{print $1}')

    cleanup_container_test

    assert_equals "$perms_before" "$perms_after" "Permissions should be unchanged"
}

test_timestamps_unchanged() {
    log_test "Testing file timestamps unchanged on host"

    setup_container_test "host-time"

    # Record modification time before
    local mtime_before
    mtime_before=$(stat -f "%m" "$TEST_PROJECT/pom.xml" 2>/dev/null || stat -c "%Y" "$TEST_PROJECT/pom.xml")

    # Modify file in container
    sleep 2  # Ensure time would change
    run_in_container "echo 'change' >> /workspace/pom.xml"

    # Check modification time after
    local mtime_after
    mtime_after=$(stat -f "%m" "$TEST_PROJECT/pom.xml" 2>/dev/null || stat -c "%Y" "$TEST_PROJECT/pom.xml")

    cleanup_container_test

    assert_equals "$mtime_before" "$mtime_after" "Modification time should be unchanged"
}

test_symlinks_unchanged() {
    log_test "Testing symlinks not created on host"

    setup_container_test "host-symlink"

    # Create symlink in container
    run_in_container "ln -s /workspace/pom.xml /workspace/pom-link.xml" || true

    # Check no symlink on host
    if [[ -L "$TEST_PROJECT/pom-link.xml" ]]; then
        cleanup_container_test
        log_fail "Symlink was created on host"
        return 1
    fi

    cleanup_container_test
    return 0
}

test_file_content_identical() {
    log_test "Testing specific file content unchanged"

    setup_container_test "host-content"

    # Read content before
    local content_before
    content_before=$(cat "$TEST_PROJECT/src/main/java/Main.java")

    # Heavily modify in container
    run_in_container "
        echo 'completely different content' > /workspace/src/main/java/Main.java
    "

    # Read content after
    local content_after
    content_after=$(cat "$TEST_PROJECT/src/main/java/Main.java")

    cleanup_container_test

    assert_equals "$content_before" "$content_after" "File content should be identical"
}

test_multiple_container_runs() {
    log_test "Testing host unchanged after multiple container runs"

    # Record state before
    record_file_checksums
    local count_before
    count_before=$(find "$TEST_PROJECT" -type f | wc -l)

    # Run multiple containers with modifications
    for i in 1 2 3; do
        setup_container_test "host-multi-$i"
        run_in_container "
            echo 'run $i' > /workspace/run-$i.txt
            sed -i 's/Hello/Run$i/' /workspace/src/main/java/Main.java
        " || true
        cleanup_container_test
    done

    # Verify unchanged
    local count_after
    count_after=$(find "$TEST_PROJECT" -type f | wc -l)

    assert_equals "$count_before" "$count_after" "File count unchanged after multiple runs"

    if verify_file_checksums; then
        return 0
    else
        log_fail "Files were modified after multiple runs"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Host Filesystem Unchanged"

    # Check prerequisites
    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_no_files_modified
    run_test test_no_files_created
    run_test test_no_files_deleted
    run_test test_git_status_clean
    run_test test_permissions_unchanged
    run_test test_timestamps_unchanged
    run_test test_symlinks_unchanged
    run_test test_file_content_identical
    run_test test_multiple_container_runs

    # Cleanup
    cleanup_test_project
    rm -f "$TEST_PROJECT/../checksums-before.txt" "$TEST_PROJECT/../checksums-after.txt" 2>/dev/null || true

    # Summary
    print_summary
}

main "$@"
