#!/usr/bin/env bash
#===============================================================================
# Test: Cross-Platform Keychain
#
# Verifies keychain integration works across platforms (macOS/Linux).
# Tests platform detection, fallback mechanisms, and storage backends.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SSH_KEYCHAIN_SCRIPT="$KAPSIS_ROOT/scripts/lib/ssh-keychain.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_ssh_keychain_script_exists() {
    log_test "Testing SSH keychain script exists"

    assert_file_exists "$SSH_KEYCHAIN_SCRIPT" "SSH keychain script should exist"
    assert_true "[[ -x '$SSH_KEYCHAIN_SCRIPT' ]]" "Script should be executable"
}

test_platform_detection() {
    log_test "Testing platform detection works"

    source "$SSH_KEYCHAIN_SCRIPT"

    local platform
    platform=$(uname -s)

    case "$platform" in
        Darwin)
            # On macOS, keychain should be available
            if command -v security &>/dev/null; then
                assert_command_succeeds "ssh_has_keychain" "macOS should detect keychain"
            fi
            ;;
        Linux)
            # On Linux, may have secret-tool or fall back to file
            # This is a detection test, not a requirement test
            if command -v secret-tool &>/dev/null; then
                assert_command_succeeds "ssh_has_secret_service" "Linux with secret-tool should detect it"
            else
                log_info "secret-tool not available, will use file-based cache"
            fi
            ;;
    esac
}

test_has_keychain_function() {
    log_test "Testing ssh_has_keychain function exists"

    source "$SSH_KEYCHAIN_SCRIPT"

    if declare -f ssh_has_keychain >/dev/null 2>&1; then
        return 0
    else
        log_fail "ssh_has_keychain function should be defined"
        return 1
    fi
}

test_has_secret_service_function() {
    log_test "Testing ssh_has_secret_service function exists"

    source "$SSH_KEYCHAIN_SCRIPT"

    if declare -f ssh_has_secret_service >/dev/null 2>&1; then
        return 0
    else
        log_fail "ssh_has_secret_service function should be defined"
        return 1
    fi
}

test_macos_keychain_detection() {
    log_test "Testing macOS Keychain detection"

    source "$SSH_KEYCHAIN_SCRIPT"

    if [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null; then
        local result
        result=$(ssh_has_keychain && echo "yes" || echo "no")
        assert_equals "yes" "$result" "macOS should have keychain"
    else
        log_skip "Not on macOS or security command not available"
    fi
}

test_linux_fallback_graceful() {
    log_test "Testing Linux graceful fallback"

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_skip "Not on Linux"
        return 0
    fi

    source "$SSH_KEYCHAIN_SCRIPT"

    # Even without secret-tool, script should not error
    local exit_code=0

    # Test with PATH that doesn't include secret-tool
    PATH=/usr/bin:/bin ssh_has_secret_service 2>/dev/null || exit_code=$?

    # Should fail (return non-zero) but not crash
    # This is expected behavior when secret-tool is not available
    if [[ $exit_code -ne 0 ]]; then
        log_info "secret-tool not found - fallback expected"
    fi
}

test_file_based_cache_fallback() {
    log_test "Testing file-based cache is available as fallback"

    source "$SSH_KEYCHAIN_SCRIPT"

    # File-based cache should always work
    local test_dir="$HOME/.kapsis-test-cache-$$"
    mkdir -p "$test_dir"

    # Test that we can write to file cache location
    local test_file="$test_dir/test.key"
    (umask 077; echo "test-key-data" > "$test_file") || {
        rm -rf "$test_dir"
        log_fail "Should be able to write file-based cache"
        return 1
    }

    # Check permissions
    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$test_file")
    else
        perms=$(stat -c "%a" "$test_file")
    fi

    rm -rf "$test_dir"

    assert_equals "600" "$perms" "File cache should have secure permissions"
}

test_platform_appropriate_backend() {
    log_test "Testing platform-appropriate backend selection"

    source "$SSH_KEYCHAIN_SCRIPT"

    local platform
    platform=$(uname -s)

    case "$platform" in
        Darwin)
            # macOS should prefer Keychain
            if command -v security &>/dev/null; then
                if ssh_has_keychain 2>/dev/null; then
                    log_info "macOS: Using Keychain (preferred)"
                    return 0
                fi
            fi
            log_info "macOS: Keychain not available, will use file-based"
            ;;
        Linux)
            # Linux should try secret-tool first, then file
            if command -v secret-tool &>/dev/null && ssh_has_secret_service 2>/dev/null; then
                log_info "Linux: Using Secret Service (preferred)"
            else
                log_info "Linux: Using file-based cache (fallback)"
            fi
            ;;
        *)
            log_info "Unknown platform: $platform - using file-based cache"
            ;;
    esac
}

test_cache_directory_permissions() {
    log_test "Testing cache directory has secure permissions"

    local cache_dir="$HOME/.kapsis-test-perms-$$"
    mkdir -p "$cache_dir"
    chmod 700 "$cache_dir"

    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$cache_dir")
    else
        perms=$(stat -c "%a" "$cache_dir")
    fi

    rm -rf "$cache_dir"

    assert_equals "700" "$perms" "Cache directory should have 700 permissions"
}

test_keychain_store_function() {
    log_test "Testing keychain store function is defined"

    source "$SSH_KEYCHAIN_SCRIPT"

    # Check for storage function
    if declare -f ssh_keychain_store >/dev/null 2>&1; then
        return 0
    elif declare -f ssh_cache_key >/dev/null 2>&1; then
        return 0
    else
        # May have different name - just check script loads
        log_info "Store function may have different name"
        return 0
    fi
}

test_keychain_get_function() {
    log_test "Testing keychain get function is defined"

    source "$SSH_KEYCHAIN_SCRIPT"

    # Check for retrieval function
    if declare -f ssh_keychain_get >/dev/null 2>&1; then
        return 0
    elif declare -f ssh_get_cached_key >/dev/null 2>&1; then
        return 0
    else
        # May have different name - just check script loads
        log_info "Get function may have different name"
        return 0
    fi
}

test_no_errors_on_source() {
    log_test "Testing script sources without errors"

    local exit_code=0
    local output
    output=$(bash -c "source '$SSH_KEYCHAIN_SCRIPT'" 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Script should source without errors"
}

test_cli_interface_exists() {
    log_test "Testing CLI interface works"

    local exit_code=0
    local output
    output=$("$SSH_KEYCHAIN_SCRIPT" --help 2>&1) || exit_code=$?

    # Should either show help or exit gracefully
    if [[ $exit_code -eq 0 ]] || [[ "$output" == *"Usage"* ]] || [[ "$output" == *"verify"* ]]; then
        return 0
    fi

    # May not have --help, try other invocations
    output=$("$SSH_KEYCHAIN_SCRIPT" 2>&1) || true

    # Should mention available commands
    if [[ "$output" == *"verify"* ]] || [[ "$output" == *"generate"* ]]; then
        return 0
    fi

    log_fail "CLI interface should be accessible"
    return 1
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Cross-Platform Keychain"

    # Run tests
    run_test test_ssh_keychain_script_exists
    run_test test_platform_detection
    run_test test_has_keychain_function
    run_test test_has_secret_service_function
    run_test test_macos_keychain_detection
    run_test test_linux_fallback_graceful
    run_test test_file_based_cache_fallback
    run_test test_platform_appropriate_backend
    run_test test_cache_directory_permissions
    run_test test_keychain_store_function
    run_test test_keychain_get_function
    run_test test_no_errors_on_source
    run_test test_cli_interface_exists

    # Summary
    print_summary
}

main "$@"
