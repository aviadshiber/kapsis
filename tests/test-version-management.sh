#!/usr/bin/env bash
#===============================================================================
# Test: Version Management
#
# Tests version detection, upgrade checking, and command generation for the
# --version, --check-upgrade, --upgrade, and --downgrade flags.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the version library for direct function testing
source "$KAPSIS_ROOT/scripts/lib/version.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Check if we have network connectivity to GitHub
has_network() {
    curl -fsS --connect-timeout 5 "https://api.github.com" &>/dev/null
}

#===============================================================================
# UNIT TESTS: version.sh functions
#===============================================================================

test_detect_install_method() {
    log_test "Testing install method detection returns valid value"

    local method
    method=$(detect_install_method)

    # Should return one of the valid install methods
    case "$method" in
        "$INSTALL_HOMEBREW"|"$INSTALL_APT"|"$INSTALL_RPM"|"$INSTALL_SCRIPT"|"$INSTALL_GIT"|"$INSTALL_UNKNOWN")
            assert_true "true" "Install method '$method' is valid"
            ;;
        *)
            assert_true "false" "Install method '$method' should be one of: homebrew, apt, rpm, script, git, unknown"
            ;;
    esac
}

test_get_current_version_format() {
    log_test "Testing current version format"

    local version
    version=$(get_current_version)

    # Should match semver pattern (e.g., 0.16.0)
    assert_matches "$version" "^[0-9]+\.[0-9]+\.[0-9]+" "Version should be semver format"
}

test_get_latest_version_from_api() {
    log_test "Testing latest version fetch from GitHub API"

    # Skip if no network
    if ! has_network; then
        log_skip "No network connectivity"
        return 0
    fi

    local version
    version=$(get_latest_version)

    assert_not_equals "" "$version" "Should return a version"
    assert_not_contains "$version" "error" "Should not contain error"
    assert_matches "$version" "^[0-9]+\.[0-9]+\.[0-9]+" "Latest version should be semver format"
}

test_list_available_versions() {
    log_test "Testing list available versions"

    # Skip if no network
    if ! has_network; then
        log_skip "No network connectivity"
        return 0
    fi

    local versions
    versions=$(list_available_versions 5)

    assert_not_equals "" "$versions" "Should return versions"

    local count
    count=$(echo "$versions" | wc -l | tr -d ' ')
    assert_true "[[ $count -ge 1 ]]" "Should return at least one version"
}

test_compare_versions_equal() {
    log_test "Testing version comparison - equal"

    local result
    result=$(compare_versions "1.2.3" "1.2.3")

    assert_equals "0" "$result" "Equal versions should return 0"
}

test_compare_versions_less_than() {
    log_test "Testing version comparison - less than"

    local result
    result=$(compare_versions "1.2.3" "1.2.4")

    assert_equals "-1" "$result" "Older version should return -1"
}

test_compare_versions_greater_than() {
    log_test "Testing version comparison - greater than"

    local result
    result=$(compare_versions "1.3.0" "1.2.9")

    assert_equals "1" "$result" "Newer version should return 1"
}

test_compare_versions_major_difference() {
    log_test "Testing version comparison - major version difference"

    local result
    result=$(compare_versions "2.0.0" "1.9.9")

    assert_equals "1" "$result" "Major version bump should be greater"
}

test_compare_versions_with_v_prefix() {
    log_test "Testing version comparison with v prefix"

    local result
    result=$(compare_versions "v1.2.3" "1.2.3")

    assert_equals "0" "$result" "v prefix should be handled"
}

test_upgrade_command_generates_output() {
    log_test "Testing upgrade command generates valid output"

    # Test that get_upgrade_command generates non-empty output
    local cmd
    cmd=$(get_upgrade_command)

    # Should generate some command regardless of install method
    assert_not_equals "" "$cmd" "Should generate some command"
    # Should not contain error messages
    assert_not_contains "$cmd" "error:" "Should not contain errors"
}

test_upgrade_command_specific_version() {
    log_test "Testing upgrade to specific version generates output"

    local cmd
    cmd=$(get_upgrade_command "0.15.0")

    # Should generate some command with the version number
    assert_not_equals "" "$cmd" "Should generate some command"
    assert_contains "$cmd" "0.15.0" "Should contain target version"
}

#===============================================================================
# SECURITY TESTS: Input validation
#===============================================================================

test_validate_version_format_valid() {
    log_test "Testing version validation accepts valid versions"

    # Valid versions should pass
    assert_true "validate_version_format '1.2.3'" "Should accept 1.2.3"
    assert_true "validate_version_format 'v1.2.3'" "Should accept v1.2.3"
    assert_true "validate_version_format '0.16.0'" "Should accept 0.16.0"
    assert_true "validate_version_format '99.0.0'" "Should accept 99.0.0"
}

test_validate_version_format_rejects_injection() {
    log_test "Testing version validation rejects command injection attempts"

    # These should all be rejected to prevent command injection
    # SC2016: Single quotes intentional - we're testing literal injection strings
    local exit_code

    exit_code=0
    validate_version_format '1.0.0;whoami' 2>/dev/null || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should reject semicolon injection"

    exit_code=0
    # shellcheck disable=SC2016
    validate_version_format '1$(id)' 2>/dev/null || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should reject command substitution"

    exit_code=0
    # shellcheck disable=SC2016
    validate_version_format 'v$(whoami)' 2>/dev/null || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should reject v-prefixed injection"

    exit_code=0
    validate_version_format '1.0.0|cat /etc/passwd' 2>/dev/null || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should reject pipe injection"

    exit_code=0
    # shellcheck disable=SC2016
    validate_version_format '`whoami`' 2>/dev/null || exit_code=$?
    assert_not_equals 0 "$exit_code" "Should reject backtick injection"
}

test_upgrade_rejects_malicious_version() {
    log_test "Testing --upgrade rejects malicious version strings"

    local output
    local exit_code=0
    # shellcheck disable=SC2016
    output=$("$LAUNCH_SCRIPT" --upgrade '1$(id)' --dry-run 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on malicious input"
    assert_contains "$output" "Invalid version format" "Should show validation error"
}

#===============================================================================
# INTEGRATION TESTS: CLI flags
#===============================================================================

test_version_flag_output() {
    log_test "Testing --version flag output"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --version 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0"
    assert_contains "$output" "Kapsis" "Should show Kapsis name"
    assert_matches "$output" "[0-9]+\.[0-9]+\.[0-9]+" "Should show version number"
    assert_contains "$output" "Installation method" "Should show installation method"
}

test_version_short_flag() {
    log_test "Testing -V flag (short version)"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" -V 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0"
    assert_contains "$output" "Kapsis" "Should show Kapsis name"
}

test_check_upgrade_flag() {
    log_test "Testing --check-upgrade flag"

    # Skip if no network
    if ! has_network; then
        log_skip "No network connectivity"
        return 0
    fi

    local output
    output=$("$LAUNCH_SCRIPT" --check-upgrade 2>&1) || true

    assert_contains "$output" "Current version:" "Should show current version"
    assert_contains "$output" "Latest version:" "Should show latest version"
}

test_upgrade_dry_run() {
    log_test "Testing --upgrade --dry-run flag"

    # Use a specific future version to ensure dry-run output is always shown
    # (avoids "Already on version" when current equals latest)
    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --upgrade 99.0.0 --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0 on dry-run"
    assert_contains "$output" "[DRY-RUN]" "Should indicate dry run mode"
    assert_contains "$output" "Would execute" "Should show planned command"
}

test_upgrade_already_on_latest() {
    log_test "Testing --upgrade when already on target version"

    # Get current version and try to upgrade to the same version
    local current
    current=$(get_current_version)

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --upgrade "$current" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0"
    assert_contains "$output" "Already on version" "Should indicate already on target"
}

test_upgrade_with_v_prefix_dry_run() {
    log_test "Testing --upgrade vX.Y.Z --dry-run flag"

    # Use a version that's different from current
    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --upgrade v99.0.0 --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0 on dry-run"
    assert_contains "$output" "99.0.0" "Should handle v prefix (strip v)"
}

test_downgrade_without_version() {
    log_test "Testing --downgrade without version finds previous"

    # Skip if no network (needed to find previous version)
    if ! has_network; then
        log_skip "No network connectivity"
        return 0
    fi

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --downgrade --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with dry-run"
    assert_contains "$output" "previous version" "Should mention finding previous version"
    assert_contains "$output" "[DRY-RUN]" "Should show dry-run output"
}

test_downgrade_dry_run() {
    log_test "Testing --downgrade VERSION --dry-run flag"

    local output
    local exit_code=0
    # Use a very old version that's definitely older than current
    output=$("$LAUNCH_SCRIPT" --downgrade 0.1.0 --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit with 0 on dry-run"
    assert_contains "$output" "0.1.0" "Should reference target version"
}

test_downgrade_rejects_newer_version() {
    log_test "Testing --downgrade rejects newer version"

    local output
    local exit_code=0
    # Try to downgrade to a version that's newer than any possible current version
    output=$("$LAUNCH_SCRIPT" --downgrade 999.0.0 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when target is newer"
    assert_contains "$output" "newer" "Should explain target is newer"
}

test_downgrade_rejects_same_version() {
    log_test "Testing --downgrade rejects same version"

    local current
    current=$(get_current_version)

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" --downgrade "$current" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when target is same"
    assert_contains "$output" "same" "Should explain target is same version"
}

test_usage_shows_version_flags() {
    log_test "Testing usage shows version management flags"

    local output
    output=$("$LAUNCH_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "--version" "Usage should document --version"
    assert_contains "$output" "--check-upgrade" "Usage should document --check-upgrade"
    assert_contains "$output" "--upgrade" "Usage should document --upgrade"
    assert_contains "$output" "--downgrade" "Usage should document --downgrade"
    assert_contains "$output" "Global Options" "Usage should have Global Options section"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Version Management"

    # Unit tests
    run_test test_detect_install_method
    run_test test_get_current_version_format
    run_test test_get_latest_version_from_api
    run_test test_list_available_versions
    run_test test_compare_versions_equal
    run_test test_compare_versions_less_than
    run_test test_compare_versions_greater_than
    run_test test_compare_versions_major_difference
    run_test test_compare_versions_with_v_prefix
    run_test test_upgrade_command_generates_output
    run_test test_upgrade_command_specific_version

    # Security tests
    run_test test_validate_version_format_valid
    run_test test_validate_version_format_rejects_injection
    run_test test_upgrade_rejects_malicious_version

    # Integration tests
    run_test test_version_flag_output
    run_test test_version_short_flag
    run_test test_check_upgrade_flag
    run_test test_upgrade_dry_run
    run_test test_upgrade_already_on_latest
    run_test test_upgrade_with_v_prefix_dry_run
    run_test test_downgrade_without_version
    run_test test_downgrade_dry_run
    run_test test_downgrade_rejects_newer_version
    run_test test_downgrade_rejects_same_version
    run_test test_usage_shows_version_flags

    print_summary
}

main "$@"
