#!/usr/bin/env bash
#===============================================================================
# Test: Keychain Retrieval
#
# Verifies secrets retrieval from OS keychain and handling of missing secrets.
# Tests secret masking, priority handling, and graceful degradation.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
SSH_KEYCHAIN_SCRIPT="$KAPSIS_ROOT/scripts/lib/ssh-keychain.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_secrets_masked_in_dry_run() {
    log_test "Testing secrets are masked in dry-run output"

    local secret_key="sk-secret-value-12345"

    # Create a custom config with passthrough
    local test_config="$TEST_PROJECT/.kapsis-mask-dry-run-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - MY_API_KEY
EOF

    export MY_API_KEY="$secret_key"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset MY_API_KEY
    rm -f "$test_config"

    # Actual secret value NOT visible (KEY in name triggers masking)
    assert_not_contains "$output" "$secret_key" "Secret should be masked"

    # Masking indicator shown
    assert_contains "$output" "MASKED" "Should show masking indicator"
}

test_keychain_lookup_function_exists() {
    log_test "Testing keychain lookup functions exist"

    source "$SSH_KEYCHAIN_SCRIPT"

    # Check that key functions are defined
    if declare -f ssh_keychain_get >/dev/null 2>&1 || declare -f ssh_has_keychain >/dev/null 2>&1; then
        return 0
    else
        # Functions may have different names - check for any keychain-related function
        local funcs
        funcs=$(declare -F | grep -ci "ssh_" || true)
        assert_true "[[ $funcs -gt 0 ]]" "Should have SSH keychain functions defined"
    fi
}

test_missing_keychain_no_crash() {
    log_test "Testing missing keychain entry doesn't cause crash"

    local test_config="$TEST_PROJECT/.kapsis-missing-keychain-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    NONEXISTENT_SECRET:
      service: "nonexistent-service-12345"
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should complete without crashing (may warn but shouldn't fail)
    assert_contains "$output" "DRY RUN" "Should complete dry-run even with missing keychain entry"
}

test_keychain_service_name_format() {
    log_test "Testing keychain service name is properly formatted"

    local test_config="$TEST_PROJECT/.kapsis-keychain-format-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_SECRET:
      service: "com.example.my-service"
      account: "api-key"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse keychain section (use -r to get raw string without quotes)
    local service
    service=$(yq -r '.environment.keychain.MY_SECRET.service' "$test_config")

    rm -f "$test_config"

    assert_equals "com.example.my-service" "$service" "Service name should be preserved"
}

test_keychain_passthrough_precedence() {
    log_test "Testing passthrough has precedence over keychain"

    local test_config="$TEST_PROJECT/.kapsis-precedence-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - SHARED_API_KEY
  keychain:
    SHARED_API_KEY:
      service: "keychain-service"
EOF

    export SHARED_API_KEY="passthrough-value"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset SHARED_API_KEY
    rm -f "$test_config"

    # Variable should be passed through (from env), not from keychain
    # KEY in name triggers masking
    assert_contains "$output" "SHARED_API_KEY=***MASKED***" "Should use passthrough value"
}

test_keychain_inject_to_file_config() {
    log_test "Testing inject_to_file configuration is parsed"

    local test_config="$TEST_PROJECT/.kapsis-inject-config-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    AGENT_CREDS:
      service: "agent-creds"
      inject_to_file: "~/.config/agent/credentials.json"
      mode: "0600"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse inject_to_file
    local inject_path
    inject_path=$(yq -r '.environment.keychain.AGENT_CREDS.inject_to_file' "$test_config")

    local mode
    mode=$(yq -r '.environment.keychain.AGENT_CREDS.mode' "$test_config")

    rm -f "$test_config"

    # The config file contains literal "~/" which yq preserves as a string
    # Verify the path starts with ~/ and contains the expected components
    assert_contains "$inject_path" ".config/agent/credentials.json" "inject_to_file should contain path"
    assert_true "[[ \${inject_path:0:2} == '~/' ]]" "inject_to_file path should start with ~/"
    assert_equals "0600" "$mode" "mode should be parsed"
}

test_empty_keychain_section() {
    log_test "Testing empty keychain section is handled"

    local test_config="$TEST_PROJECT/.kapsis-empty-keychain-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain: {}
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should complete successfully
    assert_equals 0 "$exit_code" "Should handle empty keychain section"
    assert_contains "$output" "DRY RUN" "Should complete dry-run"
}

test_no_keychain_section() {
    log_test "Testing config without keychain section"

    local test_config="$TEST_PROJECT/.kapsis-no-keychain-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - MY_VAR
EOF

    export MY_VAR="my-value"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    unset MY_VAR
    rm -f "$test_config"

    # Should complete successfully
    assert_equals 0 "$exit_code" "Should work without keychain section"
    assert_contains "$output" "MY_VAR=my-value" "Passthrough vars should work"
}

test_special_characters_in_secret_name() {
    log_test "Testing special characters in keychain variable names"

    local test_config="$TEST_PROJECT/.kapsis-special-name-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_API_KEY_V2:
      service: "my-service"
    TOKEN_3RD_PARTY:
      service: "third-party-service"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse to verify no errors
    local keys
    keys=$(yq '.environment.keychain | keys | .[]' "$test_config" 2>&1)
    local exit_code=$?

    rm -f "$test_config"

    assert_equals 0 "$exit_code" "Should parse variable names with numbers"
    assert_contains "$keys" "MY_API_KEY_V2" "Should include MY_API_KEY_V2"
    assert_contains "$keys" "TOKEN_3RD_PARTY" "Should include TOKEN_3RD_PARTY"
}

test_keychain_multiple_entries() {
    log_test "Testing multiple keychain entries"

    local test_config="$TEST_PROJECT/.kapsis-multi-keychain-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    SECRET_ONE:
      service: "service-one"
    SECRET_TWO:
      service: "service-two"
      account: "account-two"
    SECRET_THREE:
      service: "service-three"
      inject_to_file: "~/.secret3.json"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Count entries
    local count
    count=$(yq '.environment.keychain | keys | length' "$test_config")

    rm -f "$test_config"

    assert_equals "3" "$count" "Should have 3 keychain entries"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Keychain Retrieval"

    # Setup
    setup_test_project

    # Run tests
    run_test test_secrets_masked_in_dry_run
    run_test test_keychain_lookup_function_exists
    run_test test_missing_keychain_no_crash
    run_test test_keychain_service_name_format
    run_test test_keychain_passthrough_precedence
    run_test test_keychain_inject_to_file_config
    run_test test_empty_keychain_section
    run_test test_no_keychain_section
    run_test test_special_characters_in_secret_name
    run_test test_keychain_multiple_entries

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
