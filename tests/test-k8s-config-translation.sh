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

    assert_contains "$result" "apiVersion: kapsis.aviadshiber.github.io/v1alpha1" "Should contain apiVersion"
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
    if skip_if_not_mikefarah_yq 2>/dev/null; then
        yq eval '.' "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    else
        python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    fi
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

    assert_contains "$result" 'branch: "feature/my-branch"' "Should contain branch"
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
# EDGE CASE / NEGATIVE TESTS
#===============================================================================

test_translate_memory_empty_string() {
    log_test "Testing memory translation: empty string passes through"

    local result
    result=$(_run_translator 'echo $(translate_memory_to_k8s "")')

    assert_equals "" "$result" "Empty string should pass through"
}

test_translate_memory_uppercase() {
    log_test "Testing memory translation: uppercase G/M handled"

    local result
    result=$(_run_translator 'echo $(translate_memory_to_k8s "8G")')
    assert_equals "8Gi" "$result" "8G should become 8Gi"

    result=$(_run_translator 'echo $(translate_memory_to_k8s "512M")')
    assert_equals "512Mi" "$result" "512M should become 512Mi"
}

test_generate_cr_special_chars_valid_yaml() {
    log_test "Testing CR with special characters produces valid YAML"

    local cr_output
    cr_output=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE="implement \"login\" feature: with {special} chars"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task \"hello: world\" && echo done"
        generate_agent_request_cr
    ')

    local tmpfile
    tmpfile=$(mktemp)
    echo "$cr_output" > "$tmpfile"
    local exit_code=0
    if skip_if_not_mikefarah_yq 2>/dev/null; then
        yq eval '.' "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    else
        python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    fi
    rm -f "$tmpfile"

    assert_equals 0 "$exit_code" "CR with special characters should be valid YAML"
}

test_yaml_escape_newline_tab() {
    log_test "Testing _yaml_escape handles newline and tab"

    local result
    result=$(_run_translator '
        printf "%s" "$(_yaml_escape "line1
line2")"
    ')

    assert_contains "$result" '\n' "Should escape newline to \\n"
    # Verify no literal newline in the output (should be single line)
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')
    assert_equals 1 "$line_count" "Should be a single line (no literal newlines)"
}

test_yaml_escape_tab() {
    log_test "Testing _yaml_escape handles tab character"

    local result
    result=$(_run_translator "printf '%s' \"\$(_yaml_escape \$'hello\\tworld')\"")

    assert_contains "$result" '\t' "Should escape tab to \\t"
}

test_yaml_escape_echo_flag_values() {
    log_test "Testing _yaml_escape handles values starting with -n, -e, -E"

    local result_n result_e result_E

    # Values starting with -n, -e, -E could be misinterpreted by echo
    result_n=$(_run_translator "printf '%s' \"\$(_yaml_escape '-nfoo')\"")
    result_e=$(_run_translator "printf '%s' \"\$(_yaml_escape '-efoo')\"")
    result_E=$(_run_translator "printf '%s' \"\$(_yaml_escape '-Efoo')\"")

    assert_equals "-nfoo" "$result_n" "Should preserve -n prefix (not interpret as echo flag)"
    assert_equals "-efoo" "$result_e" "Should preserve -e prefix (not interpret as echo flag)"
    assert_equals "-Efoo" "$result_E" "Should preserve -E prefix (not interpret as echo flag)"
}

test_generate_cr_branch_special_chars_valid_yaml() {
    log_test "Testing CR with special branch name produces valid YAML"

    local cr_output
    cr_output=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH="feat/my-branch:with-colon"
        GIT_REMOTE_URL="https://github.com/user/repo.git"
        BASE_BRANCH="main"
        DO_PUSH="true"
        TASK_INLINE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND=""
        generate_agent_request_cr
    ')

    local tmpfile
    tmpfile=$(mktemp)
    echo "$cr_output" > "$tmpfile"
    local exit_code=0
    if skip_if_not_mikefarah_yq 2>/dev/null; then
        yq eval '.' "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    else
        python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$tmpfile" > /dev/null 2>&1 || exit_code=$?
    fi
    rm -f "$tmpfile"

    assert_equals 0 "$exit_code" "CR with special branch chars should be valid YAML"
    assert_contains "$cr_output" 'feat/my-branch:with-colon' "Should contain branch name"
}

test_generate_env_yaml_cr_integration() {
    log_test "Testing generate_env_yaml wired into CR generation"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH=""
        TASK_INLINE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND=""
        declare -a MY_EXTRA_ENV=("CUSTOM_KEY=custom_value" "ANOTHER=test")
        generate_agent_request_cr MY_EXTRA_ENV
    ')

    assert_contains "$result" "CUSTOM_KEY" "Should contain extra env var name"
    assert_contains "$result" "custom_value" "Should contain extra env var value"
    assert_contains "$result" "ANOTHER" "Should contain second extra env var"
}

test_generate_cr_contains_status_env_vars() {
    log_test "Testing generated CR contains status and gist env vars"

    local result
    result=$(_run_translator '
        AGENT_ID="test123"
        IMAGE_NAME="kapsis-sandbox:latest"
        AGENT_NAME="claude-cli"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        BRANCH="feature/test"
        TASK_INLINE="test task"
        INLINE_SPEC_FILE=""
        NETWORK_MODE="filtered"
        SECURITY_PROFILE="standard"
        AGENT_COMMAND="claude --task test"
        KAPSIS_STATUS_PROJECT="my-project"
        INJECT_GIST="true"
        generate_agent_request_cr
    ')

    assert_contains "$result" "KAPSIS_STATUS_PROJECT" "Should contain KAPSIS_STATUS_PROJECT"
    assert_contains "$result" "my-project" "Should contain project name value"
    # KAPSIS_STATUS_AGENT_ID and KAPSIS_STATUS_BRANCH removed: they duplicated operator-injected
    # KAPSIS_AGENT_ID and KAPSIS_BRANCH respectively. The operator already injects those last.
    assert_contains "$result" "KAPSIS_INJECT_GIST" "Should contain KAPSIS_INJECT_GIST"
}

test_generate_cr_empty_globals_does_not_crash() {
    log_test "Testing CR generation with empty globals does not crash"

    local exit_code=0
    _run_translator '
        AGENT_ID=""
        IMAGE_NAME=""
        AGENT_NAME=""
        RESOURCE_MEMORY=""
        RESOURCE_CPUS=""
        BRANCH=""
        TASK_INLINE=""
        NETWORK_MODE=""
        SECURITY_PROFILE=""
        AGENT_COMMAND=""
        generate_agent_request_cr
    ' > /dev/null 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should not crash with empty globals"
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
    run_test test_translate_memory_empty_string
    run_test test_translate_memory_uppercase
    run_test test_generate_cr_special_chars_valid_yaml
    run_test test_generate_cr_contains_status_env_vars
    run_test test_generate_cr_empty_globals_does_not_crash
    run_test test_yaml_escape_newline_tab
    run_test test_yaml_escape_tab
    run_test test_yaml_escape_echo_flag_values
    run_test test_generate_cr_branch_special_chars_valid_yaml
    run_test test_generate_env_yaml_cr_integration

    print_summary
}

main "$@"
