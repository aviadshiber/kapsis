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
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2030,SC2031  # Subshell variable modifications are intentional in mock tests
# shellcheck disable=SC2034  # Variables used by sourced functions inside subshells
# shellcheck disable=SC2329  # Functions defined in subshells are invoked by sourced scripts

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
    # Disable commit signing for tests (may be enabled in CI environment)
    git config commit.gpgsign false
    git config tag.gpgsign false

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
    if podman image exists "$KAPSIS_TEST_IMAGE" 2>/dev/null; then
        check_images "$KAPSIS_TEST_IMAGE" || result=$?
        assert_equals 0 "$result" "Existing image should pass"
    else
        skip_test "test_image_check_existing" "$KAPSIS_TEST_IMAGE not built"
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
    if ! podman image exists "$KAPSIS_TEST_IMAGE" 2>/dev/null; then
        skip_test "test_preflight_full_pass" "$KAPSIS_TEST_IMAGE not built"
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
    output=$(preflight_check "$test_repo" "feature/new-branch" "$spec_file" "$KAPSIS_TEST_IMAGE" "1" 2>&1) || result=$?

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
    output=$(preflight_check "$test_repo" "feature/conflict-branch" "" "$KAPSIS_TEST_IMAGE" "1" 2>&1) || result=$?

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
    output=$(preflight_check "$test_repo" "feature/my-branch" "" "$KAPSIS_TEST_IMAGE" "1" 2>&1) || true

    rm -rf "$test_repo"

    # Check for actionable guidance
    assert_contains "$output" "git checkout" "Should suggest git checkout"
    assert_contains "$output" "To fix" "Should provide fix instructions"
}

#===============================================================================
# TEST CASES: SSH Tunnel Connectivity (Issue #255)
#===============================================================================

test_check_podman_verifies_ssh_connectivity() {
    log_test "Testing check_podman verifies SSH connectivity on macOS"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "_podman_ssh_probe" \
        "check_podman should call _podman_ssh_probe"
    assert_contains "$content" "SSH tunnel is broken" \
        "check_podman should report SSH tunnel broken on probe failure"
    assert_contains "$content" "is_macos" \
        "SSH probe should be gated on macOS platform check"
}

test_ssh_probe_defined_in_compat() {
    log_test "Testing _podman_ssh_probe is defined in compat.sh"

    local compat_file="$KAPSIS_ROOT/scripts/lib/compat.sh"
    local content
    content=$(cat "$compat_file")

    assert_contains "$content" "_podman_ssh_probe()" \
        "_podman_ssh_probe function should be defined in compat.sh"
    assert_contains "$content" "podman info" \
        "_podman_ssh_probe should use 'podman info' as connectivity check"
    assert_contains "$content" "is_linux" \
        "_podman_ssh_probe should skip on Linux (native Podman)"
}

test_ssh_probe_constants_exist() {
    log_test "Testing SSH probe constants exist in constants.sh"

    local constants_file="$KAPSIS_ROOT/scripts/lib/constants.sh"
    local content
    content=$(cat "$constants_file")

    assert_contains "$content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_PROBE_TIMEOUT" \
        "SSH probe timeout constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_RETRIES" \
        "SSH recovery retries constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_DELAY" \
        "SSH recovery delay constant should exist"
}

test_backend_validate_has_ssh_recovery() {
    log_test "Testing backend_validate includes SSH recovery logic"

    local backend_file="$KAPSIS_ROOT/scripts/backends/podman.sh"
    local content
    content=$(cat "$backend_file")

    assert_contains "$content" "_podman_ssh_probe" \
        "backend_validate should call _podman_ssh_probe"
    assert_contains "$content" "SSH tunnel is stale" \
        "backend_validate should detect stale SSH tunnel"
    assert_contains "$content" "podman machine stop" \
        "backend_validate should attempt stop as part of recovery"
    assert_contains "$content" "SSH tunnel recovered" \
        "backend_validate should report successful recovery"
    assert_contains "$content" "SSH tunnel is broken" \
        "backend_validate should report if recovery fails"
}

test_check_podman_fails_on_stale_ssh() {
    log_test "Testing check_podman fails when SSH tunnel is stale"

    local mock_dir
    mock_dir=$(mktemp -d)

    # Mock podman: machine inspect returns "running" but podman info fails
    cat > "$mock_dir/podman" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "machine" ]]; then
    if [[ "${2:-}" == "inspect" ]]; then
        for arg in "$@"; do
            if [[ "$arg" == *"{{.State}}"* ]]; then
                echo "running"
                exit 0
            fi
        done
        echo "{}"
        exit 0
    fi
    # machine stop / machine start — succeed silently
    exit 0
fi
if [[ "${1:-}" == "info" ]]; then
    # Simulate stale SSH: podman info fails
    exit 125
fi
exit 0
MOCK
    chmod +x "$mock_dir/podman"

    # Mock timeout to just pass through
    cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift  # skip timeout value
exec "$@"
MOCK
    chmod +x "$mock_dir/timeout"

    # Run in a fresh bash process to avoid readonly variable inheritance
    local test_script="$mock_dir/run-test.sh"
    cat > "$test_script" <<TESTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$mock_dir:\$PATH"
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
# Force macOS detection for CI environments
_KAPSIS_OS="Darwin"
source "$PREFLIGHT_SCRIPT"
_PREFLIGHT_ERRORS=0
_PREFLIGHT_WARNINGS=0
KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT=2
KAPSIS_PREFLIGHT_SSH_RECOVERY_RETRIES=1
KAPSIS_PREFLIGHT_SSH_RECOVERY_DELAY=0
check_podman
TESTEOF
    chmod +x "$test_script"

    local output
    local result=0
    output=$(bash "$test_script" 2>&1) || result=$?

    rm -rf "$mock_dir"

    assert_not_equals 0 "$result" "check_podman should fail when SSH tunnel is stale"
    assert_contains "$output" "SSH tunnel is broken" "Should report broken SSH tunnel"
}

test_check_podman_passes_on_healthy_ssh() {
    log_test "Testing check_podman passes when SSH tunnel is healthy"

    local mock_dir
    mock_dir=$(mktemp -d)

    # Mock podman: both inspect and info succeed
    cat > "$mock_dir/podman" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "machine" ]] && [[ "${2:-}" == "inspect" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *"{{.State}}"* ]]; then
            echo "running"
            exit 0
        fi
    done
    echo "{}"
    exit 0
fi
if [[ "${1:-}" == "info" ]]; then
    echo "host:"
    exit 0
fi
exit 0
MOCK
    chmod +x "$mock_dir/podman"

    cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
    chmod +x "$mock_dir/timeout"

    # Run in a fresh bash process to avoid readonly variable inheritance
    local test_script="$mock_dir/run-test.sh"
    cat > "$test_script" <<TESTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$mock_dir:\$PATH"
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test"
source "$KAPSIS_ROOT/scripts/lib/compat.sh"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
# Force macOS detection for CI environments
_KAPSIS_OS="Darwin"
source "$PREFLIGHT_SCRIPT"
_PREFLIGHT_ERRORS=0
_PREFLIGHT_WARNINGS=0
KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT=2
check_podman
TESTEOF
    chmod +x "$test_script"

    local output
    local result=0
    output=$(bash "$test_script" 2>&1) || result=$?

    rm -rf "$mock_dir"

    assert_equals 0 "$result" "check_podman should pass when SSH tunnel is healthy"
    assert_contains "$output" "SSH tunnel is functional" "Should report functional SSH tunnel"
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

    # SSH connectivity tests (Issue #255)
    run_test test_check_podman_verifies_ssh_connectivity
    run_test test_ssh_probe_defined_in_compat
    run_test test_ssh_probe_constants_exist
    run_test test_backend_validate_has_ssh_recovery
    run_test test_check_podman_fails_on_stale_ssh
    run_test test_check_podman_passes_on_healthy_ssh

    # Summary
    print_summary
}

main "$@"
