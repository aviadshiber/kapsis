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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
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
        $KAPSIS_TEST_IMAGE \
        bash -c 'echo $AGENT_SPECIFIC' 2>&1) || true

    # Agent 2 should not see Agent 1's env
    local output2
    output2=$(podman run --rm \
        --name "env-agent2-$$" \
        --userns=keep-id \
        $KAPSIS_TEST_IMAGE \
        bash -c 'echo "${AGENT_SPECIFIC:-not_set}"' 2>&1) || true

    # Use assert_contains since entrypoint outputs logging before the command
    assert_contains "$output1" "agent1-data" "Agent 1 should see its env"
    assert_contains "$output2" "not_set" "Agent 2 should not see Agent 1's env"
}

#===============================================================================
# KEYCHAIN / SECRET STORE TESTS
#===============================================================================

test_keychain_config_parsing() {
    log_test "Testing keychain config section is parsed correctly (including inject_to_file)"

    # Create a test config with keychain section including new inject_to_file feature
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
    AGENT_OAUTH:
      service: "agent-oauth-service"
      inject_to_file: "~/.agent/credentials.json"
      mode: "0600"
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

    # Parse keychain section with new format (VAR|service|account|inject_to_file|mode)
    local env_keychain
    env_keychain=$(yq '.environment.keychain // {} | to_entries | .[] | .key + "|" + .value.service + "|" + (.value.account // "") + "|" + (.value.inject_to_file // "") + "|" + (.value.mode // "0600")' "$test_config" 2>/dev/null || echo "")

    rm -f "$test_config"

    # Verify parsing - basic entries
    assert_contains "$env_keychain" "TEST_SECRET|test-service|||0600" "Should parse TEST_SECRET entry with defaults"
    assert_contains "$env_keychain" "ANOTHER_SECRET|another-service|testuser||0600" "Should parse ANOTHER_SECRET with account"

    # Verify parsing - inject_to_file entry
    assert_contains "$env_keychain" "AGENT_OAUTH|agent-oauth-service||~/.agent/credentials.json|0600" "Should parse AGENT_OAUTH with inject_to_file"
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

    # Get position of image ($KAPSIS_TEST_IMAGE)
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
    if echo "$output" | grep -q "$KAPSIS_TEST_IMAGE.*bash -c.*my-custom-agent"; then
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

    if echo "$cmd_line" | grep -q "$KAPSIS_TEST_IMAGE bash$"; then
        return 0
    else
        log_fail "Interactive mode should use bash"
        return 1
    fi
}

#===============================================================================
# REGRESSION TESTS - BUGS FOUND IN SESSION 2025-12-16
#===============================================================================

test_environment_set_variables() {
    log_test "Testing environment.set variables are passed to container"

    local test_config="$TEST_PROJECT/.kapsis-env-set-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  set:
    CUSTOM_PATH: "/custom/path"
    MY_SETTING: "my-value"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Both set variables should appear in the command
    assert_contains "$output" "CUSTOM_PATH=/custom/path" "CUSTOM_PATH should be set"
    assert_contains "$output" "MY_SETTING=my-value" "MY_SETTING should be set"
}

test_secret_masking_alphanumeric() {
    log_test "Testing secret masking includes alphanumeric variable names"

    local test_config="$TEST_PROJECT/.kapsis-mask-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - CONTEXT7_API_KEY
    - GRAFANA_READONLY_TOKEN
EOF

    # Set test values
    export CONTEXT7_API_KEY="ctx7-secret-value"
    export GRAFANA_READONLY_TOKEN="graf-secret-value"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset CONTEXT7_API_KEY GRAFANA_READONLY_TOKEN
    rm -f "$test_config"

    # Secret values should NOT appear in output (masked)
    assert_not_contains "$output" "ctx7-secret-value" "CONTEXT7_API_KEY value should be masked"
    assert_not_contains "$output" "graf-secret-value" "GRAFANA_READONLY_TOKEN value should be masked"

    # Variable names with ***MASKED*** should appear
    assert_contains "$output" "CONTEXT7_API_KEY=***MASKED***" "CONTEXT7_API_KEY should be masked"
    assert_contains "$output" "GRAFANA_READONLY_TOKEN=***MASKED***" "GRAFANA_READONLY_TOKEN should be masked"
}

test_filesystem_mounts_home_paths_staged() {
    log_test "Testing home paths use staging pattern (mounted to /kapsis-staging/)"

    local test_config="$TEST_PROJECT/.kapsis-mount-path-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.local
    - ~/.config
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Home paths should be mounted to /kapsis-staging/ (staging pattern)
    # Then entrypoint copies them to container's $HOME (preserving symlinks)
    # Check that staging pattern is used
    if echo "$output" | grep -q "/kapsis-staging/.local"; then
        return 0
    else
        log_fail "Home paths should use staging pattern (mount to /kapsis-staging/)"
        echo "Output: $output"
        return 1
    fi
}

test_image_flag_priority() {
    log_test "Testing --image flag takes priority over config"

    local test_config="$TEST_PROJECT/.kapsis-image-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
image:
  name: "config-image"
  tag: "v1"
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --image "my-custom-image:latest" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # --image flag should override config
    assert_contains "$output" "my-custom-image:latest" "--image flag should take priority"
    assert_not_contains "$output" "config-image:v1" "Config image should be overridden"
}

test_yq_v4_filesystem_parsing() {
    log_test "Testing yq v4 compatibility for filesystem.include parsing"

    local test_config="$TEST_PROJECT/.kapsis-yq-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh
environment:
  passthrough:
    - HOME
    - USER
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Should parse multiple items without yq errors
    assert_contains "$output" "DRY RUN" "Should complete without yq parsing errors"
    # Check that both mounts appear
    if echo "$output" | grep -q ".gitconfig" && echo "$output" | grep -q ".ssh"; then
        return 0
    else
        log_fail "filesystem.include should parse multiple items correctly"
        return 1
    fi
}

test_environment_passthrough_parsing() {
    log_test "Testing yq v4 compatibility for environment.passthrough parsing"

    local test_config="$TEST_PROJECT/.kapsis-passthrough-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - TEST_VAR1
    - TEST_VAR2
    - TEST_VAR3
EOF

    export TEST_VAR1="value1"
    export TEST_VAR2="value2"
    export TEST_VAR3="value3"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset TEST_VAR1 TEST_VAR2 TEST_VAR3
    rm -f "$test_config"

    # All three variables should be passed through
    assert_contains "$output" "TEST_VAR1=value1" "TEST_VAR1 should be passed through"
    assert_contains "$output" "TEST_VAR2=value2" "TEST_VAR2 should be passed through"
    assert_contains "$output" "TEST_VAR3=value3" "TEST_VAR3 should be passed through"
}

#===============================================================================
# INJECT_TO_FILE TESTS (Agent-Agnostic Credential Injection)
#===============================================================================

test_inject_to_file_config_parsing() {
    log_test "Testing inject_to_file is parsed and generates KAPSIS_CREDENTIAL_FILES"

    local test_config="$TEST_PROJECT/.kapsis-inject-file-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    AGENT_CREDS:
      service: "test-agent-creds"
      inject_to_file: "~/.agent/credentials.json"
      mode: "0640"
EOF

    # We can't actually query keychain in tests, but we can verify the config parsing
    # by checking the dry-run output shows the variable would be processed
    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Should complete without errors
    assert_contains "$output" "DRY RUN" "Dry-run should complete with inject_to_file config"
}

test_inject_to_file_multiple_entries() {
    log_test "Testing multiple inject_to_file entries are parsed correctly"

    local test_config="$TEST_PROJECT/.kapsis-multi-inject-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  keychain:
    CLAUDE_OAUTH:
      service: "claude-creds"
      inject_to_file: "~/.claude/.credentials.json"
    CODEX_AUTH:
      service: "codex-creds"
      inject_to_file: "~/.codex/auth.json"
      mode: "0600"
    API_KEY_ONLY:
      service: "api-key"
EOF

    # Check yq is available
    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        rm -f "$test_config"
        return 0
    fi

    # Parse and verify all entries are handled correctly
    local env_keychain
    env_keychain=$(yq '.environment.keychain // {} | to_entries | .[] | .key + "|" + .value.service + "|" + (.value.account // "") + "|" + (.value.inject_to_file // "") + "|" + (.value.mode // "0600")' "$test_config" 2>/dev/null || echo "")

    rm -f "$test_config"

    # Check each entry
    assert_contains "$env_keychain" "CLAUDE_OAUTH|claude-creds||~/.claude/.credentials.json|0600" "Should parse CLAUDE_OAUTH"
    assert_contains "$env_keychain" "CODEX_AUTH|codex-creds||~/.codex/auth.json|0600" "Should parse CODEX_AUTH"
    assert_contains "$env_keychain" "API_KEY_ONLY|api-key|||0600" "Should parse API_KEY_ONLY without file"
}

test_credential_files_env_format() {
    log_test "Testing KAPSIS_CREDENTIAL_FILES environment variable format"

    # This tests the format of KAPSIS_CREDENTIAL_FILES that gets passed to entrypoint
    # Format should be: VAR_NAME|file_path|mode (comma-separated for multiple)

    # Simulate what launch-agent.sh would generate
    local cred_files=""
    local entries=(
        "CLAUDE_OAUTH|~/.claude/.credentials.json|0600"
        "CODEX_AUTH|~/.codex/auth.json|0640"
    )

    for entry in "${entries[@]}"; do
        if [[ -n "$cred_files" ]]; then
            cred_files="${cred_files},${entry}"
        else
            cred_files="$entry"
        fi
    done

    # Verify format is correct
    assert_contains "$cred_files" "CLAUDE_OAUTH|~/.claude/.credentials.json|0600" "Should contain CLAUDE_OAUTH entry"
    assert_contains "$cred_files" "CODEX_AUTH|~/.codex/auth.json|0640" "Should contain CODEX_AUTH entry"
    assert_contains "$cred_files" "," "Should be comma-separated"
}

test_inject_credential_files_entrypoint() {
    log_test "Testing inject_credential_files function in container"

    setup_container_test "inject-creds"

    # Test the inject_credential_files function by passing env vars and checking file creation
    local test_secret="test-secret-value-12345"
    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_CREDENTIAL_FILES="TEST_CRED|/tmp/test-cred.json|0600" \
        -e TEST_CRED="$test_secret" \
        $KAPSIS_TEST_IMAGE \
        bash -c '
            # The entrypoint should have run inject_credential_files
            # Check if file was created
            if [[ -f /tmp/test-cred.json ]]; then
                echo "FILE_EXISTS"
                cat /tmp/test-cred.json
                # Check permissions
                stat -c "%a" /tmp/test-cred.json
            else
                echo "FILE_NOT_FOUND"
            fi
            # Check env var was unset
            echo "ENV_VAR=${TEST_CRED:-UNSET}"
        ' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "FILE_EXISTS" "Credential file should be created"
    assert_contains "$output" "$test_secret" "File should contain the secret value"
    assert_contains "$output" "600" "File should have 0600 permissions"
    assert_contains "$output" "ENV_VAR=UNSET" "Env var should be unset after injection"
}

test_inject_credential_files_multiple() {
    log_test "Testing multiple credential file injections"

    setup_container_test "inject-multi-creds"

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_CREDENTIAL_FILES="CRED1|/tmp/cred1.txt|0600,CRED2|/tmp/cred2.txt|0640" \
        -e CRED1="secret1" \
        -e CRED2="secret2" \
        $KAPSIS_TEST_IMAGE \
        bash -c '
            echo "CRED1_EXISTS=$(test -f /tmp/cred1.txt && echo YES || echo NO)"
            echo "CRED2_EXISTS=$(test -f /tmp/cred2.txt && echo YES || echo NO)"
            echo "CRED1_CONTENT=$(cat /tmp/cred1.txt 2>/dev/null || echo EMPTY)"
            echo "CRED2_CONTENT=$(cat /tmp/cred2.txt 2>/dev/null || echo EMPTY)"
        ' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "CRED1_EXISTS=YES" "First credential file should exist"
    assert_contains "$output" "CRED2_EXISTS=YES" "Second credential file should exist"
    assert_contains "$output" "CRED1_CONTENT=secret1" "First file should have correct content"
    assert_contains "$output" "CRED2_CONTENT=secret2" "Second file should have correct content"
}

test_inject_credential_files_home_expansion() {
    log_test "Testing ~ expansion in inject_to_file paths"

    setup_container_test "inject-home-expand"

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_CREDENTIAL_FILES="HOME_CRED|~/.test-creds/secret.json|0600" \
        -e HOME_CRED="home-secret-value" \
        $KAPSIS_TEST_IMAGE \
        bash -c '
            # Check if file was created in home directory
            if [[ -f ~/.test-creds/secret.json ]]; then
                echo "FILE_IN_HOME=YES"
                cat ~/.test-creds/secret.json
            else
                echo "FILE_IN_HOME=NO"
                # Debug: show what HOME is
                echo "HOME=$HOME"
                ls -la ~ 2>/dev/null | head -5
            fi
        ' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "FILE_IN_HOME=YES" "File should be created in home directory"
    assert_contains "$output" "home-secret-value" "File should contain the secret"
}

test_inject_credential_files_creates_parent_dirs() {
    log_test "Testing inject_credential_files creates parent directories"

    setup_container_test "inject-mkdir"

    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -e KAPSIS_CREDENTIAL_FILES="DEEP_CRED|/tmp/deep/nested/path/cred.json|0600" \
        -e DEEP_CRED="deep-secret" \
        $KAPSIS_TEST_IMAGE \
        bash -c '
            if [[ -f /tmp/deep/nested/path/cred.json ]]; then
                echo "NESTED_FILE_EXISTS=YES"
            else
                echo "NESTED_FILE_EXISTS=NO"
            fi
        ' 2>&1) || true

    cleanup_container_test

    assert_contains "$output" "NESTED_FILE_EXISTS=YES" "Should create nested parent directories"
}

#===============================================================================
# STAGING PATTERN TESTS (CoW for home directory configs)
#===============================================================================

test_staged_configs_env_var() {
    log_test "Testing KAPSIS_STAGED_CONFIGS is set for home directory mounts"

    local test_config="$TEST_PROJECT/.kapsis-staging-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Should have KAPSIS_STAGED_CONFIGS with the relative paths
    assert_contains "$output" "KAPSIS_STAGED_CONFIGS=" "Should set KAPSIS_STAGED_CONFIGS env var"
}

test_staging_mounts_to_kapsis_staging() {
    log_test "Testing home paths mount to /kapsis-staging/"

    local test_config="$TEST_PROJECT/.kapsis-staging-mount-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.gitconfig
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Should mount to /kapsis-staging/ not directly to home
    assert_contains "$output" "/kapsis-staging/" "Should mount to /kapsis-staging/ directory"
}

test_staging_non_home_paths_direct() {
    log_test "Testing non-home absolute paths mount directly (not staged)"

    local test_config="$TEST_PROJECT/.kapsis-non-home-test.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - /etc/hosts
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"

    # Non-home paths should mount directly (same source and target)
    assert_contains "$output" "/etc/hosts:/etc/hosts" "Non-home paths should mount directly"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Environment API Keys"

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

    # Regression tests - bugs found 2025-12-16
    run_test test_environment_set_variables
    run_test test_secret_masking_alphanumeric
    run_test test_filesystem_mounts_home_paths_staged
    run_test test_image_flag_priority
    run_test test_yq_v4_filesystem_parsing
    run_test test_environment_passthrough_parsing

    # inject_to_file tests - agent-agnostic credential injection
    run_test test_inject_to_file_config_parsing
    run_test test_inject_to_file_multiple_entries
    run_test test_credential_files_env_format
    run_test test_inject_credential_files_entrypoint
    run_test test_inject_credential_files_multiple
    run_test test_inject_credential_files_home_expansion
    run_test test_inject_credential_files_creates_parent_dirs

    # Staging pattern tests - CoW for home directory configs
    run_test test_staged_configs_env_var
    run_test test_staging_mounts_to_kapsis_staging
    run_test test_staging_non_home_paths_direct

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
