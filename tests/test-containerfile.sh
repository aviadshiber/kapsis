#!/usr/bin/env bash
#===============================================================================
# Test: Containerfile Configuration
#
# Verifies that the Containerfile contains correct configurations including:
# - SDKMAN offline mode configuration
# - Java version installation
# - Build tool installation
# - Environment configuration
#
# These tests validate the Containerfile syntax and structure without
# requiring a full image build.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CONTAINERFILE="$KAPSIS_ROOT/Containerfile"

#===============================================================================
# TEST CASES: SDKMAN Offline Mode Configuration
#===============================================================================

test_sdkman_offline_mode_block_exists() {
    log_test "Testing SDKMAN offline mode configuration block exists"

    assert_file_exists "$CONTAINERFILE" "Containerfile should exist"

    local content
    content=$(cat "$CONTAINERFILE")

    # The block should configure SDKMAN for offline mode
    assert_contains "$content" "sdkman_offline_mode=true" \
        "Containerfile should configure SDKMAN offline mode"
}

test_sdkman_auto_answer_configured() {
    log_test "Testing SDKMAN auto_answer is set to true"

    local content
    content=$(cat "$CONTAINERFILE")

    # Should change sdkman_auto_answer from false to true
    assert_contains "$content" "s/sdkman_auto_answer=false/sdkman_auto_answer=true/" \
        "Containerfile should set sdkman_auto_answer=true"
}

test_sdkman_auto_update_disabled() {
    log_test "Testing SDKMAN auto_update is disabled"

    local content
    content=$(cat "$CONTAINERFILE")

    # Should change sdkman_auto_update from true to false
    assert_contains "$content" "s/sdkman_auto_update=true/sdkman_auto_update=false/" \
        "Containerfile should disable sdkman_auto_update"
}

test_sdkman_config_conditional_on_java_enabled() {
    log_test "Testing SDKMAN config is conditional on ENABLE_JAVA"

    local content
    content=$(cat "$CONTAINERFILE")

    # The SDKMAN config block should check ENABLE_JAVA
    # Look for the pattern that has both the condition and the offline mode setting
    if echo "$content" | grep -q 'ENABLE_JAVA.*=.*"true".*sdkman_offline_mode'; then
        return 0
    fi

    # Alternative: check if the RUN block before sdkman_offline_mode contains ENABLE_JAVA check
    # Extract the block containing sdkman_offline_mode and check for ENABLE_JAVA condition
    local block
    block=$(echo "$content" | grep -B5 "sdkman_offline_mode=true")

    assert_contains "$block" 'ENABLE_JAVA' \
        "SDKMAN offline mode should be conditional on ENABLE_JAVA"
}

test_sdkman_config_checks_file_exists() {
    log_test "Testing SDKMAN config block checks config file exists"

    local content
    content=$(cat "$CONTAINERFILE")

    # Should check if the config file exists before modifying
    # Look for pattern near the sdkman_offline_mode setting
    local block
    block=$(echo "$content" | grep -B5 "sdkman_offline_mode=true")

    assert_contains "$block" 'SDKMAN_DIR/etc/config' \
        "SDKMAN config block should check for config file existence"
}

test_sdkman_config_uses_sed_in_place() {
    log_test "Testing SDKMAN config uses sed -i for in-place editing"

    local content
    content=$(cat "$CONTAINERFILE")

    # Should use sed -i for in-place editing
    assert_contains "$content" "sed -i 's/sdkman_auto_answer" \
        "Should use sed -i for sdkman_auto_answer"
    assert_contains "$content" "sed -i 's/sdkman_auto_update" \
        "Should use sed -i for sdkman_auto_update"
}

test_sdkman_offline_mode_appended() {
    log_test "Testing SDKMAN offline mode is appended (not sed replaced)"

    local content
    content=$(cat "$CONTAINERFILE")

    # The offline mode should be appended with echo, not sed replaced
    # (because it doesn't exist in the default config)
    assert_contains "$content" "echo 'sdkman_offline_mode=true'" \
        "SDKMAN offline mode should be appended with echo"
}

test_sdkman_config_block_order() {
    log_test "Testing SDKMAN config block comes after Maven installation"

    local content
    content=$(cat "$CONTAINERFILE")

    # Find line numbers for Maven installation and SDKMAN config
    local maven_line
    local config_line

    maven_line=$(echo "$content" | grep -n "sdk install maven" | head -1 | cut -d: -f1)
    config_line=$(echo "$content" | grep -n "sdkman_offline_mode=true" | head -1 | cut -d: -f1)

    if [[ -z "$maven_line" ]] || [[ -z "$config_line" ]]; then
        log_fail "Could not find Maven installation or SDKMAN config lines"
        return 1
    fi

    if [[ "$config_line" -gt "$maven_line" ]]; then
        return 0
    else
        log_fail "SDKMAN config should come after Maven installation"
        log_info "Maven line: $maven_line, Config line: $config_line"
        return 1
    fi
}

test_sdkman_config_comment_exists() {
    log_test "Testing SDKMAN config block has explanatory comment"

    local content
    content=$(cat "$CONTAINERFILE")

    # Should have a comment explaining why offline mode is configured
    # Look for comment near the offline mode setting
    local block
    block=$(echo "$content" | grep -B10 "sdkman_offline_mode=true")

    if echo "$block" | grep -qi "offline"; then
        return 0
    fi

    log_info "Consider adding a comment explaining SDKMAN offline mode"
    # This is a soft check - don't fail if comment is missing
    return 0
}

#===============================================================================
# TEST CASES: Container Integration (requires Podman)
#===============================================================================

test_sdkman_config_in_built_image() {
    log_test "Testing SDKMAN config settings in built image"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "sdkman-config"

    local output
    output=$(run_named_container "$CONTAINER_TEST_ID" \
        "cat /opt/sdkman/etc/config 2>/dev/null || echo 'CONFIG_NOT_FOUND'") || true

    cleanup_container_test

    # If SDKMAN is not installed (minimal profile), skip
    if [[ "$output" == "CONFIG_NOT_FOUND" ]]; then
        log_info "SDKMAN not installed in this image (minimal profile?)"
        return 0
    fi

    # Check all three settings
    assert_contains "$output" "sdkman_auto_answer=true" \
        "SDKMAN config should have auto_answer=true"
    assert_contains "$output" "sdkman_auto_update=false" \
        "SDKMAN config should have auto_update=false"
    assert_contains "$output" "sdkman_offline_mode=true" \
        "SDKMAN config should have offline_mode=true"
}

test_sdkman_no_network_warning() {
    log_test "Testing SDKMAN commands don't show network warnings"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "sdkman-no-warn"

    local output
    output=$(run_named_container "$CONTAINER_TEST_ID" \
        "source /opt/sdkman/bin/sdkman-init.sh 2>/dev/null && sdk current java 2>&1 || echo 'SDK_NOT_AVAILABLE'") || true

    cleanup_container_test

    # If SDKMAN is not installed, skip
    if [[ "$output" == "SDK_NOT_AVAILABLE" ]]; then
        log_info "SDKMAN not installed in this image"
        return 0
    fi

    # Should NOT contain network unreachable warning
    assert_not_contains "$output" "INTERNET NOT REACHABLE" \
        "SDKMAN should not show network warning with offline mode"
}

test_java_available_in_image() {
    log_test "Testing Java is available in built image"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "java-avail"

    local output
    local exit_code=0
    output=$(run_named_container "$CONTAINER_TEST_ID" \
        "java -version 2>&1 || echo 'JAVA_NOT_FOUND'") || exit_code=$?

    cleanup_container_test

    # If Java is not installed (minimal profile), skip
    if [[ "$output" == "JAVA_NOT_FOUND" ]]; then
        log_info "Java not installed in this image (minimal profile?)"
        return 0
    fi

    # Should have Java available
    assert_contains "$output" "version" \
        "Java should be available and show version"
}

test_maven_available_in_image() {
    log_test "Testing Maven is available in built image"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "maven-avail"

    local output
    output=$(run_named_container "$CONTAINER_TEST_ID" \
        "mvn --version 2>&1 || echo 'MAVEN_NOT_FOUND'") || true

    cleanup_container_test

    # If Maven is not installed (minimal profile), skip
    if [[ "$output" == "MAVEN_NOT_FOUND" ]]; then
        log_info "Maven not installed in this image (minimal profile?)"
        return 0
    fi

    # Should have Maven available
    assert_contains "$output" "Apache Maven" \
        "Maven should be available and show version"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Containerfile Configuration"

    # Static Containerfile analysis tests (no container required)
    run_test test_sdkman_offline_mode_block_exists
    run_test test_sdkman_auto_answer_configured
    run_test test_sdkman_auto_update_disabled
    run_test test_sdkman_config_conditional_on_java_enabled
    run_test test_sdkman_config_checks_file_exists
    run_test test_sdkman_config_uses_sed_in_place
    run_test test_sdkman_offline_mode_appended
    run_test test_sdkman_config_block_order
    run_test test_sdkman_config_comment_exists

    # Container integration tests (requires Podman)
    if skip_if_no_container 2>/dev/null; then
        run_test test_sdkman_config_in_built_image
        run_test test_sdkman_no_network_warning
        run_test test_java_available_in_image
        run_test test_maven_available_in_image
    else
        skip_test test_sdkman_config_in_built_image "No container runtime"
        skip_test test_sdkman_no_network_warning "No container runtime"
        skip_test test_java_available_in_image "No container runtime"
        skip_test test_maven_available_in_image "No container runtime"
    fi

    # Summary
    print_summary
}

main "$@"
