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

# Helper: create a mock podman script for SSH tests
# Args: $1=mock_dir, $2=info_behavior ("fail"|"succeed"|"fail_then_succeed")
_create_ssh_mock_podman() {
    local mock_dir="$1"
    local info_behavior="${2:-fail}"

    # State file for fail_then_succeed mode
    local call_count_file="$mock_dir/.podman_info_calls"
    echo "0" > "$call_count_file"

    cat > "$mock_dir/podman" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "machine" ]]; then
    if [[ "\${2:-}" == "inspect" ]]; then
        for arg in "\$@"; do
            if [[ "\$arg" == *"{{.State}}"* ]]; then
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
if [[ "\${1:-}" == "info" ]]; then
    case "$info_behavior" in
        fail)
            exit 125
            ;;
        succeed)
            echo "host:"
            exit 0
            ;;
        fail_then_succeed)
            count=\$(cat "$call_count_file")
            count=\$((count + 1))
            echo "\$count" > "$call_count_file"
            if [[ \$count -le 1 ]]; then
                exit 125  # first call fails
            else
                echo "host:"
                exit 0    # subsequent calls succeed
            fi
            ;;
    esac
fi
exit 0
MOCK
    chmod +x "$mock_dir/podman"

    # Mock timeout to pass through (strips timeout arg)
    cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
    chmod +x "$mock_dir/timeout"
}

# Helper: create a test script that sources libraries and runs check_podman
# Args: $1=mock_dir, $2...=extra lines to add before check_podman
_create_ssh_test_script() {
    local mock_dir="$1"
    shift
    local extra_lines=("$@")

    local test_script="$mock_dir/run-test.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$mock_dir:\$PATH\""
        echo "source \"$KAPSIS_ROOT/scripts/lib/logging.sh\""
        echo 'log_init "test"'
        echo "source \"$KAPSIS_ROOT/scripts/lib/compat.sh\""
        echo "source \"$KAPSIS_ROOT/scripts/lib/constants.sh\""
        echo '_KAPSIS_OS="Darwin"'
        echo "source \"$PREFLIGHT_SCRIPT\""
        echo '_PREFLIGHT_ERRORS=0'
        echo '_PREFLIGHT_WARNINGS=0'
        echo 'KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT=2'
        for line in "${extra_lines[@]}"; do
            echo "$line"
        done
        echo 'check_podman'
        # shellcheck disable=SC2016
        echo 'echo "ERRORS=$_PREFLIGHT_ERRORS"'
    } > "$test_script"
    chmod +x "$test_script"
}

# Smoke test: key integration points exist in source
test_ssh_probe_source_integration() {
    log_test "Testing SSH probe integration points exist in source"

    local compat_content preflight_content backend_content constants_content
    compat_content=$(cat "$KAPSIS_ROOT/scripts/lib/compat.sh")
    preflight_content=$(cat "$PREFLIGHT_SCRIPT")
    backend_content=$(cat "$KAPSIS_ROOT/scripts/backends/podman.sh")
    constants_content=$(cat "$KAPSIS_ROOT/scripts/lib/constants.sh")

    # Probe and recovery functions defined in compat.sh
    assert_contains "$compat_content" "_podman_ssh_probe()" \
        "_podman_ssh_probe should be defined in compat.sh"
    assert_contains "$compat_content" "_recover_podman_ssh_tunnel()" \
        "_recover_podman_ssh_tunnel should be defined in compat.sh"
    assert_contains "$compat_content" "podman info" \
        "Probe should use 'podman info' as connectivity check"

    # Callers use shared recovery function
    assert_contains "$preflight_content" "_recover_podman_ssh_tunnel" \
        "preflight should call shared recovery function"
    assert_contains "$backend_content" "_recover_podman_ssh_tunnel" \
        "backend should call shared recovery function"

    # Constants defined
    assert_contains "$constants_content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_PROBE_TIMEOUT=10" \
        "SSH probe timeout constant should exist with default 10"
    assert_contains "$constants_content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_RETRIES=2" \
        "SSH recovery retries constant should exist with default 2"
    assert_contains "$constants_content" "KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_DELAY=3" \
        "SSH recovery delay constant should exist with default 3"

    # Backend skips if probe already passed
    assert_contains "$backend_content" "KAPSIS_SSH_PROBE_PASSED" \
        "backend should check KAPSIS_SSH_PROBE_PASSED to avoid double probing"
}

# Behavioral: check_podman fails when SSH tunnel is permanently stale
test_check_podman_fails_on_stale_ssh() {
    log_test "Testing check_podman fails when SSH tunnel is stale"

    local mock_dir
    mock_dir=$(mktemp -d)
    _create_ssh_mock_podman "$mock_dir" "fail"
    _create_ssh_test_script "$mock_dir" \
        'KAPSIS_PREFLIGHT_SSH_RECOVERY_RETRIES=1' \
        'KAPSIS_PREFLIGHT_SSH_RECOVERY_DELAY=0'

    local output result=0
    output=$(bash "$mock_dir/run-test.sh" 2>&1) || result=$?
    rm -rf "$mock_dir"

    assert_not_equals 0 "$result" "check_podman should fail when SSH tunnel is stale"
    assert_contains "$output" "SSH tunnel is broken" "Should report broken SSH tunnel"
    assert_not_contains "$output" "SSH tunnel is functional" "Should NOT report functional"
}

# Behavioral: check_podman passes when SSH tunnel is healthy
test_check_podman_passes_on_healthy_ssh() {
    log_test "Testing check_podman passes when SSH tunnel is healthy"

    local mock_dir
    mock_dir=$(mktemp -d)
    _create_ssh_mock_podman "$mock_dir" "succeed"
    _create_ssh_test_script "$mock_dir"

    local output result=0
    output=$(bash "$mock_dir/run-test.sh" 2>&1) || result=$?
    rm -rf "$mock_dir"

    assert_equals 0 "$result" "check_podman should pass when SSH tunnel is healthy"
    assert_contains "$output" "SSH tunnel is functional" "Should report functional SSH tunnel"
    assert_contains "$output" "ERRORS=0" "Should have zero preflight errors"
}

# Behavioral: recovery succeeds on retry after initial failure
test_check_podman_recovers_on_retry() {
    log_test "Testing check_podman recovers when SSH tunnel heals after restart"

    local mock_dir
    mock_dir=$(mktemp -d)
    _create_ssh_mock_podman "$mock_dir" "fail_then_succeed"
    _create_ssh_test_script "$mock_dir" \
        'KAPSIS_PREFLIGHT_SSH_RECOVERY_RETRIES=2' \
        'KAPSIS_PREFLIGHT_SSH_RECOVERY_DELAY=0'

    local output result=0
    output=$(bash "$mock_dir/run-test.sh" 2>&1) || result=$?
    rm -rf "$mock_dir"

    assert_equals 0 "$result" "check_podman should succeed after recovery"
    assert_contains "$output" "SSH tunnel is functional" "Should report functional after recovery"
    assert_not_contains "$output" "SSH tunnel is broken" "Should NOT report broken"
    assert_contains "$output" "ERRORS=0" "Should have zero preflight errors"
}

# Behavioral: SSH probe is skipped on Linux
test_check_podman_skips_ssh_on_linux() {
    log_test "Testing check_podman skips SSH probe on Linux"

    local mock_dir
    mock_dir=$(mktemp -d)
    # Use fail behavior — but on Linux, probe should never run
    _create_ssh_mock_podman "$mock_dir" "fail"

    local test_script="$mock_dir/run-test.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$mock_dir:\$PATH\""
        echo "source \"$KAPSIS_ROOT/scripts/lib/logging.sh\""
        echo 'log_init "test"'
        echo "source \"$KAPSIS_ROOT/scripts/lib/compat.sh\""
        echo "source \"$KAPSIS_ROOT/scripts/lib/constants.sh\""
        echo '_KAPSIS_OS="Linux"'
        echo "source \"$PREFLIGHT_SCRIPT\""
        echo '_PREFLIGHT_ERRORS=0'
        echo '_PREFLIGHT_WARNINGS=0'
        echo 'KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT=2'
        echo 'check_podman'
    } > "$test_script"
    chmod +x "$test_script"

    local output result=0
    output=$(bash "$test_script" 2>&1) || result=$?
    rm -rf "$mock_dir"

    assert_equals 0 "$result" "check_podman should pass on Linux (no SSH probe)"
    assert_not_contains "$output" "SSH tunnel" "Should not mention SSH tunnel on Linux"
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
    run_test test_ssh_probe_source_integration
    run_test test_check_podman_fails_on_stale_ssh
    run_test test_check_podman_passes_on_healthy_ssh
    run_test test_check_podman_recovers_on_retry
    run_test test_check_podman_skips_ssh_on_linux

    # Summary
    print_summary
}

main "$@"
