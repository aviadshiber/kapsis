#!/usr/bin/env bash
#===============================================================================
# Test: Input Validation
#
# Verifies that the launch script properly validates inputs and provides
# helpful error messages for invalid inputs.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_missing_agent_id() {
    log_test "Testing error when agent-id missing"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when agent-id missing"
    assert_contains "$output" "Usage" "Should show usage"
}

test_missing_project_path() {
    log_test "Testing error when project-path missing"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when project-path missing"
    assert_contains "$output" "Usage" "Should show usage"
}

test_nonexistent_project_path() {
    log_test "Testing error when project path doesn't exist"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "/nonexistent/path/to/project" --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when project doesn't exist"
    assert_contains "$output" "not exist" "Should mention path doesn't exist"
}

test_task_required_without_interactive() {
    log_test "Testing error when no task input provided"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail without task input"
    assert_contains "$output" "Task input required" "Should mention task is required"
}

test_interactive_mode_no_task_required() {
    log_test "Testing --interactive doesn't require task"

    local output
    local exit_code=0

    # With --interactive and --dry-run, should not error about missing task
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --interactive --dry-run 2>&1) || exit_code=$?

    # Should succeed (exit 0 from dry-run) or at least not fail on task validation
    assert_not_contains "$output" "Task input required" "Should not require task with --interactive"
}

test_nonexistent_spec_file() {
    log_test "Testing error when spec file doesn't exist"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --spec "/nonexistent/spec.md" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when spec file doesn't exist"
    assert_contains "$output" "not found" "Should mention spec file not found"
}

test_branch_requires_git_repo() {
    log_test "Testing --branch requires git repository"

    # Create non-git directory
    local non_git_dir
    non_git_dir=$(mktemp -d)

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$non_git_dir" --branch "test-branch" --task "test" 2>&1) || exit_code=$?

    rm -rf "$non_git_dir"

    assert_not_equals 0 "$exit_code" "Should fail when project is not git repo"
    assert_contains "$output" "git repository" "Should mention git repository required"
}

test_auto_branch_requires_git_repo() {
    log_test "Testing --auto-branch requires git repository"

    # Create non-git directory
    local non_git_dir
    non_git_dir=$(mktemp -d)

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$non_git_dir" --auto-branch --task "test" 2>&1) || exit_code=$?

    rm -rf "$non_git_dir"

    assert_not_equals 0 "$exit_code" "Should fail when project is not git repo"
    assert_contains "$output" "git repository" "Should mention git repository required"
}

test_unknown_option_error() {
    log_test "Testing error on unknown option"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --unknown-option --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on unknown option"
    assert_contains "$output" "Unknown option" "Should mention unknown option"
}

test_help_flag() {
    log_test "Testing --help shows usage"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" --help 2>&1) || exit_code=$?

    # Help exits with 1 but shows usage
    assert_contains "$output" "Usage" "Should show usage"
    assert_contains "$output" "Options" "Should show options section"
    assert_contains "$output" "Examples" "Should show examples"
}

test_short_help_flag() {
    log_test "Testing -h shows usage"

    local output
    output=$("$LAUNCH_SCRIPT" -h 2>&1) || true

    assert_contains "$output" "Usage" "Should show usage with -h"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Input Validation"

    # Setup
    setup_test_project

    # Run tests
    run_test test_missing_agent_id
    run_test test_missing_project_path
    run_test test_nonexistent_project_path
    run_test test_task_required_without_interactive
    run_test test_interactive_mode_no_task_required
    run_test test_nonexistent_spec_file
    run_test test_branch_requires_git_repo
    run_test test_auto_branch_requires_git_repo
    run_test test_unknown_option_error
    run_test test_help_flag
    run_test test_short_help_flag

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
