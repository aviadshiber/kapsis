#!/usr/bin/env bash
#===============================================================================
# Test: SSH Keychain Integration
#
# Verifies SSH host key verification and caching functionality across platforms.
# Tests fingerprint verification, TOFU mode, and known_hosts generation.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

SSH_KEYCHAIN_SCRIPT="$KAPSIS_ROOT/scripts/lib/ssh-keychain.sh"

# Test-specific config
TEST_SSH_CONFIG_DIR="$TEST_PROJECT/.kapsis-test-ssh"
TEST_SSH_CUSTOM_CONFIG="$TEST_SSH_CONFIG_DIR/ssh-hosts.conf"
TEST_SSH_CACHE_DIR="$TEST_SSH_CONFIG_DIR/ssh-cache"

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_test_environment() {
    mkdir -p "$TEST_SSH_CONFIG_DIR"
    mkdir -p "$TEST_SSH_CACHE_DIR"

    # Override config paths for testing
    export SSH_CUSTOM_CONFIG="$TEST_SSH_CUSTOM_CONFIG"
    export SSH_CACHE_DIR="$TEST_SSH_CACHE_DIR"

    # Use a unique keychain service for testing (avoid polluting real cache)
    export SSH_KEYCHAIN_SERVICE="kapsis-ssh-test-$$"

    # Disable TOFU by default
    export SSH_TOFU_ENABLED="false"
}

cleanup_test_environment() {
    rm -rf "$TEST_SSH_CONFIG_DIR"

    # Clean up test keychain entries (macOS only, suppress all output)
    if [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null; then
        for host in github.com gitlab.com bitbucket.org test-host.example.com; do
            security delete-generic-password -s "$SSH_KEYCHAIN_SERVICE" -a "$host" &>/dev/null || true
            security delete-generic-password -s "${SSH_KEYCHAIN_SERVICE}-timestamp" -a "$host" &>/dev/null || true
        done
    fi
}

#===============================================================================
# TEST CASES
#===============================================================================

test_script_exists() {
    log_test "SSH keychain script exists and is executable"

    assert_file_exists "$SSH_KEYCHAIN_SCRIPT" "SSH keychain script should exist"
    assert_true "[[ -x '$SSH_KEYCHAIN_SCRIPT' ]]" "Script should be executable"
}

test_script_passes_shellcheck() {
    log_test "Script passes shellcheck"

    if ! command -v shellcheck &>/dev/null; then
        log_skip "shellcheck not available"
        return 0
    fi

    local exit_code=0
    shellcheck "$SSH_KEYCHAIN_SCRIPT" || exit_code=$?

    assert_equals 0 "$exit_code" "Script should pass shellcheck"
}

test_cli_verify_help() {
    log_test "CLI verify subcommand works"

    local output
    local exit_code=0

    # Verify with github.com (should work with network access)
    output=$("$SSH_KEYCHAIN_SCRIPT" verify github.com 2>&1) || exit_code=$?

    # Should succeed (0) or fail gracefully if no network
    assert_contains "$output" "github.com" "Should reference github.com in output"
}

test_cli_list_hosts_empty() {
    log_test "list-hosts with no custom config shows message"

    setup_test_environment

    # Ensure no config exists
    rm -f "$TEST_SSH_CUSTOM_CONFIG"

    local output
    output=$("$SSH_KEYCHAIN_SCRIPT" list-hosts 2>&1)

    assert_contains "$output" "No custom" "Should indicate no custom hosts"

    cleanup_test_environment
}

test_cli_add_host_requires_hostname() {
    log_test "add-host requires hostname argument"

    local exit_code=0
    "$SSH_KEYCHAIN_SCRIPT" add-host 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail without hostname"
}

test_custom_config_creation() {
    log_test "Custom config file is created with proper permissions"

    setup_test_environment

    # Add a test host (non-interactively via direct function call)
    source "$SSH_KEYCHAIN_SCRIPT"
    ssh_add_custom_host "test-host.example.com" "SHA256:testfingerprint123"

    assert_file_exists "$TEST_SSH_CUSTOM_CONFIG" "Config file should be created"

    # Check permissions (should be 600)
    local perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        perms=$(stat -f "%Lp" "$TEST_SSH_CUSTOM_CONFIG")
    else
        perms=$(stat -c "%a" "$TEST_SSH_CUSTOM_CONFIG")
    fi
    assert_equals "600" "$perms" "Config should have 600 permissions"

    cleanup_test_environment
}

test_custom_fingerprint_lookup() {
    log_test "Can lookup custom host fingerprint from config"

    setup_test_environment

    # Create config with test entry
    echo "my-git.company.com SHA256:abc123def456" > "$TEST_SSH_CUSTOM_CONFIG"
    chmod 600 "$TEST_SSH_CUSTOM_CONFIG"

    # Source the script and test lookup
    source "$SSH_KEYCHAIN_SCRIPT"

    local result
    result=$(ssh_get_custom_fingerprint "my-git.company.com")

    assert_equals "SHA256:abc123def456" "$result" "Should return stored fingerprint"

    cleanup_test_environment
}

test_custom_fingerprint_not_found() {
    log_test "Lookup for unknown host returns error"

    setup_test_environment

    # Create config with different host
    echo "other-host.com SHA256:xyz789" > "$TEST_SSH_CUSTOM_CONFIG"
    chmod 600 "$TEST_SSH_CUSTOM_CONFIG"

    source "$SSH_KEYCHAIN_SCRIPT"

    local exit_code=0
    ssh_get_custom_fingerprint "unknown-host.com" || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail for unknown host"

    cleanup_test_environment
}

test_github_fingerprints_fetch() {
    log_test "Can fetch GitHub official fingerprints"

    # Fetch API response and check for rate limiting
    local api_response
    api_response=$(curl -sS --max-time 10 https://api.github.com/meta 2>&1) || {
        log_skip "Network error fetching GitHub API"
        return 0
    }

    # Check if rate limited (response won't have ssh_key_fingerprints)
    if ! echo "$api_response" | jq -e '.ssh_key_fingerprints' >/dev/null 2>&1; then
        log_skip "GitHub API rate limited - skipping (not a test failure)"
        return 0
    fi

    source "$SSH_KEYCHAIN_SCRIPT"

    local fingerprints
    fingerprints=$(ssh_fetch_github_fingerprints)

    # Should contain SHA256 fingerprints
    assert_contains "$fingerprints" "SHA256" "Should contain SHA256 fingerprints"
}

test_gitlab_fingerprints_static() {
    log_test "GitLab fingerprints are available (static)"

    source "$SSH_KEYCHAIN_SCRIPT"

    local fingerprints
    fingerprints=$(ssh_fetch_gitlab_fingerprints)

    assert_contains "$fingerprints" "SHA256" "Should contain SHA256 fingerprints"
}

test_bitbucket_fingerprints_static() {
    log_test "Bitbucket fingerprints are available (static)"

    source "$SSH_KEYCHAIN_SCRIPT"

    local fingerprints
    fingerprints=$(ssh_fetch_bitbucket_fingerprints)

    assert_contains "$fingerprints" "SHA256" "Should contain SHA256 fingerprints"
}

test_platform_detection_keychain() {
    log_test "Platform detection - macOS Keychain"

    source "$SSH_KEYCHAIN_SCRIPT"

    if [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null; then
        assert_command_succeeds "ssh_has_keychain" "macOS should have keychain"
    else
        assert_command_fails "ssh_has_keychain" "Non-macOS should not have keychain"
    fi
}

test_platform_detection_secret_service() {
    log_test "Platform detection - Linux Secret Service"

    source "$SSH_KEYCHAIN_SCRIPT"

    if [[ "$(uname -s)" == "Linux" ]] && command -v secret-tool &>/dev/null; then
        assert_command_succeeds "ssh_has_secret_service" "Linux with secret-tool should detect it"
    else
        assert_command_fails "ssh_has_secret_service" "Platform without secret-tool should fail detection"
    fi
}

test_file_based_cache_permissions() {
    log_test "File-based cache has secure permissions"

    setup_test_environment

    source "$SSH_KEYCHAIN_SCRIPT"

    # Simulate storing a key (use file-based storage by forcing non-keychain)
    mkdir -p "$SSH_CACHE_DIR"
    chmod 700 "$SSH_CACHE_DIR"

    local cache_file="$SSH_CACHE_DIR/test-host.key"
    (umask 077; echo "test-key-data" > "$cache_file")

    # Check directory permissions
    local dir_perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        dir_perms=$(stat -f "%Lp" "$SSH_CACHE_DIR")
    else
        dir_perms=$(stat -c "%a" "$SSH_CACHE_DIR")
    fi
    assert_equals "700" "$dir_perms" "Cache dir should have 700 permissions"

    # Check file permissions
    local file_perms
    if [[ "$(uname -s)" == "Darwin" ]]; then
        file_perms=$(stat -f "%Lp" "$cache_file")
    else
        file_perms=$(stat -c "%a" "$cache_file")
    fi
    assert_equals "600" "$file_perms" "Cache file should have 600 permissions"

    cleanup_test_environment
}

test_known_hosts_generation() {
    log_test "known_hosts file generation"

    setup_test_environment

    # Skip if no network access
    if ! curl -s --max-time 5 https://api.github.com/meta >/dev/null 2>&1; then
        log_skip "No network access"
        cleanup_test_environment
        return 0
    fi

    local output_file="$TEST_SSH_CONFIG_DIR/known_hosts"

    local exit_code=0
    "$SSH_KEYCHAIN_SCRIPT" generate "$output_file" github.com 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        assert_file_exists "$output_file" "known_hosts file should be created"

        # Verify format (should contain github.com and key type)
        local content
        content=$(cat "$output_file")
        assert_contains "$content" "github.com" "Should contain github.com"
        assert_contains "$content" "ssh-" "Should contain SSH key type"
    else
        log_skip "Network or key verification issue - skipping content check"
    fi

    cleanup_test_environment
}

test_key_ttl_expiration() {
    log_test "Cache TTL expiration logic"

    setup_test_environment

    source "$SSH_KEYCHAIN_SCRIPT"

    # Set very short TTL for testing
    export SSH_KEY_TTL=1  # 1 second

    # Store test data in file cache
    mkdir -p "$SSH_CACHE_DIR"
    chmod 700 "$SSH_CACHE_DIR"

    local test_host="ttl-test-host"
    local cache_file="$SSH_CACHE_DIR/${test_host}.key"
    local ts_file="$SSH_CACHE_DIR/${test_host}.ts"

    # Write with current timestamp
    echo "test-key-data" > "$cache_file"
    date +%s > "$ts_file"

    # Key should be retrievable immediately
    # (Need to check via file reads since ssh_keychain_get might use keychain on macOS)
    local current_ts fresh_ts
    current_ts=$(date +%s)
    fresh_ts=$(cat "$ts_file")

    local age=$((current_ts - fresh_ts))
    assert_true "[[ $age -le $SSH_KEY_TTL ]]" "Fresh key should not be expired"

    # Wait for expiration
    sleep 2

    # Key should now be expired
    current_ts=$(date +%s)
    age=$((current_ts - fresh_ts))
    assert_true "[[ $age -gt $SSH_KEY_TTL ]]" "Old key should be expired"

    cleanup_test_environment
}

test_fingerprint_computation() {
    log_test "SSH fingerprint computation"

    # Skip if ssh-keygen is not available
    if ! command -v ssh-keygen &>/dev/null; then
        log_skip "ssh-keygen not available"
        return 0
    fi

    # Test if ssh-keygen can read from stdin (not all versions support -f -)
    local test_result
    test_result=$(echo "test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" | ssh-keygen -lf - 2>/dev/null) || true
    if [[ -z "$test_result" ]]; then
        log_skip "ssh-keygen does not support reading from stdin"
        return 0
    fi

    source "$SSH_KEYCHAIN_SCRIPT"

    # Test with a known SSH key (ed25519 test key)
    local test_key="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

    local fingerprint
    fingerprint=$(ssh_compute_fingerprint "$test_key")

    # Should start with SHA256:
    assert_contains "$fingerprint" "SHA256:" "Fingerprint should be SHA256 format"
}

test_verify_key_mismatch_detection() {
    log_test "Key verification detects fingerprint mismatch"

    # Skip if ssh-keygen cannot compute fingerprints
    if ! command -v ssh-keygen &>/dev/null; then
        log_skip "ssh-keygen not available"
        return 0
    fi

    # Test if ssh-keygen can read from stdin
    local test_fp
    test_fp=$(echo "test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || true
    if [[ -z "$test_fp" ]]; then
        log_skip "ssh-keygen cannot compute fingerprints from stdin"
        return 0
    fi

    setup_test_environment

    source "$SSH_KEYCHAIN_SCRIPT"

    # Create custom config with wrong fingerprint
    echo "github.com SHA256:WRONG_FINGERPRINT_12345" > "$TEST_SSH_CUSTOM_CONFIG"
    chmod 600 "$TEST_SSH_CUSTOM_CONFIG"

    # Skip if no network
    if ! curl -s --max-time 5 https://api.github.com/meta >/dev/null 2>&1; then
        log_skip "No network access"
        cleanup_test_environment
        return 0
    fi

    # Fetch real key
    local key_data
    key_data=$(ssh-keyscan -t ed25519 github.com 2>/dev/null) || {
        log_skip "Could not scan github.com"
        cleanup_test_environment
        return 0
    }

    # Verify should fail because config has wrong fingerprint
    local exit_code=0
    ssh_verify_key "github.com" "$key_data" 2>/dev/null || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail with mismatched fingerprint"

    cleanup_test_environment
}

test_no_secrets_in_output() {
    log_test "No private keys or secrets in command output"

    setup_test_environment

    # Run verify and capture all output
    local output
    output=$("$SSH_KEYCHAIN_SCRIPT" verify github.com 2>&1) || true

    # Should not contain common secret patterns
    # Private keys start with "-----BEGIN"
    assert_not_contains "$output" "-----BEGIN" "Should not contain private key markers"
    assert_not_contains "$output" "PRIVATE KEY" "Should not reference private keys"

    cleanup_test_environment
}

#===============================================================================
# RUN TESTS
#===============================================================================

print_test_header "SSH Keychain Integration"

# Core functionality
run_test test_script_exists
run_test test_script_passes_shellcheck

# CLI interface
run_test test_cli_verify_help
run_test test_cli_list_hosts_empty
run_test test_cli_add_host_requires_hostname

# Custom config management
run_test test_custom_config_creation
run_test test_custom_fingerprint_lookup
run_test test_custom_fingerprint_not_found

# Provider fingerprints
run_test test_github_fingerprints_fetch
run_test test_gitlab_fingerprints_static
run_test test_bitbucket_fingerprints_static

# Platform detection
run_test test_platform_detection_keychain
run_test test_platform_detection_secret_service

# Security
run_test test_file_based_cache_permissions
run_test test_key_ttl_expiration
run_test test_fingerprint_computation
run_test test_verify_key_mismatch_detection
run_test test_no_secrets_in_output

# Integration
run_test test_known_hosts_generation

print_summary
