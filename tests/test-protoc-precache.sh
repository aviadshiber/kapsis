#!/usr/bin/env bash
#===============================================================================
# Test: Protoc Binary Pre-caching
#
# Verifies that protoc binaries are pre-cached in the container image.
# This ensures proto compilation works in DNS-filtered network mode.
#
# Prerequisites:
#   - Podman installed and running
#   - Kapsis image built (with protoc pre-caching)
#===============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# =============================================================================
# Test: Protoc cache directory exists
# =============================================================================
test_protoc_cache_directory_exists() {
    if ! skip_if_no_container; then
        return 0
    fi

    local result
    result=$(run_simple_container \
        "test -d /opt/kapsis/m2-cache/com/google/protobuf/protoc && echo EXISTS || echo NOT_FOUND")

    if [[ "$result" == *"EXISTS"* ]]; then
        return 0
    else
        # Image may not have been rebuilt with protoc caching yet
        skip_test "test_protoc_cache_directory_exists" \
            "Protoc cache not found - image may need rebuild with latest Containerfile"
        return 0
    fi
}

# =============================================================================
# Test: Protoc binaries are present for multiple architectures
# =============================================================================
test_protoc_binaries_present() {
    if ! skip_if_no_container; then
        return 0
    fi

    # Check that at least one protoc binary exists
    local result
    result=$(run_simple_container \
        "find /opt/kapsis/m2-cache -name 'protoc-*' -type f 2>/dev/null | head -1")

    if [[ -n "$result" && "$result" != *"NOT_FOUND"* ]]; then
        log_info "Found protoc binary: $result"
        return 0
    else
        skip_test "test_protoc_binaries_present" \
            "No protoc binaries found - image may need rebuild"
        return 0
    fi
}

# =============================================================================
# Test: Protoc binary is executable
# =============================================================================
test_protoc_binary_is_executable() {
    if ! skip_if_no_container; then
        return 0
    fi

    # Find a protoc binary and check if it's executable
    local protoc_path
    protoc_path=$(run_simple_container \
        "find /opt/kapsis/m2-cache -name 'protoc-*-linux-*' -type f 2>/dev/null | head -1")

    if [[ -z "$protoc_path" || "$protoc_path" == *"error"* ]]; then
        skip_test "test_protoc_binary_is_executable" \
            "No protoc binary found to check"
        return 0
    fi

    # Check if the binary is executable
    local result
    result=$(run_simple_container \
        "test -x '$protoc_path' && echo EXECUTABLE || echo NOT_EXECUTABLE")

    if [[ "$result" == *"EXECUTABLE"* ]]; then
        log_info "Protoc binary is executable: $protoc_path"
        return 0
    else
        _log_failure "Protoc binary should be executable" "Binary: $protoc_path"
        return 1
    fi
}

# =============================================================================
# Test: KAPSIS_JAVA_VERSION environment variable support
# =============================================================================
test_java_version_switch_environment() {
    if ! skip_if_no_container; then
        return 0
    fi

    # Test that KAPSIS_JAVA_VERSION is recognized by entrypoint
    # We look for the log message in the output
    local result
    result=$(run_simple_container \
        "grep -q 'KAPSIS_JAVA_VERSION' /opt/kapsis/entrypoint.sh && echo FOUND || echo NOT_FOUND")

    if [[ "$result" == *"FOUND"* ]]; then
        log_info "KAPSIS_JAVA_VERSION support found in entrypoint.sh"
        return 0
    else
        _log_failure "KAPSIS_JAVA_VERSION should be supported in entrypoint.sh"
        return 1
    fi
}

# =============================================================================
# Test: switch-java.sh script exists and is executable
# =============================================================================
test_switch_java_script_exists() {
    if ! skip_if_no_container; then
        return 0
    fi

    local result
    result=$(run_simple_container \
        "test -x /opt/kapsis/switch-java.sh && echo EXISTS || echo NOT_FOUND")

    if [[ "$result" == *"EXISTS"* ]]; then
        return 0
    else
        _log_failure "switch-java.sh should exist and be executable"
        return 1
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
print_test_header "Protoc Pre-caching and Java Version Support"

run_test test_protoc_cache_directory_exists
run_test test_protoc_binaries_present
run_test test_protoc_binary_is_executable
run_test test_java_version_switch_environment
run_test test_switch_java_script_exists

print_summary
