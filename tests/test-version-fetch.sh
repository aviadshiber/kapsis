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

test_python_json_parse_valid_version() {
    log_test "Testing Python JSON parsing with valid version"

    # Simulate GitHub API response
    local json_response='{"tag_name": "v1.2.3", "name": "Release 1.2.3"}'

    local version
    version=$(echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    assert_equals "1.2.3" "$version" "Should extract version without 'v' prefix"
}

test_python_json_parse_version_without_v_prefix() {
    log_test "Testing Python JSON parsing with version without 'v' prefix"

    # Some repos might not use 'v' prefix
    local json_response='{"tag_name": "2.0.0", "name": "Release 2.0.0"}'

    local version
    version=$(echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    assert_equals "2.0.0" "$version" "Should handle version without 'v' prefix"
}

test_python_json_parse_prerelease_version() {
    log_test "Testing Python JSON parsing with prerelease version"

    local json_response='{"tag_name": "v0.8.0-beta.1", "name": "Beta Release"}'

    local version
    version=$(echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    assert_equals "0.8.0-beta.1" "$version" "Should handle prerelease versions"
}

test_python_json_parse_complex_response() {
    log_test "Testing Python JSON parsing with full GitHub API response"

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
    version=$(echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    assert_equals "3.1.4" "$version" "Should extract version from full API response"
}

test_python_json_parse_invalid_json() {
    log_test "Testing Python JSON parsing with invalid JSON"

    local json_response='not valid json'
    local exit_code=0

    echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on invalid JSON"
}

test_python_json_parse_missing_tag_name() {
    log_test "Testing Python JSON parsing with missing tag_name field"

    local json_response='{"name": "Some Release", "draft": false}'
    local exit_code=0

    echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when tag_name is missing"
}

test_python_json_parse_empty_response() {
    log_test "Testing Python JSON parsing with empty response"

    local json_response=''
    local exit_code=0

    echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail on empty response"
}

test_python3_availability() {
    log_test "Testing Python3 is available"

    local exit_code=0
    python3 --version >/dev/null 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Python3 should be available"
}

test_version_used_in_url_construction() {
    log_test "Testing version can be used in URL construction"

    local json_response='{"tag_name": "v1.0.5"}'

    local version
    version=$(echo "$json_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

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

    # Run tests
    run_test test_python3_availability
    run_test test_python_json_parse_valid_version
    run_test test_python_json_parse_version_without_v_prefix
    run_test test_python_json_parse_prerelease_version
    run_test test_python_json_parse_complex_response
    run_test test_python_json_parse_invalid_json
    run_test test_python_json_parse_missing_tag_name
    run_test test_python_json_parse_empty_response
    run_test test_version_used_in_url_construction

    # Summary
    print_summary
}

main "$@"
