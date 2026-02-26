#!/usr/bin/env bash
#===============================================================================
# Test: K8s Config Translation
#
# Verifies that the K8s config translator correctly converts
# launch-agent.sh internal variables into AgentRequest CR YAML.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# HELPERS
#===============================================================================

# Source the translator in a subshell with minimal globals set
_run_translator() {
    bash -c '
        source "'"$KAPSIS_ROOT"'/scripts/lib/constants.sh"
        source "'"$KAPSIS_ROOT"'/scripts/lib/logging.sh" 2>/dev/null || true
        init_logging "test" 2>/dev/null || true
        source "'"$KAPSIS_ROOT"'/scripts/lib/k8s-config.sh"
        '"$1"'
    '
}

#===============================================================================
# TEST CASES
#===============================================================================

test_translate_memory_8g() {
    log_test "Testing memory translation: 8g -> 8Gi"

    local result
    result=$(_run_translator 'echo $(translate_memory_to_k8s "8g")')

    assert_equals "8Gi" "$result" "8g should become 8Gi"
}

test_translate_memory_512m() {
    log_test "Testing memory translation: 512m -> 512Mi"

    local result
    result=$(_run_translator 'echo $(translate_memory_to_k8s "512m")')

    assert_equals "512Mi" "$result" "512m should become 512Mi"
}

test_translate_memory_already_k8s() {
    log_test "Testing memory translation: already K8s format passes through"

    local result
    result=$(_run_translator 'echo $(translate_memory_to_k8s "4Gi")')

    assert_equals "4Gi" "$result" "4Gi should pass through unchanged"
}

test_translate_cpus() {
    log_test "Testing CPU translation"

    local result
    result=$(_run_translator 'echo $(translate_cpus_to_k8s "4")')

    assert_equals "4" "$result" "CPU count should pass through"
}

test_generate_env_yaml_single() {
    log_test "Testing env var YAML generation"

    local result
    result=$(_run_translator '
        declare -a TEST_VARS=("FOO=bar")
        generate_env_yaml TEST_VARS
    ')

    assert_contains "$result" "name: FOO" "Should contain env var name"
    assert_contains "$result" "value: \"bar\"" "Should contain env var value"
}

test_generate_env_yaml_multiple() {
    log_test "Testing multiple env vars YAML generation"

    local result
    result=$(_run_translator '
        declare -a TEST_VARS=("FOO=bar" "BAZ=qux")
        generate_env_yaml TEST_VARS
    ')

    assert_contains "$result" "name: FOO" "Should contain first env var"
    assert_contains "$result" "name: BAZ" "Should contain second env var"
}

test_generate_cr_contains_apiversion() {
    log_test "Testing generated CR contains apiVersion"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "apiVersion: kapsis.io/v1alpha1" "Should contain apiVersion"
}

test_generate_cr_contains_kind() {
    log_test "Testing generated CR contains kind"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "kind: AgentRequest" "Should contain kind"
}

test_generate_cr_contains_image() {
    log_test "Testing generated CR contains image"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-claude-cli:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "image: kapsis-claude-cli:latest" "Should contain image"
}

test_generate_cr_contains_resources() {
    log_test "Testing generated CR contains translated resources"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "memory: \"8Gi\"" "Should contain translated memory"
    assert_contains "$result" "cpu: \"4\"" "Should contain CPU"
}

test_generate_cr_valid_yaml() {
    log_test "Testing generated CR is valid YAML"

    local cr_output
    cr_output=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    local tmpfile
    tmpfile=$(mktemp)
    echo "$cr_output" > "$tmpfile"
    local exit_code=0
    yq eval '.' "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    rm -f "$tmpfile"

    assert_equals 0 "$exit_code" "Generated CR should be valid YAML"
}

test_generate_cr_with_branch() {
    log_test "Testing generated CR includes git section when branch set"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH="feature/my-branch"
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "branch: feature/my-branch" "Should contain branch"
}

test_generate_cr_with_task_inline() {
    log_test "Testing generated CR includes inline task"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="implement login feature"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        generate_agent_request_cr
    ')

    assert_contains "$result" "inline:" "Should have inline task"
    assert_contains "$result" "implement login feature" "Should contain task text"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "K8s Config Translation"

    run_test test_translate_memory_8g
    run_test test_translate_memory_512m
    run_test test_translate_memory_already_k8s
    run_test test_translate_cpus
    run_test test_generate_env_yaml_single
    run_test test_generate_env_yaml_multiple
    run_test test_generate_cr_contains_apiversion
    run_test test_generate_cr_contains_kind
    run_test test_generate_cr_contains_image
    run_test test_generate_cr_contains_resources
    run_test test_generate_cr_valid_yaml
    run_test test_generate_cr_with_branch
    run_test test_generate_cr_with_task_inline

    print_summary
}

main "$@"
