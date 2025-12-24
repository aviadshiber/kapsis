#!/usr/bin/env bash
#===============================================================================
# Test: Worktree Isolation
#
# Verifies that the git worktree sandbox mode works correctly:
# - Worktrees are created on host
# - Sanitized git prevents hook attacks
# - Objects are read-only
# - Changes stay in worktree
# - Host project unchanged
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_worktree_created_on_host() {
    log_test "Testing worktree is created on host"

    setup_worktree_test "wt-create"

    # Worktree should exist
    assert_worktree_exists "$WORKTREE_TEST_PATH" "Worktree should be created"

    # Should be a valid git worktree (has .git file, not directory)
    if [[ -f "$WORKTREE_TEST_PATH/.git" ]]; then
        log_pass "Worktree has .git file (not directory)"
    else
        log_fail "Worktree should have .git file"
        cleanup_worktree_test
        return 1
    fi

    cleanup_worktree_test
}

test_sanitized_git_has_empty_hooks() {
    log_test "Testing sanitized git has empty hooks directory"

    setup_worktree_test "wt-hooks"

    # Hooks directory should be empty
    assert_sanitized_git_secure "$WORKTREE_SANITIZED_GIT" "Sanitized git should be secure"

    # Verify hooks dir exists but is empty
    local hooks_dir="$WORKTREE_SANITIZED_GIT/hooks"
    if [[ -d "$hooks_dir" ]]; then
        local file_count
        file_count=$(find "$hooks_dir" -type f | wc -l | tr -d ' ')
        assert_equals "0" "$file_count" "Hooks directory should be empty"
    else
        log_fail "Hooks directory should exist"
        cleanup_worktree_test
        return 1
    fi

    cleanup_worktree_test
}

test_sanitized_git_has_minimal_config() {
    log_test "Testing sanitized git has minimal config"

    setup_worktree_test "wt-config"

    local config_file="$WORKTREE_SANITIZED_GIT/config"

    # Config should exist
    assert_file_exists "$config_file" "Config file should exist"

    local config_content
    config_content=$(cat "$config_file")

    # Config should NOT have dangerous credential storage that could leak secrets
    # (credential.helper = store/cache with plaintext files)
    # Note: Some CI environments have credential helpers (e.g., manager-core) which are OK
    if [[ "$config_content" == *"credential.helper = store"* ]] || \
       [[ "$config_content" == *"credentialStore"* ]]; then
        log_fail "Config should not have plaintext credential storage"
        cleanup_worktree_test
        return 1
    fi

    # Config should have safe directory
    assert_contains "$config_content" "safe" "Config should have safe directory setting"

    cleanup_worktree_test
}

test_objects_mounted_readonly() {
    log_test "Testing objects are mounted read-only in container"

    setup_worktree_test "wt-objects-ro"

    # Try to modify objects directory in container
    local output
    local exit_code=0
    output=$(run_in_worktree_container "touch /workspace/.git-objects/test-file 2>&1") || exit_code=$?

    cleanup_worktree_test

    # Should fail (read-only)
    if [[ $exit_code -ne 0 ]] || [[ "$output" == *"Read-only"* ]] || [[ "$output" == *"Permission denied"* ]]; then
        return 0
    else
        log_fail "Objects directory should be read-only"
        log_info "Exit code: $exit_code"
        log_info "Output: $output"
        return 1
    fi
}

test_container_can_read_files() {
    log_test "Testing container can read files from worktree"

    setup_worktree_test "wt-read"

    # Read file from container
    local output
    output=$(run_in_worktree_container "cat /workspace/pom.xml")

    cleanup_worktree_test

    # Should contain original content
    assert_contains "$output" "kapsis" "Should be able to read original file"
    assert_contains "$output" "test-project" "Should contain project name"
}

test_container_can_write_files() {
    log_test "Testing container can write files to worktree"

    setup_worktree_test "wt-write"

    # Write file in container
    run_in_worktree_container "echo 'test content' > /workspace/test-write.txt"

    # File should exist in worktree on host
    assert_file_exists "$WORKTREE_TEST_PATH/test-write.txt" "Written file should exist in worktree"

    # Content should match
    local content
    content=$(cat "$WORKTREE_TEST_PATH/test-write.txt")
    assert_equals "test content" "$content" "Content should match"

    cleanup_worktree_test
}

test_changes_stay_in_worktree() {
    log_test "Testing changes stay in worktree (not main project)"

    setup_worktree_test "wt-isolation"

    # Write file in container
    run_in_worktree_container "echo 'isolated change' > /workspace/isolated-file.txt"

    # File should exist in worktree
    assert_file_exists "$WORKTREE_TEST_PATH/isolated-file.txt" "File should be in worktree"

    # File should NOT exist in main project
    assert_file_not_exists "$TEST_PROJECT/isolated-file.txt" "File should NOT be in main project"

    cleanup_worktree_test
}

test_host_project_unchanged() {
    log_test "Testing host project is unchanged after container operations"

    # Record original pom.xml content
    local original_content
    original_content=$(cat "$TEST_PROJECT/pom.xml")

    setup_worktree_test "wt-host-unchanged"

    # Modify pom.xml in container
    run_in_worktree_container "echo '<!-- modified -->' >> /workspace/pom.xml"

    cleanup_worktree_test

    # Host pom.xml should be unchanged
    local current_content
    current_content=$(cat "$TEST_PROJECT/pom.xml")

    assert_equals "$original_content" "$current_content" "Host pom.xml should be unchanged"
}

test_git_operations_work_in_container() {
    log_test "Testing git operations work in container"

    setup_worktree_test "wt-git-ops"

    # Run git status in container
    local output
    output=$(run_in_worktree_container "cd /workspace && GIT_DIR=/workspace/.git-safe GIT_WORK_TREE=/workspace git status")

    cleanup_worktree_test

    # Should show clean working tree or show branch
    if [[ "$output" == *"nothing to commit"* ]] || [[ "$output" == *"On branch"* ]] || [[ "$output" == *"feature/"* ]]; then
        return 0
    else
        log_fail "Git operations should work"
        log_info "Output: $output"
        return 1
    fi
}

test_no_hooks_execute() {
    log_test "Testing no hooks execute in container"

    setup_worktree_test "wt-no-hooks"

    # Try to create a hook in the sanitized git directory
    # This should fail because .git-safe is mounted read-only
    local output
    output=$(run_in_worktree_container "
        # Try to create a pre-commit hook (should fail - read-only)
        echo '#!/bin/bash' > /workspace/.git-safe/hooks/test-hook 2>&1 || true

        # Check if the hook file was actually created (it shouldn't be)
        if [[ -f /workspace/.git-safe/hooks/test-hook ]]; then
            echo 'HOOK_CREATED=true'
        else
            echo 'HOOK_CREATED=false'
        fi
    ") || true

    cleanup_worktree_test

    # Hook creation should have failed (read-only mount)
    if [[ "$output" == *"HOOK_CREATED=true"* ]]; then
        log_fail "Hooks should not be creatable in read-only .git-safe"
        return 1
    fi

    return 0
}

test_worktree_cleanup() {
    log_test "Testing worktree cleanup"

    setup_worktree_test "wt-cleanup"

    local worktree_path="$WORKTREE_TEST_PATH"
    local sanitized_git="$WORKTREE_SANITIZED_GIT"

    # Worktree should exist before cleanup
    assert_worktree_exists "$worktree_path" "Worktree should exist before cleanup"

    cleanup_worktree_test

    # Worktree should not exist after cleanup
    if [[ -d "$worktree_path" ]]; then
        log_fail "Worktree should be removed after cleanup"
        return 1
    fi

    # Sanitized git should not exist after cleanup
    if [[ -d "$sanitized_git" ]]; then
        log_fail "Sanitized git should be removed after cleanup"
        return 1
    fi

    return 0
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Worktree Isolation"

    # Worktree tests require Linux - sanitized git has known issues on macOS
    # See tests/README.md for platform notes
    if [[ "$(uname -s)" == "Darwin" ]]; then
        log_skip "Worktree tests require Linux (macOS has known sanitized git issues)"
        exit 0
    fi

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping worktree tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_worktree_created_on_host
    run_test test_sanitized_git_has_empty_hooks
    run_test test_sanitized_git_has_minimal_config
    run_test test_objects_mounted_readonly
    run_test test_container_can_read_files
    run_test test_container_can_write_files
    run_test test_changes_stay_in_worktree
    run_test test_host_project_unchanged
    run_test test_git_operations_work_in_container
    run_test test_no_hooks_execute
    run_test test_worktree_cleanup

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
