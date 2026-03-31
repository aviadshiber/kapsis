#!/usr/bin/env bash
#===============================================================================
# Test: Ephemeral Artifact Filtering (Issue #227)
#
# Verifies that constants for ephemeral artifact filtering and push timeouts
# are properly defined and have valid values.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Import constants and post-container-git
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/post-container-git.sh"

# Global variables
TEST_REPO=""

#===============================================================================
# SETUP AND TEARDOWN
#===============================================================================

setup_test_repo() {
    local test_name="$1"
    TEST_REPO=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-test-ephem-${test_name}-XXXXXX")
    cd "$TEST_REPO"
    git init --quiet
    git config user.email "test@kapsis.local"
    git config user.name "Kapsis Test"
    git config commit.gpgsign false
    echo "# Test Project" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
    echo "$TEST_REPO"
}

cleanup_test_repo() {
    [[ -n "$TEST_REPO" && -d "$TEST_REPO" ]] && rm -rf "$TEST_REPO"
    TEST_REPO=""
}

#===============================================================================
# TEST CASES
#===============================================================================

test_push_timeout_constant_exists() {
    log_test "KAPSIS_DEFAULT_PUSH_TIMEOUT constant exists and is numeric"
    # shellcheck disable=SC2016  # Single-quoted strings passed to assert_true are eval'd, not expanded here
    assert_true '[[ -n "${KAPSIS_DEFAULT_PUSH_TIMEOUT:-}" ]]' \
        "KAPSIS_DEFAULT_PUSH_TIMEOUT should be defined"
    # shellcheck disable=SC2016  # Single-quoted strings passed to assert_true are eval'd, not expanded here
    assert_true '[[ "${KAPSIS_DEFAULT_PUSH_TIMEOUT}" =~ ^[0-9]+$ ]]' \
        "KAPSIS_DEFAULT_PUSH_TIMEOUT should be numeric"
}

test_ephemeral_patterns_constant_exists() {
    log_test "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS constant exists and is non-empty"
    # shellcheck disable=SC2016  # Single-quoted strings passed to assert_true are eval'd, not expanded here
    assert_true '[[ -n "${KAPSIS_DEFAULT_EPHEMERAL_PATTERNS:-}" ]]' \
        "KAPSIS_DEFAULT_EPHEMERAL_PATTERNS should be defined"
}

test_pycache_files_are_unstaged() {
    log_test "__pycache__ files are unstaged by validate_staged_files"
    setup_test_repo "pycache"
    cd "$TEST_REPO"

    mkdir -p "src/__pycache__"
    echo "bytecode" > "src/__pycache__/module.cpython-311.pyc"
    git add "src/__pycache__/module.cpython-311.pyc"

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "__pycache__" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail "__pycache__ file should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "__pycache__" || echo "")
    assert_equals "" "$staged_after" "__pycache__ files should be unstaged after validation"

    cleanup_test_repo
}

test_pytest_cache_files_are_unstaged() {
    log_test ".pytest_cache files are unstaged by validate_staged_files"
    setup_test_repo "pytest-cache"
    cd "$TEST_REPO"

    mkdir -p ".pytest_cache/v/cache"
    echo "{}" > ".pytest_cache/v/cache/lastfailed"
    git add ".pytest_cache/"

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "\.pytest_cache" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail ".pytest_cache file should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "\.pytest_cache" || echo "")
    assert_equals "" "$staged_after" ".pytest_cache files should be unstaged after validation"

    cleanup_test_repo
}

test_coverage_file_is_unstaged() {
    log_test ".coverage file is unstaged by validate_staged_files"
    setup_test_repo "coverage"
    cd "$TEST_REPO"

    echo "coverage data" > ".coverage"
    git add ".coverage"

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "\.coverage" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail ".coverage file should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "\.coverage" || echo "")
    assert_equals "" "$staged_after" ".coverage should be unstaged after validation"

    cleanup_test_repo
}

test_legitimate_python_preserved() {
    log_test "Legitimate .py source files are NOT filtered by validate_staged_files"
    setup_test_repo "legit-py"
    cd "$TEST_REPO"

    mkdir -p src
    echo "def main(): pass" > "src/main.py"
    git add "src/main.py"

    local staged_before
    staged_before=$(git diff --cached --name-only | grep "src/main.py" || echo "")
    if [[ -z "$staged_before" ]]; then
        log_fail "src/main.py should be staged before validation"
        cleanup_test_repo
        return 1
    fi

    validate_staged_files "$TEST_REPO"

    local staged_after
    staged_after=$(git diff --cached --name-only | grep "src/main.py" || echo "")
    if [[ -z "$staged_after" ]]; then
        log_fail "src/main.py should still be staged after validation"
        cleanup_test_repo
        return 1
    fi

    cleanup_test_repo
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Ephemeral Artifact Filtering (Issue #227)"

    run_test test_push_timeout_constant_exists
    run_test test_ephemeral_patterns_constant_exists
    run_test test_pycache_files_are_unstaged
    run_test test_pytest_cache_files_are_unstaged
    run_test test_coverage_file_is_unstaged
    run_test test_legitimate_python_preserved

    print_summary
    return "$TESTS_FAILED"
}

main "$@"
