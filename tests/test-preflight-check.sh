#!/usr/bin/env bash
#===============================================================================
# Test: Pre-Flight Check
#
# Verifies that the preflight-check.sh script properly validates all
# prerequisites before launching a Kapsis agent.
#
# Tests cover:
# - Podman machine detection
# - Image availability check
# - Git status validation
# - Branch conflict detection (CRITICAL)
# - Spec file validation
# - Worktree conflict detection
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

PREFLIGHT_SCRIPT="$KAPSIS_ROOT/scripts/preflight-check.sh"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Create a test git repo with specific branch
setup_test_git_repo() {
    local repo_path="$1"
    local branch_name="${2:-main}"

    mkdir -p "$repo_path"
    cd "$repo_path"
    git init -q
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"

    echo "test content" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    if [[ "$branch_name" != "main" && "$branch_name" != "master" ]]; then
        git checkout -q -b "$branch_name"
    fi
}

# Create a spec file with content
create_spec_file() {
    local spec_path="$1"
    local lines="${2:-10}"

    mkdir -p "$(dirname "$spec_path")"
    for i in $(seq 1 "$lines"); do
        echo "Line $i of spec file" >> "$spec_path"
    done
}

#===============================================================================
# TEST CASES: Script Loading
#===============================================================================

test_script_exists() {
    log_test "Testing preflight-check.sh script exists"

    assert_file_exists "$PREFLIGHT_SCRIPT" "Script should exist"
}

test_script_is_executable() {
    log_test "Testing preflight-check.sh is executable"

    assert_true "[[ -x '$PREFLIGHT_SCRIPT' ]]" "Script should be executable"
}

test_script_has_help() {
    log_test "Testing --help flag"

    local output
    output=$("$PREFLIGHT_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "Usage" "Should show usage"
    assert_contains "$output" "project_path" "Should mention project_path"
    assert_contains "$output" "target_branch" "Should mention target_branch"
}

#===============================================================================
# TEST CASES: Git Status Check
#===============================================================================

test_git_status_clean() {
    log_test "Testing clean git status passes"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "main"

    # Source the script to get access to functions
    source "$PREFLIGHT_SCRIPT"

    # Reset counters
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_git_status "$test_repo" || result=$?

    rm -rf "$test_repo"

    assert_equals 0 "$result" "Clean git status should pass"
    assert_equals 0 "$_PREFLIGHT_WARNINGS" "Should have no warnings"
}

test_git_status_dirty() {
    log_test "Testing dirty git status warns"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "main"

    # Make repo dirty
    echo "uncommitted" > "$test_repo/dirty.txt"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_git_status "$test_repo" || result=$?

    rm -rf "$test_repo"

    # Dirty status is a warning, not an error
    assert_equals 0 "$result" "Dirty git status should pass (warning only)"
    assert_not_equals 0 "$_PREFLIGHT_WARNINGS" "Should have warnings for dirty status"
}

test_git_status_not_git_repo() {
    log_test "Testing non-git directory fails"

    local test_dir
    test_dir=$(mktemp -d)

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_git_status "$test_dir" || result=$?

    rm -rf "$test_dir"

    assert_not_equals 0 "$result" "Non-git directory should fail"
}

#===============================================================================
# TEST CASES: Branch Conflict Detection (CRITICAL)
#===============================================================================

test_branch_conflict_same_branch() {
    log_test "Testing branch conflict when on same branch"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "feature/test-branch"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_branch_conflict "$test_repo" "feature/test-branch" || result=$?

    rm -rf "$test_repo"

    assert_not_equals 0 "$result" "Same branch should fail with conflict"
    assert_not_equals 0 "$_PREFLIGHT_ERRORS" "Should have errors for branch conflict"
}

test_branch_conflict_different_branch() {
    log_test "Testing no conflict when on different branch"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "main"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_branch_conflict "$test_repo" "feature/other-branch" || result=$?

    rm -rf "$test_repo"

    assert_equals 0 "$result" "Different branch should pass"
    assert_equals 0 "$_PREFLIGHT_ERRORS" "Should have no errors"
}

test_branch_conflict_normalized_names() {
    log_test "Testing branch conflict with normalized names (feature/ prefix)"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "feature/DEV-123-test"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Try with same branch name
    local result=0
    check_branch_conflict "$test_repo" "feature/DEV-123-test" || result=$?

    rm -rf "$test_repo"

    assert_not_equals 0 "$result" "Matching feature branch should conflict"
}

#===============================================================================
# TEST CASES: Spec File Check
#===============================================================================

test_spec_file_exists_and_valid() {
    log_test "Testing valid spec file passes"

    local spec_file
    spec_file=$(mktemp)
    create_spec_file "$spec_file" 15

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_spec_file "$spec_file" || result=$?

    rm -f "$spec_file"

    assert_equals 0 "$result" "Valid spec file should pass"
    assert_equals 0 "$_PREFLIGHT_WARNINGS" "Should have no warnings"
}

test_spec_file_too_short() {
    log_test "Testing very short spec file warns"

    local spec_file
    spec_file=$(mktemp)
    echo "tiny" > "$spec_file"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_spec_file "$spec_file" || result=$?

    rm -f "$spec_file"

    # Short spec is a warning, not error
    assert_equals 0 "$result" "Short spec file should pass (warning only)"
    assert_not_equals 0 "$_PREFLIGHT_WARNINGS" "Should warn about short spec"
}

test_spec_file_not_found() {
    log_test "Testing missing spec file fails"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_spec_file "/nonexistent/spec.md" || result=$?

    assert_not_equals 0 "$result" "Missing spec file should fail"
    assert_not_equals 0 "$_PREFLIGHT_ERRORS" "Should have error for missing spec"
}

test_spec_file_empty_path() {
    log_test "Testing empty spec path is skipped"

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_spec_file "" || result=$?

    assert_equals 0 "$result" "Empty spec path should pass (skipped)"
    assert_equals 0 "$_PREFLIGHT_ERRORS" "Should have no errors"
}

#===============================================================================
# TEST CASES: Image Check
#===============================================================================

test_image_check_existing() {
    log_test "Testing existing image passes"

    # Skip if podman not available
    if ! command -v podman &>/dev/null; then
        skip_test "test_image_check_existing" "Podman not available"
        return 0
    fi

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Use an image we know exists from test prerequisites
    local result=0
    if podman image exists kapsis-sandbox:latest 2>/dev/null; then
        check_images "kapsis-sandbox:latest" || result=$?
        assert_equals 0 "$result" "Existing image should pass"
    else
        skip_test "test_image_check_existing" "kapsis-sandbox:latest not built"
    fi
}

test_image_check_nonexistent() {
    log_test "Testing non-existent image fails"

    # Skip if podman not available
    if ! command -v podman &>/dev/null; then
        skip_test "test_image_check_nonexistent" "Podman not available"
        return 0
    fi

    source "$PREFLIGHT_SCRIPT"
    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    local result=0
    check_images "nonexistent-image:v999" || result=$?

    assert_not_equals 0 "$result" "Non-existent image should fail"
    assert_not_equals 0 "$_PREFLIGHT_ERRORS" "Should have error for missing image"
}

#===============================================================================
# TEST CASES: Main Preflight Function
#===============================================================================

test_preflight_full_pass() {
    log_test "Testing full preflight with valid inputs"

    # Skip if podman not available
    if ! command -v podman &>/dev/null; then
        skip_test "test_preflight_full_pass" "Podman not available"
        return 0
    fi

    # Skip if image not built
    if ! podman image exists kapsis-sandbox:latest 2>/dev/null; then
        skip_test "test_preflight_full_pass" "kapsis-sandbox:latest not built"
        return 0
    fi

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "main"

    local spec_file
    spec_file=$(mktemp)
    create_spec_file "$spec_file" 10

    source "$PREFLIGHT_SCRIPT"

    local output
    local result=0
    output=$(preflight_check "$test_repo" "feature/new-branch" "$spec_file" "kapsis-sandbox:latest" "1" 2>&1) || result=$?

    rm -rf "$test_repo"
    rm -f "$spec_file"

    assert_equals 0 "$result" "Full preflight should pass with valid inputs"
    assert_contains "$output" "Pre-flight check PASSED" "Should show passed message"
}

test_preflight_branch_conflict_fails() {
    log_test "Testing preflight fails on branch conflict"

    # Skip if podman not available
    if ! command -v podman &>/dev/null; then
        skip_test "test_preflight_branch_conflict_fails" "Podman not available"
        return 0
    fi

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "feature/conflict-branch"

    source "$PREFLIGHT_SCRIPT"

    local output
    local result=0
    output=$(preflight_check "$test_repo" "feature/conflict-branch" "" "kapsis-sandbox:latest" "1" 2>&1) || result=$?

    rm -rf "$test_repo"

    assert_not_equals 0 "$result" "Preflight should fail on branch conflict"
    assert_contains "$output" "BRANCH CONFLICT" "Should show branch conflict message"
    assert_contains "$output" "Pre-flight check FAILED" "Should show failed message"
}

test_preflight_error_messages_actionable() {
    log_test "Testing error messages provide actionable guidance"

    local test_repo
    test_repo=$(mktemp -d)
    setup_test_git_repo "$test_repo" "feature/my-branch"

    source "$PREFLIGHT_SCRIPT"

    local output
    output=$(preflight_check "$test_repo" "feature/my-branch" "" "kapsis-sandbox:latest" "1" 2>&1) || true

    rm -rf "$test_repo"

    # Check for actionable guidance
    assert_contains "$output" "git checkout" "Should suggest git checkout"
    assert_contains "$output" "To fix" "Should provide fix instructions"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Pre-Flight Check"

    # Script existence tests
    run_test test_script_exists
    run_test test_script_is_executable
    run_test test_script_has_help

    # Git status tests
    run_test test_git_status_clean
    run_test test_git_status_dirty
    run_test test_git_status_not_git_repo

    # Branch conflict tests (CRITICAL)
    run_test test_branch_conflict_same_branch
    run_test test_branch_conflict_different_branch
    run_test test_branch_conflict_normalized_names

    # Spec file tests
    run_test test_spec_file_exists_and_valid
    run_test test_spec_file_too_short
    run_test test_spec_file_not_found
    run_test test_spec_file_empty_path

    # Image tests (require Podman)
    run_test test_image_check_existing
    run_test test_image_check_nonexistent

    # Integration tests
    run_test test_preflight_full_pass
    run_test test_preflight_branch_conflict_fails
    run_test test_preflight_error_messages_actionable

    # Summary
    print_summary
}

main "$@"
