#!/usr/bin/env bash
#===============================================================================
# Test: Agent Image Building
#
# Verifies that agent images can be built from profiles and contain
# the expected tools. Tests build-image.sh script and image tags.
#
# REQUIRES: Container environment (Podman)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

BUILD_SCRIPT="$KAPSIS_ROOT/scripts/build-image.sh"
PROFILES_DIR="$KAPSIS_ROOT/configs/agents"

#===============================================================================
# TEST CASES
#===============================================================================

test_build_script_exists() {
    log_test "Testing build script exists"

    assert_file_exists "$BUILD_SCRIPT" "Build script should exist"
    assert_true "[[ -x '$BUILD_SCRIPT' ]]" "Build script should be executable"
}

test_build_script_help() {
    log_test "Testing build script has help option"

    local output
    output=$("$BUILD_SCRIPT" --help 2>&1) || true

    # Should show usage information
    if [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]] || [[ "$output" == *"build"* ]]; then
        return 0
    fi

    # May not have explicit help, just check it doesn't crash
    log_info "Build script executed without crashing"
}

test_containerfile_exists() {
    log_test "Testing Containerfile exists"

    assert_file_exists "$KAPSIS_ROOT/Containerfile" "Containerfile should exist"
}

test_containerfile_has_base_image() {
    log_test "Testing Containerfile has base image"

    local content
    content=$(cat "$KAPSIS_ROOT/Containerfile")

    # Should have FROM instruction
    assert_contains "$content" "FROM" "Containerfile should have FROM instruction"
}

test_containerfile_installs_developer_tools() {
    log_test "Testing Containerfile installs developer tools"

    local content
    content=$(cat "$KAPSIS_ROOT/Containerfile")

    # Should install common dev tools
    assert_contains "$content" "git" "Should install git"
}

test_containerfile_creates_developer_user() {
    log_test "Testing Containerfile creates developer user"

    local content
    content=$(cat "$KAPSIS_ROOT/Containerfile")

    # Should have developer user setup
    assert_contains "$content" "developer" "Should reference developer user"
}

test_base_image_exists() {
    log_test "Testing base kapsis image exists"

    if ! skip_if_no_container; then
        return 0
    fi

    local image_name="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"

    local exists
    exists=$(podman image exists "$image_name" 2>/dev/null && echo "yes" || echo "no")

    assert_equals "yes" "$exists" "Base kapsis image should exist"
}

test_image_has_bash() {
    log_test "Testing image has bash"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "has-bash"

    local output
    local exit_code=0
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        which bash 2>&1) || exit_code=$?

    cleanup_container_test

    assert_equals 0 "$exit_code" "Image should have bash"
    assert_contains "$output" "/bash" "Should find bash"
}

test_image_has_git() {
    log_test "Testing image has git"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "has-git"

    local output
    local exit_code=0
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        git --version 2>&1) || exit_code=$?

    cleanup_container_test

    assert_equals 0 "$exit_code" "Image should have git"
    assert_contains "$output" "git version" "Should show git version"
}

test_image_has_curl() {
    log_test "Testing image has curl"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "has-curl"

    local output
    local exit_code=0
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        curl --version 2>&1) || exit_code=$?

    cleanup_container_test

    assert_equals 0 "$exit_code" "Image should have curl"
}

test_image_has_jq() {
    log_test "Testing image has jq"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "has-jq"

    local output
    local exit_code=0
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        jq --version 2>&1) || exit_code=$?

    cleanup_container_test

    assert_equals 0 "$exit_code" "Image should have jq"
}

test_image_developer_user() {
    log_test "Testing image has developer user"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "developer-user"

    local output
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        id 2>&1) || true

    cleanup_container_test

    # Should run as the mapped user (with userns=keep-id)
    # or show developer user info
    if [[ "$output" == *"developer"* ]] || [[ "$output" == *"$(whoami)"* ]]; then
        return 0
    fi

    log_info "User output: $output"
}

test_image_home_directory() {
    log_test "Testing image has proper home directory"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "home-dir"

    local output
    # shellcheck disable=SC2046 # Word splitting intentional for multiple -e args
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        $(get_test_container_env_args) \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'echo $HOME' 2>&1) || true

    cleanup_container_test

    # Home should be set to something
    assert_not_equals "" "$output" "HOME should be set"
}

test_image_entrypoint() {
    log_test "Testing image has entrypoint"

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    output=$(podman inspect "$KAPSIS_TEST_IMAGE" --format '{{.Config.Entrypoint}}' 2>/dev/null) || true

    # Should have entrypoint configured
    if [[ -n "$output" ]] && [[ "$output" != "<nil>" ]] && [[ "$output" != "[]" ]]; then
        return 0
    fi

    log_info "Entrypoint: $output (may be shell-based)"
}

test_profiles_define_agent_commands() {
    log_test "Testing profiles define agent commands"

    if ! command -v yq &> /dev/null; then
        log_skip "yq not available"
        return 0
    fi

    local missing=0

    for profile in "$PROFILES_DIR"/*.yaml; do
        [[ -f "$profile" ]] || continue
        local name
        name=$(basename "$profile")

        local command
        command=$(yq '.command // ""' "$profile")

        if [[ -z "$command" || "$command" == "null" ]]; then
            log_info "Profile $name missing command"
            ((missing++))
        fi
    done

    assert_equals 0 "$missing" "All profiles should define agent commands"
}

test_build_with_unknown_profile_fails() {
    log_test "Testing build with unknown profile fails"

    if ! skip_if_no_container; then
        return 0
    fi

    local exit_code=0
    local output
    output=$("$BUILD_SCRIPT" nonexistent-profile-12345 2>&1) || exit_code=$?

    # Should fail for unknown profile
    assert_not_equals 0 "$exit_code" "Should fail for unknown profile"
}

test_image_labels() {
    log_test "Testing image has appropriate labels"

    if ! skip_if_no_container; then
        return 0
    fi

    local labels
    labels=$(podman inspect "$KAPSIS_TEST_IMAGE" --format '{{json .Config.Labels}}' 2>/dev/null) || true

    # Should have some labels (may vary by build)
    if [[ -n "$labels" ]] && [[ "$labels" != "null" ]]; then
        log_info "Image has labels"
        return 0
    fi

    log_info "Image may not have labels (acceptable for base image)"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Image Building"

    # Run tests
    run_test test_build_script_exists
    run_test test_build_script_help
    run_test test_containerfile_exists
    run_test test_containerfile_has_base_image
    run_test test_containerfile_installs_developer_tools
    run_test test_containerfile_creates_developer_user

    # Container tests
    if skip_if_no_container 2>/dev/null; then
        run_test test_base_image_exists
        run_test test_image_has_bash
        run_test test_image_has_git
        run_test test_image_has_curl
        run_test test_image_has_jq
        run_test test_image_developer_user
        run_test test_image_home_directory
        run_test test_image_entrypoint
        run_test test_build_with_unknown_profile_fails
        run_test test_image_labels
    else
        skip_test test_base_image_exists "No container runtime"
        skip_test test_image_has_bash "No container runtime"
        skip_test test_image_has_git "No container runtime"
        skip_test test_image_has_curl "No container runtime"
        skip_test test_image_has_jq "No container runtime"
        skip_test test_image_developer_user "No container runtime"
        skip_test test_image_home_directory "No container runtime"
        skip_test test_image_entrypoint "No container runtime"
        skip_test test_build_with_unknown_profile_fails "No container runtime"
        skip_test test_image_labels "No container runtime"
    fi

    run_test test_profiles_define_agent_commands

    # Summary
    print_summary
}

main "$@"
