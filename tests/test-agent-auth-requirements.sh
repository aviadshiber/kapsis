#!/usr/bin/env bash
#===============================================================================
# Test: Agent Authentication Requirements
#
# Verifies that agent profiles properly handle authentication requirements.
# Tests missing required credentials, present credentials, and error messages.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_present_auth_succeeds() {
    log_test "Testing available credential allows launch"

    # Save original value if set
    local original_key="${ANTHROPIC_API_KEY:-}"

    # Set required credential
    export ANTHROPIC_API_KEY="test-key-12345"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || exit_code=$?

    # Restore original
    if [[ -n "$original_key" ]]; then
        export ANTHROPIC_API_KEY="$original_key"
    else
        unset ANTHROPIC_API_KEY
    fi

    # Should succeed without auth errors
    assert_equals 0 "$exit_code" "Should succeed with present auth"
    assert_not_contains "$output" "auth error" "Should not show auth errors"
    assert_not_contains "$output" "credential error" "Should not show credential errors"
}

test_auth_in_passthrough() {
    log_test "Testing auth key appears in passthrough"

    # Create a custom config that uses passthrough for auth key
    local test_config="$TEST_PROJECT/.kapsis-auth-passthrough-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - ANTHROPIC_API_KEY
EOF

    # Set test key
    export ANTHROPIC_API_KEY="test-auth-key"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset ANTHROPIC_API_KEY
    rm -f "$test_config"

    # Key should be passed through (masked in output because it contains KEY)
    assert_contains "$output" "ANTHROPIC_API_KEY=***MASKED***" "Auth key should be passed through (masked)"
}

test_multiple_auth_keys() {
    log_test "Testing multiple auth keys can be configured"

    local test_config="$TEST_PROJECT/.kapsis-multi-auth-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - ANTHROPIC_API_KEY
    - OPENAI_API_KEY
    - CUSTOM_TOKEN
EOF

    export ANTHROPIC_API_KEY="anthro-key"
    export OPENAI_API_KEY="openai-key"
    export CUSTOM_TOKEN="custom-token"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset ANTHROPIC_API_KEY OPENAI_API_KEY CUSTOM_TOKEN
    rm -f "$test_config"

    # All keys should be passed through
    assert_contains "$output" "ANTHROPIC_API_KEY=***MASKED***" "ANTHROPIC_API_KEY should be passed"
    assert_contains "$output" "OPENAI_API_KEY=***MASKED***" "OPENAI_API_KEY should be passed"
    assert_contains "$output" "CUSTOM_TOKEN=***MASKED***" "CUSTOM_TOKEN should be passed"
}

test_env_priority_over_keychain() {
    log_test "Testing environment takes priority over keychain"

    # This tests the logic that environment passthrough is processed first
    local test_config="$TEST_PROJECT/.kapsis-env-priority-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - MY_API_KEY
  keychain:
    MY_API_KEY:
      service: "should-not-be-used"
EOF

    export MY_API_KEY="env-value-wins"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset MY_API_KEY
    rm -f "$test_config"

    # Passthrough should be used, not keychain lookup
    assert_contains "$output" "MY_API_KEY=***MASKED***" "Env var should be used from passthrough"
}

test_secrets_masked_in_output() {
    log_test "Testing secrets are masked in dry-run output"

    local secret_key="sk-secret-value-do-not-show"

    # Create a custom config that uses passthrough
    local test_config="$TEST_PROJECT/.kapsis-secret-mask-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - MY_SECRET_KEY
EOF

    export MY_SECRET_KEY="$secret_key"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset MY_SECRET_KEY
    rm -f "$test_config"

    # Actual secret value should NOT be visible
    assert_not_contains "$output" "$secret_key" "Secret value should be masked"

    # Masking indicator should be shown (KEY in the name triggers masking)
    assert_contains "$output" "MASKED" "Should show masking indicator"
}

test_various_key_patterns_masked() {
    log_test "Testing various key naming patterns are masked"

    local test_config="$TEST_PROJECT/.kapsis-key-patterns-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - API_KEY
    - SECRET_TOKEN
    - AUTH_PASSWORD
    - PRIVATE_KEY
    - ACCESS_KEY
    - CREDENTIALS
EOF

    export API_KEY="secret1"
    export SECRET_TOKEN="secret2"
    export AUTH_PASSWORD="secret3"
    export PRIVATE_KEY="secret4"
    export ACCESS_KEY="secret5"
    export CREDENTIALS="secret6"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset API_KEY SECRET_TOKEN AUTH_PASSWORD PRIVATE_KEY ACCESS_KEY CREDENTIALS
    rm -f "$test_config"

    # All secret values should be masked
    assert_not_contains "$output" "secret1" "API_KEY value should be masked"
    assert_not_contains "$output" "secret2" "SECRET_TOKEN value should be masked"
    assert_not_contains "$output" "secret3" "AUTH_PASSWORD value should be masked"
    assert_not_contains "$output" "secret4" "PRIVATE_KEY value should be masked"
    assert_not_contains "$output" "secret5" "ACCESS_KEY value should be masked"
    assert_not_contains "$output" "secret6" "CREDENTIALS value should be masked"
}

test_empty_key_handling() {
    log_test "Testing empty auth key doesn't cause crash"

    export ANTHROPIC_API_KEY=""

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || exit_code=$?

    unset ANTHROPIC_API_KEY

    # Should complete without crashing
    assert_contains "$output" "DRY RUN" "Should complete dry-run with empty key"
}

test_unset_passthrough_not_error() {
    log_test "Testing unset passthrough variable doesn't cause error"

    local test_config="$TEST_PROJECT/.kapsis-unset-passthrough-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - THIS_VAR_IS_NOT_SET
EOF

    # Ensure variable is not set
    unset THIS_VAR_IS_NOT_SET 2>/dev/null || true

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should complete (variable just won't be passed)
    assert_contains "$output" "DRY RUN" "Should complete when passthrough var is unset"
}

test_keychain_config_structure() {
    log_test "Testing keychain config section structure is valid"

    local test_config="$TEST_PROJECT/.kapsis-keychain-structure-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    API_KEY:
      service: "my-service"
      account: "my-account"
    OAUTH_TOKEN:
      service: "oauth-service"
      inject_to_file: "~/.config/credentials.json"
      mode: "0600"
EOF

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse keychain section
    local keychain_entries
    keychain_entries=$(yq '.environment.keychain | keys | .[]' "$test_config" 2>/dev/null || echo "")

    rm -f "$test_config"

    # Should have both entries
    assert_contains "$keychain_entries" "API_KEY" "Should parse API_KEY entry"
    assert_contains "$keychain_entries" "OAUTH_TOKEN" "Should parse OAUTH_TOKEN entry"
}

test_set_vars_config_valid() {
    log_test "Testing environment.set config is valid YAML"

    local test_config="$TEST_PROJECT/.kapsis-set-vars-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  set:
    MY_PATH: "/custom/path"
    DEBUG_MODE: "true"
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Config with set variables should be processed without error
    assert_equals 0 "$exit_code" "Should process config with set variables"
    assert_contains "$output" "DRY RUN" "Should complete dry-run"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Authentication Requirements"

    # Setup
    setup_test_project

    # Run tests
    run_test test_present_auth_succeeds
    run_test test_auth_in_passthrough
    run_test test_multiple_auth_keys
    run_test test_env_priority_over_keychain
    run_test test_secrets_masked_in_output
    run_test test_various_key_patterns_masked
    run_test test_empty_key_handling
    run_test test_unset_passthrough_not_error
    run_test test_keychain_config_structure
    run_test test_set_vars_config_valid

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
