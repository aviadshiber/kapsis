#!/usr/bin/env bash
#===============================================================================
# Test: Version Fetching
#
# Verifies that the version fetching command used in install docs works
# correctly with various GitHub API responses.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_jq_availability() {
    log_test "Testing jq is available"

    local exit_code=0
    jq --version >/dev/null 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "jq should be available"
}

test_jq_parse_valid_version() {
    log_test "Testing jq parsing with valid version"

    # Simulate GitHub API response
    local json_response='{"tag_name": "v1.2.3", "name": "Release 1.2.3"}'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    assert_equals "1.2.3" "$version" "Should extract version without 'v' prefix"
}

test_jq_parse_version_without_v_prefix() {
    log_test "Testing jq parsing with version without 'v' prefix"

    # Some repos might not use 'v' prefix
    local json_response='{"tag_name": "2.0.0", "name": "Release 2.0.0"}'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    assert_equals "2.0.0" "$version" "Should handle version without 'v' prefix"
}

test_jq_parse_prerelease_version() {
    log_test "Testing jq parsing with prerelease version"

    local json_response='{"tag_name": "v0.8.0-beta.1", "name": "Beta Release"}'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    assert_equals "0.8.0-beta.1" "$version" "Should handle prerelease versions"
}

test_jq_parse_complex_response() {
    log_test "Testing jq parsing with full GitHub API response"

    # More realistic GitHub API response with multiple fields
    local json_response='{
        "url": "https://api.github.com/repos/owner/repo/releases/12345",
        "tag_name": "v3.1.4",
        "name": "Version 3.1.4",
        "draft": false,
        "prerelease": false,
        "created_at": "2025-01-15T10:00:00Z",
        "published_at": "2025-01-15T10:30:00Z"
    }'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    assert_equals "3.1.4" "$version" "Should extract version from full API response"
}

test_jq_parse_invalid_json() {
    log_test "Testing jq parsing with invalid JSON"

    local json_response='not valid json'
    local exit_code=0

    echo "$json_response" | jq -r '.tag_name | ltrimstr("v")' 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on invalid JSON"
}

test_jq_parse_missing_tag_name() {
    log_test "Testing jq parsing with missing tag_name field"

    local json_response='{"name": "Some Release", "draft": false}'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    assert_equals "null" "$version" "Should return null when tag_name is missing"
}

test_jq_parse_empty_response() {
    log_test "Testing jq parsing with empty response"

    local json_response=''

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")' 2>/dev/null || echo "ERROR")

    # jq returns empty string or "null" for empty input - both are invalid versions
    # The key point is it doesn't return a valid semver version
    assert_true "[[ -z '$version' || '$version' == 'null' || '$version' == 'ERROR' ]]" "Should not return a valid version on empty response"
}

test_version_used_in_url_construction() {
    log_test "Testing version can be used in URL construction"

    local json_response='{"tag_name": "v1.0.5"}'

    local version
    version=$(echo "$json_response" | jq -r '.tag_name | ltrimstr("v")')

    # Construct URLs as they would be in the install docs
    local deb_url="https://github.com/aviadshiber/kapsis/releases/download/v${version}/kapsis_${version}-1_all.deb"
    local rpm_url="https://github.com/aviadshiber/kapsis/releases/download/v${version}/kapsis-${version}-1.noarch.rpm"

    assert_contains "$deb_url" "v1.0.5" "DEB URL should contain version with v prefix"
    assert_contains "$deb_url" "kapsis_1.0.5-1_all.deb" "DEB URL should have correct filename"
    assert_contains "$rpm_url" "kapsis-1.0.5-1.noarch.rpm" "RPM URL should have correct filename"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Version Fetching"

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_skip "jq is not installed - skipping tests"
        echo ""
        echo "To run these tests, install jq:"
        echo "  Debian/Ubuntu: sudo apt install jq"
        echo "  Fedora/RHEL:   sudo dnf install jq"
        echo "  macOS:         brew install jq"
        exit 0
    fi

    # Run tests
    run_test test_jq_availability
    run_test test_jq_parse_valid_version
    run_test test_jq_parse_version_without_v_prefix
    run_test test_jq_parse_prerelease_version
    run_test test_jq_parse_complex_response
    run_test test_jq_parse_invalid_json
    run_test test_jq_parse_missing_tag_name
    run_test test_jq_parse_empty_response
    run_test test_version_used_in_url_construction

    # Summary
    print_summary
}

main "$@"
