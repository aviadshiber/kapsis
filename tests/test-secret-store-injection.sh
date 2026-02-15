#!/usr/bin/env bash
#===============================================================================
# Test: Secret Store Injection (Issue #162)
#
# Verifies that secrets can be injected into the container's Linux Secret
# Service (gnome-keyring) instead of remaining as environment variables.
#
# Category: security
# Container required: No (config parsing and validation tests only)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# CONFIG PARSING TESTS (no container required)
#===============================================================================

test_inject_to_field_in_yq_pipeline() {
    log_test "Testing inject_to field is included in yq pipeline output"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-ss-yq-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    TOKEN_SS:
      service: "token-ss"
      inject_to: "secret_store"
    TOKEN_ENV:
      service: "token-env"
      inject_to: "env"
    TOKEN_DEFAULT:
      service: "token-default"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    # Verify inject_to values
    assert_contains "$parsed" "TOKEN_SS|token-ss|||0600|secret_store" "secret_store should be parsed"
    assert_contains "$parsed" "TOKEN_ENV|token-env|||0600|env" "env should be parsed"
    assert_contains "$parsed" "TOKEN_DEFAULT|token-default|||0600|secret_store" "default should be secret_store"
}

test_inject_to_with_inject_to_file_coexist() {
    log_test "Testing inject_to and inject_to_file can coexist"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-ss-coexist-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    AGENT_CREDS:
      service: "agent-creds"
      inject_to: "secret_store"
      inject_to_file: "~/.config/agent/creds.json"
      mode: "0640"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    assert_contains "$parsed" "AGENT_CREDS|agent-creds||~/.config/agent/creds.json|0640|secret_store" \
        "inject_to and inject_to_file should both be present"
}

test_secret_store_entries_dry_run() {
    log_test "Testing KAPSIS_SECRET_STORE_ENTRIES appears in dry-run when inject_to: secret_store"

    local test_config="$TEST_PROJECT/.kapsis-ss-dryrun-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    MY_TOKEN:
      service: "nonexistent-service"
      inject_to: "secret_store"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # The dry-run should complete (secret may not be found, but that's OK)
    assert_contains "$output" "DRY RUN" "Dry-run should complete with inject_to: secret_store"
}

test_build_config_secret_store_toggle() {
    log_test "Testing ENABLE_SECRET_STORE build arg from build-config library"

    # Source the build config library
    source "$KAPSIS_ROOT/scripts/lib/build-config.sh"

    # Test with full-stack profile
    local profile="$KAPSIS_ROOT/configs/build-profiles/full-stack.yaml"
    if [[ -f "$profile" ]]; then
        parse_build_config "$profile"

        assert_equals "true" "$ENABLE_SECRET_STORE" "full-stack profile should enable secret store"

        # Check it generates the build arg
        local build_args_str
        build_args_str=$(printf '%s\n' "${BUILD_ARGS[@]}")
        assert_contains "$build_args_str" "ENABLE_SECRET_STORE=true" "Build args should include ENABLE_SECRET_STORE"
    else
        log_skip "full-stack profile not found"
    fi
}

test_build_config_minimal_no_secret_store() {
    log_test "Testing minimal profile disables secret store"

    # Source the build config library
    source "$KAPSIS_ROOT/scripts/lib/build-config.sh"

    local profile="$KAPSIS_ROOT/configs/build-profiles/minimal.yaml"
    if [[ -f "$profile" ]]; then
        parse_build_config "$profile"

        assert_equals "false" "$ENABLE_SECRET_STORE" "minimal profile should disable secret store"
    else
        log_skip "minimal profile not found"
    fi
}

test_constants_secret_store_defaults() {
    log_test "Testing secret store constants are defined"

    source "$KAPSIS_ROOT/scripts/lib/constants.sh"

    assert_equals "secret_store" "$KAPSIS_SECRET_STORE_DEFAULT_INJECT_TO" \
        "Default inject_to should be secret_store"
    assert_equals "2" "${#KAPSIS_SECRET_STORE_INJECT_TO_VALUES[@]}" \
        "Should have 2 valid inject_to values"
    assert_equals "secret_store" "${KAPSIS_SECRET_STORE_INJECT_TO_VALUES[0]}" \
        "First value should be secret_store"
    assert_equals "env" "${KAPSIS_SECRET_STORE_INJECT_TO_VALUES[1]}" \
        "Second value should be env"
}

test_credential_files_preserves_env_for_secret_store() {
    log_test "Testing inject_credential_files preserves env vars for secret store entries"

    local entrypoint_script="$KAPSIS_ROOT/scripts/entrypoint.sh"

    # Verify the entrypoint checks KAPSIS_SECRET_STORE_ENTRIES before unsetting
    assert_contains "$(cat "$entrypoint_script")" "KAPSIS_SECRET_STORE_ENTRIES" \
        "inject_credential_files should reference KAPSIS_SECRET_STORE_ENTRIES"
    assert_contains "$(cat "$entrypoint_script")" "env var for secret store injection" \
        "Should log when keeping env var for secret store injection"
}

test_inject_to_validation_in_launch_script() {
    log_test "Testing inject_to validation is present in launch-agent.sh"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    # Verify validation logic exists
    assert_contains "$(cat "$launch_script")" "Unknown inject_to value" \
        "Should validate unknown inject_to values"
    assert_contains "$(cat "$launch_script")" "defaulting to env" \
        "Should default invalid values to env"
}

test_yq_expr_shared_between_launch_and_tests() {
    log_test "Testing KAPSIS_YQ_KEYCHAIN_EXPR is sourced from constants.sh"

    # Verify constants.sh defines the expression
    local constants_file="$KAPSIS_ROOT/scripts/lib/constants.sh"
    assert_contains "$(cat "$constants_file")" "KAPSIS_YQ_KEYCHAIN_EXPR" \
        "constants.sh should define KAPSIS_YQ_KEYCHAIN_EXPR"

    # Verify launch-agent.sh references the constant (not inline expression)
    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    # shellcheck disable=SC2016
    assert_contains "$(cat "$launch_script")" 'yq "$KAPSIS_YQ_KEYCHAIN_EXPR"' \
        "launch-agent.sh should use the shared constant"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Secret Store Injection"

    # Setup
    setup_test_project

    # Config parsing tests (no container required)
    run_test test_inject_to_field_in_yq_pipeline
    run_test test_inject_to_with_inject_to_file_coexist
    run_test test_secret_store_entries_dry_run
    run_test test_build_config_secret_store_toggle
    run_test test_build_config_minimal_no_secret_store
    run_test test_constants_secret_store_defaults

    # Review fix verification tests
    run_test test_credential_files_preserves_env_for_secret_store
    run_test test_inject_to_validation_in_launch_script
    run_test test_yq_expr_shared_between_launch_and_tests

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
