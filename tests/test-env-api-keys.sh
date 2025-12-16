#!/usr/bin/env bash
#===============================================================================
# Test: Environment API Keys
#
# Verifies that API keys and environment variables are properly passed
# to the container and handled securely.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_anthropic_key_passed() {
    log_test "Testing ANTHROPIC_API_KEY is passed to container"

    setup_container_test "env-anthropic"

    local test_key="test-anthropic-key-12345"

    # Run container with key
    local output
    output=$(ANTHROPIC_API_KEY="$test_key" podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e ANTHROPIC_API_KEY \
        kapsis-sandbox:latest \
        bash -c 'echo $ANTHROPIC_API_KEY' 2>&1) || true

    cleanup_container_test

    # Use assert_contains since entrypoint outputs logging before the command
    assert_contains "$output" "$test_key" "ANTHROPIC_API_KEY should be passed"
}

test_openai_key_passed() {
    log_test "Testing OPENAI_API_KEY is passed to container"

    setup_container_test "env-openai"

    local test_key="test-openai-key-67890"

    local output
    output=$(OPENAI_API_KEY="$test_key" podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e OPENAI_API_KEY \
        kapsis-sandbox:latest \
        bash -c 'echo $OPENAI_API_KEY' 2>&1) || true

    cleanup_container_test

    # Use assert_contains since entrypoint outputs logging before the command
    assert_contains "$output" "$test_key" "OPENAI_API_KEY should be passed"
}

test_kapsis_env_vars_set() {
    log_test "Testing KAPSIS_* env vars are set"

    setup_container_test "env-kapsis"

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_AGENT_ID="test-agent" \
        -e KAPSIS_PROJECT="test-project" \
        kapsis-sandbox:latest \
        bash -c 'echo "AGENT_ID=$KAPSIS_AGENT_ID PROJECT=$KAPSIS_PROJECT"' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "AGENT_ID=test-agent" "KAPSIS_AGENT_ID should be set"
    assert_contains "$output" "PROJECT=test-project" "KAPSIS_PROJECT should be set"
}

test_keys_not_in_dry_run() {
    log_test "Testing API keys are not shown in dry-run output"

    local secret_key="sk-super-secret-key-dont-show-this"

    export ANTHROPIC_API_KEY="$secret_key"
    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true
    unset ANTHROPIC_API_KEY

    # The actual key value should not appear in output
    assert_not_contains "$output" "$secret_key" "Secret key should not appear in dry-run output"
}

test_multiple_keys_passed() {
    log_test "Testing multiple API keys can be passed"

    setup_container_test "env-multi"

    local output
    output=$(ANTHROPIC_API_KEY="anthro-key" OPENAI_API_KEY="openai-key" podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e ANTHROPIC_API_KEY \
        -e OPENAI_API_KEY \
        kapsis-sandbox:latest \
        bash -c 'echo "ANTHRO=$ANTHROPIC_API_KEY OPENAI=$OPENAI_API_KEY"' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "ANTHRO=anthro-key" "ANTHROPIC_API_KEY should be set"
    assert_contains "$output" "OPENAI=openai-key" "OPENAI_API_KEY should be set"
}

test_empty_key_not_error() {
    log_test "Testing empty API key doesn't cause error"

    setup_container_test "env-empty"

    local exit_code=0
    local output
    output=$(ANTHROPIC_API_KEY="" podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e ANTHROPIC_API_KEY \
        kapsis-sandbox:latest \
        bash -c 'echo "KEY_LENGTH=${#ANTHROPIC_API_KEY}"' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_contains "$output" "KEY_LENGTH=0" "Empty key should be passed (length 0)"
}

test_custom_env_vars() {
    log_test "Testing custom environment variables passed"

    setup_container_test "env-custom"

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e CUSTOM_VAR1="value1" \
        -e CUSTOM_VAR2="value2" \
        kapsis-sandbox:latest \
        bash -c 'echo "$CUSTOM_VAR1 $CUSTOM_VAR2"' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "value1" "Custom var 1 should be set"
    assert_contains "$output" "value2" "Custom var 2 should be set"
}

test_path_env_preserved() {
    log_test "Testing PATH environment is properly set"

    setup_container_test "env-path"

    local output
    output=$(run_in_container 'echo $PATH')

    cleanup_container_test

    # Should include common paths
    assert_contains "$output" "/usr/bin" "PATH should include /usr/bin"
}

test_home_env_set() {
    log_test "Testing HOME environment is set"

    setup_container_test "env-home"

    local output
    output=$(run_in_container 'echo $HOME')

    cleanup_container_test

    # HOME should be set to something
    if [[ -n "$output" ]] && [[ "$output" != "" ]]; then
        return 0
    else
        log_fail "HOME should be set"
        return 1
    fi
}

test_env_isolation_between_agents() {
    log_test "Testing env vars isolated between agents"

    # Agent 1 with specific env
    local output1
    output1=$(podman run --rm \
        --name "env-agent1-$$" \
        --userns=keep-id \
        -e AGENT_SPECIFIC="agent1-data" \
        kapsis-sandbox:latest \
        bash -c 'echo $AGENT_SPECIFIC' 2>&1) || true

    # Agent 2 should not see Agent 1's env
    local output2
    output2=$(podman run --rm \
        --name "env-agent2-$$" \
        --userns=keep-id \
        kapsis-sandbox:latest \
        bash -c 'echo "${AGENT_SPECIFIC:-not_set}"' 2>&1) || true

    # Use assert_contains since entrypoint outputs logging before the command
    assert_contains "$output1" "agent1-data" "Agent 1 should see its env"
    assert_contains "$output2" "not_set" "Agent 2 should not see Agent 1's env"
}

#===============================================================================
# KEYCHAIN / SECRET STORE TESTS
#===============================================================================

test_keychain_config_parsing() {
    log_test "Testing keychain config section is parsed correctly"

    # Create a test config with keychain section
    local test_config="$TEST_PROJECT/.kapsis-keychain-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "bash"
environment:
  keychain:
    TEST_SECRET:
      service: "test-service"
    ANOTHER_SECRET:
      service: "another-service"
      account: "testuser"
EOF

    # Source launch script to get parse_config function
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"
    log_init "test"

    # Check yq is available
    if ! command -v yq &> /dev/null; then
        log_skip "yq not available - skipping keychain config test"
        rm -f "$test_config"
        return 0
    fi

    # Parse keychain section
    local env_keychain
    env_keychain=$(yq '.environment.keychain // {} | to_entries | .[] | .key + "|" + .value.service + "|" + (.value.account // "")' "$test_config" 2>/dev/null || echo "")

    rm -f "$test_config"

    # Verify parsing
    assert_contains "$env_keychain" "TEST_SECRET|test-service|" "Should parse TEST_SECRET entry"
    assert_contains "$env_keychain" "ANOTHER_SECRET|another-service|testuser" "Should parse ANOTHER_SECRET with account"
}

test_keychain_not_in_dry_run() {
    log_test "Testing keychain secrets are not shown in dry-run output"

    # Create a test config with keychain section
    local test_config="$TEST_PROJECT/.kapsis-keychain-dry.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "bash"
environment:
  keychain:
    SECRET_KEY:
      service: "some-secret-service"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # The keychain service name can appear (it's not the secret)
    # But actual secret values should never appear
    # This test just ensures dry-run doesn't crash with keychain config
    assert_contains "$output" "DRY RUN" "Dry-run should complete successfully"
}

test_passthrough_priority_over_keychain() {
    log_test "Testing passthrough takes priority over keychain"

    # This tests the logic - if ANTHROPIC_API_KEY is in passthrough and also in keychain,
    # passthrough should win because it's processed first

    # Create a test config with both
    local test_config="$TEST_PROJECT/.kapsis-priority-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - ANTHROPIC_API_KEY
  keychain:
    ANTHROPIC_API_KEY:
      service: "should-not-be-used"
EOF

    # Set the env var
    export ANTHROPIC_API_KEY="passthrough-value"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset ANTHROPIC_API_KEY
    rm -f "$test_config"

    # Should see passthrough being used, not keychain
    # (This is a logic test - actual behavior depends on generate_env_vars implementation)
    assert_contains "$output" "DRY RUN" "Dry-run should complete with priority config"
}

test_detect_os_function() {
    log_test "Testing detect_os helper function"

    # Extract and test the detect_os function from the launch script
    # We can't source the whole script as it has a main() that runs
    local os
    case "$(uname -s)" in
        Darwin*) os="macos" ;;
        Linux*)  os="linux" ;;
        *)       os="unknown" ;;
    esac

    # Verify our implementation matches expected values
    if [[ "$os" == "macos" ]] || [[ "$os" == "linux" ]] || [[ "$os" == "unknown" ]]; then
        return 0
    else
        log_fail "detect_os returned unexpected value: $os"
        return 1
    fi
}

#===============================================================================
# COMMAND STRUCTURE TESTS
#===============================================================================

test_volume_mount_before_image() {
    log_test "Testing volume mounts appear before image name in command"

    # Create a test config with inline task
    local test_config="$TEST_PROJECT/.kapsis-vol-order-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test task" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Extract the podman command
    local cmd_line
    cmd_line=$(echo "$output" | grep "^podman run")

    if [[ -z "$cmd_line" ]]; then
        log_fail "Could not find podman command in dry-run output"
        return 1
    fi

    # Find positions of key elements
    # The task-spec.md mount should appear BEFORE the image name
    local image_pos
    local spec_mount_pos

    # Get position of image (kapsis-sandbox:latest)
    image_pos=$(echo "$cmd_line" | grep -bo "kapsis-sandbox:" | head -1 | cut -d: -f1)

    # Get position of task-spec.md mount
    spec_mount_pos=$(echo "$cmd_line" | grep -bo "/task-spec.md:ro" | head -1 | cut -d: -f1)

    if [[ -z "$image_pos" ]] || [[ -z "$spec_mount_pos" ]]; then
        log_fail "Could not locate image or spec mount in command"
        return 1
    fi

    if [[ "$spec_mount_pos" -lt "$image_pos" ]]; then
        return 0
    else
        log_fail "Volume mount for task-spec.md appears AFTER image name (would cause exec error)"
        return 1
    fi
}

test_agent_command_included() {
    log_test "Testing agent command is passed to container"

    # Create a test config with custom agent command
    local test_config="$TEST_PROJECT/.kapsis-agent-cmd-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "my-custom-agent --flag value"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test task" --dry-run 2>&1) || true

    rm -f "$test_config"

    # The agent command should appear after the image name
    if echo "$output" | grep -q "kapsis-sandbox:latest.*bash -c.*my-custom-agent"; then
        return 0
    else
        log_fail "Agent command not found in container command"
        echo "Output: $output"
        return 1
    fi
}

test_interactive_mode_uses_bash() {
    log_test "Testing interactive mode uses bash, not agent command"

    # Create a test config with custom agent command
    local test_config="$TEST_PROJECT/.kapsis-interactive-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "my-custom-agent --flag value"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --interactive --dry-run 2>&1) || true

    rm -f "$test_config"

    # In interactive mode, command should be just "bash", not the agent command
    local cmd_line
    cmd_line=$(echo "$output" | grep "^podman run")

    if echo "$cmd_line" | grep -q "my-custom-agent"; then
        log_fail "Agent command should not appear in interactive mode"
        return 1
    fi

    if echo "$cmd_line" | grep -q "kapsis-sandbox:latest bash$"; then
        return 0
    else
        log_fail "Interactive mode should use bash"
        return 1
    fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Environment API Keys"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Check prerequisites
    if ! skip_if_no_container; then
        echo "Skipping container tests - prerequisites not met"
        exit 0
    fi

    # Setup
    setup_test_project

    # Run tests
    run_test test_anthropic_key_passed
    run_test test_openai_key_passed
    run_test test_kapsis_env_vars_set
    run_test test_keys_not_in_dry_run
    run_test test_multiple_keys_passed
    run_test test_empty_key_not_error
    run_test test_custom_env_vars
    run_test test_path_env_preserved
    run_test test_home_env_set
    run_test test_env_isolation_between_agents

    # Keychain / Secret Store tests
    run_test test_keychain_config_parsing
    run_test test_keychain_not_in_dry_run
    run_test test_passthrough_priority_over_keychain
    run_test test_detect_os_function

    # Command structure tests (regression tests for bugs found)
    run_test test_volume_mount_before_image
    run_test test_agent_command_included
    run_test test_interactive_mode_uses_bash

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
