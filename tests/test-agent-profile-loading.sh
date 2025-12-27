#!/usr/bin/env bash
#===============================================================================
# Test: Agent Profile Loading
#
# Verifies that agent profiles are properly loaded, resolved, and displayed.
# Tests the behavior when using --agent flag with valid and invalid profiles.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
PROFILES_DIR="$KAPSIS_ROOT/configs/agents"

#===============================================================================
# TEST CASES
#===============================================================================

test_valid_profile_loads() {
    log_test "Testing valid profile loads successfully"

    local output
    local exit_code=0

    # Use claude profile which should exist
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test task" --dry-run 2>&1) || exit_code=$?

    # Should succeed
    assert_equals 0 "$exit_code" "Should exit with zero for valid profile"

    # Should show dry-run completion
    assert_contains "$output" "DRY RUN" "Should complete dry-run with valid profile"
}

test_profile_name_displayed() {
    log_test "Testing profile name is displayed in output"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1)

    # Agent name should appear in output (case-insensitive match)
    if echo "$output" | grep -qi "claude"; then
        return 0
    else
        log_fail "Agent name 'claude' should appear in output"
        return 1
    fi
}

test_unknown_profile_errors() {
    log_test "Testing unknown profile produces error"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent nonexistent --task "test" --dry-run 2>&1) || exit_code=$?

    # Should fail
    assert_not_equals 0 "$exit_code" "Should exit with non-zero for unknown profile"

    # Should mention unknown agent
    assert_contains "$output" "Unknown agent" "Should mention unknown agent"
}

test_unknown_profile_shows_available() {
    log_test "Testing unknown profile lists available agents"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent foobar --task "test" --dry-run 2>&1) || true

    # Should list available agents
    assert_contains "$output" "claude" "Should list claude as available"
    assert_contains "$output" "aider" "Should list aider as available"
}

test_all_profiles_are_valid_yaml() {
    log_test "Testing all profile files are valid YAML"

    local failed=0

    for profile in "$PROFILES_DIR"/*.yaml; do
        [[ -f "$profile" ]] || continue
        local name
        name=$(basename "$profile")

        if ! yq '.' "$profile" >/dev/null 2>&1; then
            log_fail "Invalid YAML in profile: $name"
            ((failed++))
        fi
    done

    assert_equals 0 "$failed" "All profiles should be valid YAML"
}

test_profile_has_required_fields() {
    log_test "Testing profiles have required fields"

    local missing_fields=0

    for profile in "$PROFILES_DIR"/*.yaml; do
        [[ -f "$profile" ]] || continue
        local name
        name=$(basename "$profile")

        # Check for command field
        local command
        command=$(yq '.command // ""' "$profile")
        if [[ -z "$command" || "$command" == "null" ]]; then
            log_fail "Profile $name missing command"
            ((missing_fields++))
        fi
    done

    assert_equals 0 "$missing_fields" "All profiles should have command"
}

test_profile_shortcut_works() {
    log_test "Testing profile shortcut (--agent) works"

    local output
    local exit_code=0

    # Shortcut should work same as --agent
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with --agent shortcut"
    assert_contains "$output" "DRY RUN" "Should complete dry-run"
}

test_multiple_profiles_exist() {
    log_test "Testing multiple agent profiles exist"

    local count=0

    for profile in "$PROFILES_DIR"/*.yaml; do
        [[ -f "$profile" ]] && ((count++))
    done

    assert_true "[[ $count -ge 3 ]]" "Should have at least 3 agent profiles (claude, aider, codex)"
}

test_profile_environment_parsed() {
    log_test "Testing profile environment section is parsed"

    # Create test profile with environment
    local test_profile="$TEST_PROJECT/.kapsis-env-profile-test.yaml"
    cat > "$test_profile" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - MY_TEST_VAR
EOF

    export MY_TEST_VAR="test-value"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_profile" --task "test" --dry-run 2>&1) || exit_code=$?

    unset MY_TEST_VAR
    rm -f "$test_profile"

    # Config should be processed successfully
    assert_equals 0 "$exit_code" "Should complete with environment config"
    assert_contains "$output" "DRY RUN" "Should complete dry-run"
    # Passthrough variable should appear in podman command (non-secret vars are not masked)
    assert_contains "$output" "MY_TEST_VAR=test-value" "Passthrough var should be included"
}

test_profile_default_resolution() {
    log_test "Testing default profile resolution when --agent is empty"

    local output
    local exit_code=0

    # Empty agent should fall through to default
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent "" --task "test" --dry-run 2>&1) || exit_code=$?

    # Should succeed with default config
    assert_equals 0 "$exit_code" "Should succeed with empty agent name"
}

test_profile_config_override() {
    log_test "Testing --config overrides --agent"

    local test_config="$TEST_PROJECT/.kapsis-override-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "my-custom-agent"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Custom config command should appear (--config takes priority)
    assert_contains "$output" "my-custom-agent" "Custom config should override agent profile"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Profile Loading"

    # Setup
    setup_test_project

    # Check prerequisites
    if ! command -v yq &> /dev/null; then
        log_skip "yq not available - skipping some tests"
    fi

    # Run tests
    run_test test_valid_profile_loads
    run_test test_profile_name_displayed
    run_test test_unknown_profile_errors
    run_test test_unknown_profile_shows_available

    if command -v yq &> /dev/null; then
        run_test test_all_profiles_are_valid_yaml
        run_test test_profile_has_required_fields
        run_test test_profile_environment_parsed
    fi

    run_test test_profile_shortcut_works
    run_test test_multiple_profiles_exist
    run_test test_profile_default_resolution
    run_test test_profile_config_override

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
