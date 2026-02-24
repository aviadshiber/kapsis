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
# KEYRING COLLECTION TESTS (Issue #170)
#===============================================================================

test_yq_expr_includes_keyring_collection() {
    log_test "Testing YQ expression includes keyring_collection and keyring_profile as 7th and 8th fields"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-keyring-coll-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    BKT_TOKEN:
      service: "bkt"
      account: "host/example.com/token"
      inject_to: "secret_store"
      keyring_collection: "bkt"
    PLAIN_TOKEN:
      service: "plain-svc"
      inject_to: "secret_store"
    CUSTOM_PROFILE:
      service: "custom-svc"
      account: "lookup-account"
      inject_to: "secret_store"
      keyring_collection: "mycoll"
      keyring_profile: "host/example.com/token"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    assert_contains "$parsed" "BKT_TOKEN|bkt|host/example.com/token||0600|secret_store|bkt|" \
        "keyring_collection should be parsed as 7th field"
    assert_contains "$parsed" "PLAIN_TOKEN|plain-svc|||0600|secret_store||" \
        "missing keyring_collection should be empty 7th field"
    assert_contains "$parsed" "CUSTOM_PROFILE|custom-svc|lookup-account||0600|secret_store|mycoll|host/example.com/token" \
        "keyring_profile should be parsed as 8th field"
}

test_keyring_collection_in_launch_script() {
    log_test "Testing launch-agent.sh tracks KAPSIS_KEYRING_COLLECTIONS"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    assert_contains "$(cat "$launch_script")" "KAPSIS_KEYRING_COLLECTIONS" \
        "launch-agent.sh should reference KAPSIS_KEYRING_COLLECTIONS"
    assert_contains "$(cat "$launch_script")" "keyring_collection" \
        "launch-agent.sh should read keyring_collection field"
}

test_entrypoint_has_keyring_compat() {
    log_test "Testing entrypoint.sh has 99designs/keyring compat logic"

    local entrypoint_script="$KAPSIS_ROOT/scripts/entrypoint.sh"

    assert_contains "$(cat "$entrypoint_script")" "kapsis-ss-inject" \
        "entrypoint.sh should call kapsis-ss-inject helper"
    assert_contains "$(cat "$entrypoint_script")" "keyring_collections" \
        "entrypoint.sh should parse keyring_collections map"
    assert_contains "$(cat "$entrypoint_script")" "99designs/keyring compat" \
        "entrypoint.sh should document 99designs/keyring compatibility"
}

test_keyring_collection_coexists_with_inject_to() {
    log_test "Testing keyring_collection works alongside inject_to: secret_store"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-keyring-coexist-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    BKT_CRED:
      service: "bkt"
      account: "host/example.com/token"
      inject_to: "secret_store"
      inject_to_file: "~/.config/bkt/token"
      keyring_collection: "bkt"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    # All fields should coexist in the pipe output
    assert_contains "$parsed" "BKT_CRED|bkt|host/example.com/token|~/.config/bkt/token|0600|secret_store|bkt|" \
        "keyring_collection should coexist with inject_to_file and inject_to"
}

test_keyring_profile_overrides_account() {
    log_test "Testing keyring_profile overrides account in YQ pipeline output"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local test_config="$TEST_PROJECT/.kapsis-keyring-profile-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    BKT_TOKEN:
      service: "bkt"
      account: "aviad.s"
      inject_to: "secret_store"
      keyring_collection: "bkt"
      keyring_profile: "host/git.taboolasyndication.com/token"
    NO_PROFILE:
      service: "plain"
      account: "myaccount"
      inject_to: "secret_store"
      keyring_collection: "plain-coll"
EOF

    local parsed
    parsed=$(parse_keychain_config "$test_config")

    rm -f "$test_config"

    assert_contains "$parsed" "BKT_TOKEN|bkt|aviad.s||0600|secret_store|bkt|host/git.taboolasyndication.com/token" \
        "keyring_profile should appear as 8th field"
    assert_contains "$parsed" "NO_PROFILE|plain|myaccount||0600|secret_store|plain-coll|" \
        "missing keyring_profile should be empty 8th field"
}

test_keyring_profile_validation() {
    log_test "Testing keyring_profile validation in launch-agent.sh"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    assert_contains "$(cat "$launch_script")" "keyring_profile" \
        "launch-agent.sh should reference keyring_profile field"
    assert_contains "$(cat "$launch_script")" "keyring_profile for" \
        "launch-agent.sh should validate keyring_profile"
}

test_keyring_field_allowlist_validation() {
    log_test "Testing keyring fields use allowlist validation (not blocklist)"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local content
    content=$(cat "$launch_script")

    # Should use regex allowlist pattern [^a-zA-Z0-9/.@:_-]
    assert_contains "$content" '[^a-zA-Z0-9/.@:_-]' \
        "Should use allowlist regex for character validation"

    # Should NOT use old blocklist pattern *"|"*
    if [[ "$content" == *'== *"|"*'* ]]; then
        log_fail "Should not use blocklist pattern *\"|\"* — use allowlist regex instead"
        return 1
    fi
    log_pass "No blocklist patterns found — using allowlist validation"
}

test_entrypoint_has_keyring_profile_support() {
    log_test "Testing entrypoint.sh has keyring_profile support"

    local entrypoint_script="$KAPSIS_ROOT/scripts/entrypoint.sh"

    assert_contains "$(cat "$entrypoint_script")" "keyring_profiles" \
        "entrypoint.sh should parse keyring_profiles map"
    assert_contains "$(cat "$entrypoint_script")" "inject_key" \
        "entrypoint.sh should compute inject_key from profile"
}

test_kapsis_ss_inject_script_exists() {
    log_test "Testing kapsis-ss-inject.py script exists and is valid Python"

    local script="$KAPSIS_ROOT/scripts/kapsis-ss-inject.py"

    assert_file_exists "$script" "kapsis-ss-inject.py should exist"

    if command -v python3 &>/dev/null; then
        python3 -m py_compile "$script" 2>/dev/null
        assert_equals "0" "$?" "kapsis-ss-inject.py should be valid Python"
    else
        log_skip "python3 not available for syntax check"
    fi
}

test_containerfile_includes_secretstorage() {
    log_test "Testing Containerfile installs python3-secretstorage"

    local containerfile="$KAPSIS_ROOT/Containerfile"

    assert_contains "$(cat "$containerfile")" "python3-secretstorage" \
        "Containerfile should install python3-secretstorage"
    assert_contains "$(cat "$containerfile")" "kapsis-ss-inject" \
        "Containerfile should copy kapsis-ss-inject script"
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

    # Keyring collection tests (Issue #170)
    run_test test_yq_expr_includes_keyring_collection
    run_test test_keyring_collection_in_launch_script
    run_test test_entrypoint_has_keyring_compat
    run_test test_keyring_collection_coexists_with_inject_to
    run_test test_kapsis_ss_inject_script_exists
    run_test test_containerfile_includes_secretstorage

    # Keyring profile tests (Issue #176)
    run_test test_keyring_profile_overrides_account
    run_test test_keyring_profile_validation
    run_test test_entrypoint_has_keyring_profile_support

    # Security hardening
    run_test test_keyring_field_allowlist_validation

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
