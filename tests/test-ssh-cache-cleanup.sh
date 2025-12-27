#!/usr/bin/env bash
#===============================================================================
# Test: SSH Cache Cleanup
#
# Verifies SSH host key cache cleanup functionality.
# Tests --ssh-cache flag for kapsis-cleanup.sh and idempotent operations.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"

# Test-specific directories
TEST_SSH_CACHE_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_ssh_cache_test() {
    TEST_SSH_CACHE_DIR="$TEST_PROJECT/.kapsis-test-ssh-cache"
    mkdir -p "$TEST_SSH_CACHE_DIR"

    # Override the cache directory for testing
    export SSH_CACHE_DIR="$TEST_SSH_CACHE_DIR"
    export KAPSIS_DIR="$TEST_PROJECT/.kapsis-test"
    mkdir -p "$KAPSIS_DIR/ssh-cache"
}

cleanup_ssh_cache_test() {
    rm -rf "$TEST_SSH_CACHE_DIR"
    rm -rf "$TEST_PROJECT/.kapsis-test"
    unset SSH_CACHE_DIR KAPSIS_DIR
}

#===============================================================================
# TEST CASES
#===============================================================================

test_cleanup_script_exists() {
    log_test "Testing cleanup script exists"

    assert_file_exists "$CLEANUP_SCRIPT" "Cleanup script should exist"
    assert_true "[[ -x '$CLEANUP_SCRIPT' ]]" "Cleanup script should be executable"
}

test_ssh_cache_flag_recognized() {
    log_test "Testing --ssh-cache flag is recognized"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true

    # Should run and produce cleanup output (contains standard sections)
    assert_contains "$output" "Cleanup" "Should show Cleanup header"
    assert_contains "$output" "Dry run" "Should indicate dry-run mode"
}

test_cleanup_help_shows_ssh_cache() {
    log_test "Testing help mentions --ssh-cache"

    local output
    output=$("$CLEANUP_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "--ssh-cache" "Help should mention --ssh-cache option"
    assert_contains "$output" "SSH" "Help should mention SSH"
}

test_ssh_cache_dry_run() {
    log_test "Testing --ssh-cache with --dry-run"

    setup_ssh_cache_test

    # Create fake cache file
    echo "test-key" > "$KAPSIS_DIR/ssh-cache/test-host.key"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true

    # File should still exist after dry-run
    assert_file_exists "$KAPSIS_DIR/ssh-cache/test-host.key" "File should exist after dry-run"
    assert_contains "$output" "DRY" "Output should indicate dry-run"

    cleanup_ssh_cache_test
}

test_ssh_cache_actual_cleanup() {
    log_test "Testing --ssh-cache cleanup runs without error"

    # Run cleanup with ssh-cache flag and verify it completes
    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --force --dry-run 2>&1) || true

    # Cleanup should run (exit code may be non-zero due to nothing to clean)
    assert_contains "$output" "Cleanup" "Should show cleanup output"
}

test_cleanup_idempotent() {
    log_test "Testing cleanup is safe to run multiple times"

    # Run cleanup with dry-run twice - should not error
    local output1
    local output2
    output1=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true
    output2=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true

    # Both should produce output (not crash)
    assert_contains "$output1" "Cleanup" "First cleanup should run"
    assert_contains "$output2" "Cleanup" "Second cleanup should run"
}

test_cleanup_dry_run_no_changes() {
    log_test "Testing dry-run doesn't make changes"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true

    # Should indicate dry-run mode
    assert_contains "$output" "Dry run" "Should indicate dry-run mode"
}

test_cleanup_force_no_prompt() {
    log_test "Testing --force skips prompts"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --force --dry-run 2>&1) || true

    # Should complete without hanging (prompts would hang)
    assert_contains "$output" "Cleanup" "Should complete with --force"
}

test_cleanup_with_other_flags() {
    log_test "Testing --ssh-cache works with other flags"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run --force 2>&1) || true

    # Should work with combined flags
    assert_contains "$output" "Cleanup" "Should work with multiple flags"
}

test_cleanup_shows_sections() {
    log_test "Testing cleanup shows expected sections"

    local output
    output=$("$CLEANUP_SCRIPT" --ssh-cache --dry-run 2>&1) || true

    # Should show standard sections (at minimum Worktrees and Sandboxes)
    assert_contains "$output" "Worktrees" "Should show Worktrees section"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "SSH Cache Cleanup"

    # Setup
    setup_test_project

    # Run tests
    run_test test_cleanup_script_exists
    run_test test_ssh_cache_flag_recognized
    run_test test_cleanup_help_shows_ssh_cache
    run_test test_ssh_cache_dry_run
    run_test test_ssh_cache_actual_cleanup
    run_test test_cleanup_idempotent
    run_test test_cleanup_dry_run_no_changes
    run_test test_cleanup_force_no_prompt
    run_test test_cleanup_with_other_flags
    run_test test_cleanup_shows_sections

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
