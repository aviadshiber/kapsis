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
    log_test "Testing secrets are not shown in dry-run output (use --env-file)"

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

    # Actual secret value NOT visible (secrets now use --env-file, not -e flags)
    assert_not_contains "$output" "$secret_key" "Secret should not appear in command"

    # Secrets are passed via --env-file (Fix #135: prevent secret exposure in bash -x)
    assert_contains "$output" "--env-file" "Should use --env-file for secrets"
    assert_contains "$output" "MY_API_KEY" "Should mention secret variable name"
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

    # Variable should be passed through (via --env-file), not from keychain
    # Fix #135: secrets use --env-file, not inline flags
    assert_contains "$output" "--env-file" "Should use --env-file for secrets"
    assert_contains "$output" "SHARED_API_KEY" "Secret name should be mentioned"
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

test_keychain_array_account_parsing() {
    log_test "Testing array account parsing in keychain config"

    local test_config="$TEST_PROJECT/.kapsis-array-account-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "my-service"
      account: ["user1@example.com", "user2@example.com", "${USER}@example.com"]
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse account field with array support (same yq expression as launch-agent.sh)
    local parsed
    parsed=$(yq '.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "")' "$test_config" 2>&1)
    local exit_code=$?

    rm -f "$test_config"

    assert_equals 0 "$exit_code" "Should parse array account successfully"
    assert_contains "$parsed" "MY_TOKEN|my-service|user1@example.com,user2@example.com" "Should join array accounts with comma"
}

test_keychain_string_account_backward_compat() {
    log_test "Testing string account backward compatibility"

    local test_config="$TEST_PROJECT/.kapsis-string-account-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "my-service"
      account: "single-user@example.com"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse account field with array support (same yq expression as launch-agent.sh)
    local parsed
    parsed=$(yq '.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "")' "$test_config" 2>&1)
    local exit_code=$?

    rm -f "$test_config"

    assert_equals 0 "$exit_code" "Should parse string account successfully"
    assert_contains "$parsed" "MY_TOKEN|my-service|single-user@example.com" "Should preserve string account as-is"
}

test_keychain_mixed_account_types() {
    log_test "Testing mixed string and array account types"

    local test_config="$TEST_PROJECT/.kapsis-mixed-account-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    TOKEN_WITH_ARRAY:
      service: "service-a"
      account: ["primary@example.com", "fallback@example.com"]
    TOKEN_WITH_STRING:
      service: "service-b"
      account: "only-one@example.com"
    TOKEN_NO_ACCOUNT:
      service: "service-c"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse all entries
    local parsed
    parsed=$(yq '.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "")' "$test_config" 2>&1)
    local exit_code=$?

    rm -f "$test_config"

    assert_equals 0 "$exit_code" "Should parse mixed account types"
    assert_contains "$parsed" "TOKEN_WITH_ARRAY|service-a|primary@example.com,fallback@example.com" "Should join array"
    assert_contains "$parsed" "TOKEN_WITH_STRING|service-b|only-one@example.com" "Should preserve string"
    assert_contains "$parsed" "TOKEN_NO_ACCOUNT|service-c|" "Should handle missing account"
}

test_keychain_empty_array_account() {
    log_test "Testing empty array account handling"

    local test_config="$TEST_PROJECT/.kapsis-empty-array-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "my-service"
      account: []
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse account field
    local parsed
    parsed=$(yq '.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "")' "$test_config" 2>&1)
    local exit_code=$?

    rm -f "$test_config"

    assert_equals 0 "$exit_code" "Should parse empty array account"
    assert_contains "$parsed" "MY_TOKEN|my-service|" "Should result in empty account string"
}

#===============================================================================
# inject_to TESTS (Issue #162)
#===============================================================================

test_inject_to_secret_store_config_parsing() {
    log_test "Testing inject_to: secret_store is parsed from config"

    local test_config="$TEST_PROJECT/.kapsis-inject-to-ss-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "my-service"
      inject_to: "secret_store"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    local inject_to
    inject_to=$(yq -r '.environment.keychain.MY_TOKEN.inject_to' "$test_config")

    rm -f "$test_config"

    assert_equals "secret_store" "$inject_to" "inject_to should be parsed as secret_store"
}

test_inject_to_env_config_parsing() {
    log_test "Testing inject_to: env is parsed from config"

    local test_config="$TEST_PROJECT/.kapsis-inject-to-env-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_KEY:
      service: "my-service"
      inject_to: "env"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    local inject_to
    inject_to=$(yq -r '.environment.keychain.MY_KEY.inject_to' "$test_config")

    rm -f "$test_config"

    assert_equals "env" "$inject_to" "inject_to should be parsed as env"
}

test_inject_to_global_default() {
    log_test "Testing environment.inject_to sets global default"

    local test_config="$TEST_PROJECT/.kapsis-inject-to-global-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  inject_to: "env"
  keychain:
    TOKEN_A:
      service: "service-a"
    TOKEN_B:
      service: "service-b"
      inject_to: "secret_store"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse global default
    local global_default
    global_default=$(yq -r '.environment.inject_to // "secret_store"' "$test_config")
    assert_equals "env" "$global_default" "Global inject_to should be env"

    # TOKEN_A has no inject_to — should use global default
    local token_a_inject
    token_a_inject=$(yq -r '.environment.keychain.TOKEN_A.inject_to // "UNSET"' "$test_config")
    assert_equals "UNSET" "$token_a_inject" "TOKEN_A should not have inject_to (inherits global)"

    # TOKEN_B overrides global
    local token_b_inject
    token_b_inject=$(yq -r '.environment.keychain.TOKEN_B.inject_to' "$test_config")
    assert_equals "secret_store" "$token_b_inject" "TOKEN_B should override to secret_store"

    # Test the yq pipeline that launch-agent.sh uses (via shared helper)
    local parsed
    parsed=$(parse_keychain_config "$test_config" "$global_default")

    rm -f "$test_config"

    # TOKEN_A should get the global default "env"
    assert_contains "$parsed" "TOKEN_A|service-a|||0600|env" "TOKEN_A should inherit global inject_to"
    # TOKEN_B should keep its own "secret_store"
    assert_contains "$parsed" "TOKEN_B|service-b|||0600|secret_store" "TOKEN_B should have its own inject_to"
}

test_inject_to_default_is_secret_store() {
    log_test "Testing inject_to defaults to secret_store when unset"

    local test_config="$TEST_PROJECT/.kapsis-inject-to-default-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "my-service"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # When neither global nor per-secret inject_to is set, default is "secret_store"
    # parse_keychain_config auto-detects the global default from the config
    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    assert_contains "$parsed" "MY_TOKEN|my-service|||0600|secret_store" "Default inject_to should be secret_store"
}

test_inject_to_invalid_value_warning() {
    log_test "Testing invalid inject_to value triggers warning in dry-run"

    local test_config="$TEST_PROJECT/.kapsis-inject-to-invalid-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "nonexistent-service"
      inject_to: "keyring"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Should warn about the unrecognized inject_to value
    assert_contains "$output" "Unknown inject_to" "Should warn about invalid inject_to value"
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

    # Array account fallback tests
    run_test test_keychain_array_account_parsing
    run_test test_keychain_string_account_backward_compat
    run_test test_keychain_mixed_account_types
    run_test test_keychain_empty_array_account

    # inject_to tests (Issue #162)
    run_test test_inject_to_secret_store_config_parsing
    run_test test_inject_to_env_config_parsing
    run_test test_inject_to_global_default
    run_test test_inject_to_default_is_secret_store
    run_test test_inject_to_invalid_value_warning

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
