#!/usr/bin/env bash
#===============================================================================
# Test: Build Configuration Parsing
#
# Verifies that build-config.yaml and profiles are parsed correctly, including:
# - Default configuration loading
# - Profile preset loading
# - Language and build tool toggles
# - Build args generation for Containerfile
# - JSON export for AI agent integration
# - Image size estimation
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

BUILD_CONFIG_LIB="$KAPSIS_ROOT/scripts/lib/build-config.sh"
CONFIGURE_DEPS="$KAPSIS_ROOT/scripts/configure-deps.sh"
CONFIGS_DIR="$KAPSIS_ROOT/configs"

#===============================================================================
# SETUP
#===============================================================================

setup_test_config_dir() {
    TEST_CONFIG_DIR=$(mktemp -d)
    log_info "Test config dir: $TEST_CONFIG_DIR"
}

cleanup_test_config_dir() {
    [[ -n "${TEST_CONFIG_DIR:-}" ]] && rm -rf "$TEST_CONFIG_DIR"
}

create_test_config() {
    local filename="$1"
    local content="$2"
    echo "$content" > "$TEST_CONFIG_DIR/$filename"
}

#===============================================================================
# PREREQUISITE CHECKS
#===============================================================================

check_yq_installed() {
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed (required for config parsing)"
        return 1
    fi
    return 0
}

#===============================================================================
# TEST CASES: Config Parsing
#===============================================================================

test_parse_default_config() {
    log_test "Testing parse default configuration"

    if ! check_yq_installed; then
        return 0
    fi

    # Source the library fresh
    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    # Parse the default config
    local config_file="$CONFIGS_DIR/build-config.yaml"
    assert_file_exists "$config_file" "Default config should exist"

    parse_build_config "$config_file"

    # Verify expected defaults
    assert_equals "true" "$ENABLE_JAVA" "Java should be enabled by default"
    assert_equals "true" "$ENABLE_NODEJS" "Node.js should be enabled by default"
    assert_equals "true" "$ENABLE_PYTHON" "Python should be enabled by default"
    assert_equals "true" "$ENABLE_MAVEN" "Maven should be enabled by default"
    assert_equals "17.0.14-zulu" "$JAVA_DEFAULT" "Java default should be 17.0.14-zulu"
}

test_parse_minimal_profile() {
    log_test "Testing parse minimal profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    local config_file="$CONFIGS_DIR/build-profiles/minimal.yaml"
    assert_file_exists "$config_file" "Minimal profile should exist"

    parse_build_config "$config_file"

    # Verify minimal profile disables languages
    assert_equals "false" "$ENABLE_JAVA" "Java should be disabled in minimal"
    assert_equals "false" "$ENABLE_NODEJS" "Node.js should be disabled in minimal"
    assert_equals "false" "$ENABLE_RUST" "Rust should be disabled in minimal"
    assert_equals "false" "$ENABLE_GO" "Go should be disabled in minimal"
    assert_equals "false" "$ENABLE_MAVEN" "Maven should be disabled in minimal"
}

test_parse_java_dev_profile() {
    log_test "Testing parse java-dev profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    local config_file="$CONFIGS_DIR/build-profiles/java-dev.yaml"
    assert_file_exists "$config_file" "Java-dev profile should exist"

    parse_build_config "$config_file"

    # Verify Java development settings
    assert_equals "true" "$ENABLE_JAVA" "Java should be enabled in java-dev"
    assert_equals "true" "$ENABLE_MAVEN" "Maven should be enabled in java-dev"
    assert_equals "true" "$ENABLE_GRADLE_ENTERPRISE" "GE should be enabled in java-dev"
    assert_equals "false" "$ENABLE_NODEJS" "Node.js should be disabled in java-dev"
    assert_equals "false" "$ENABLE_RUST" "Rust should be disabled in java-dev"
}

test_parse_full_stack_profile() {
    log_test "Testing parse full-stack profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    local config_file="$CONFIGS_DIR/build-profiles/full-stack.yaml"
    assert_file_exists "$config_file" "Full-stack profile should exist"

    parse_build_config "$config_file"

    # Verify full-stack enables multiple languages
    assert_equals "true" "$ENABLE_JAVA" "Java should be enabled in full-stack"
    assert_equals "true" "$ENABLE_NODEJS" "Node.js should be enabled in full-stack"
    assert_equals "true" "$ENABLE_PYTHON" "Python should be enabled in full-stack"
    assert_equals "true" "$ENABLE_MAVEN" "Maven should be enabled in full-stack"
}

test_parse_backend_rust_profile() {
    log_test "Testing parse backend-rust profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    local config_file="$CONFIGS_DIR/build-profiles/backend-rust.yaml"
    assert_file_exists "$config_file" "Backend-rust profile should exist"

    parse_build_config "$config_file"

    # Verify Rust development settings
    assert_equals "true" "$ENABLE_RUST" "Rust should be enabled in backend-rust"
    assert_equals "true" "$ENABLE_PYTHON" "Python should be enabled in backend-rust"
    assert_equals "false" "$ENABLE_JAVA" "Java should be disabled in backend-rust"
    assert_equals "false" "$ENABLE_NODEJS" "Node.js should be disabled in backend-rust"
    assert_equals "stable" "$RUST_CHANNEL" "Rust channel should be stable"
}

test_parse_frontend_profile() {
    log_test "Testing parse frontend profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    local config_file="$CONFIGS_DIR/build-profiles/frontend.yaml"
    assert_file_exists "$config_file" "Frontend profile should exist"

    parse_build_config "$config_file"

    # Verify frontend development settings
    assert_equals "true" "$ENABLE_NODEJS" "Node.js should be enabled in frontend"
    assert_equals "true" "$ENABLE_RUST" "Rust should be enabled in frontend"
    assert_equals "false" "$ENABLE_JAVA" "Java should be disabled in frontend"
    assert_equals "20.10.0" "$NODEJS_VERSION" "Node.js default should be 20.10.0"
}

test_parse_java_versions_array() {
    log_test "Testing Java versions array parsing"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-config.yaml"

    # JAVA_VERSIONS should be a JSON array
    assert_contains "$JAVA_VERSIONS" "21.0.6-zulu" "Should include Java 21"
    assert_contains "$JAVA_VERSIONS" "17.0.14-zulu" "Should include Java 17"
    assert_contains "$JAVA_VERSIONS" "8.0.422-zulu" "Should include Java 8"
}

test_invalid_yaml_syntax() {
    log_test "Testing invalid YAML syntax error handling"

    if ! check_yq_installed; then
        return 0
    fi

    setup_test_config_dir

    # Create invalid YAML
    create_test_config "invalid.yaml" "
languages:
  java
    enabled: true  # Invalid indentation
"

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    # Should return error
    if parse_build_config "$TEST_CONFIG_DIR/invalid.yaml" 2>/dev/null; then
        log_fail "Should have failed on invalid YAML"
        cleanup_test_config_dir
        return 1
    fi

    cleanup_test_config_dir
}

test_missing_config_uses_defaults() {
    log_test "Testing missing config file uses defaults"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    # Parse non-existent file (should use defaults)
    parse_build_config "/nonexistent/config.yaml" 2>/dev/null

    # Should have default values
    assert_equals "true" "$ENABLE_JAVA" "Should use default Java enabled"
    assert_equals "17.0.14-zulu" "$JAVA_DEFAULT" "Should use default Java version"
}

#===============================================================================
# TEST CASES: Build Args Generation
#===============================================================================

test_build_args_generation() {
    log_test "Testing BUILD_ARGS array generation"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-config.yaml"

    # BUILD_ARGS should be populated
    assert_true "[[ ${#BUILD_ARGS[@]} -gt 0 ]]" "BUILD_ARGS should not be empty"

    # Convert to string for checking
    local args_string
    args_string=$(printf '%s ' "${BUILD_ARGS[@]}")

    assert_contains "$args_string" "ENABLE_JAVA=true" "Should include ENABLE_JAVA"
    assert_contains "$args_string" "ENABLE_NODEJS=true" "Should include ENABLE_NODEJS"
    assert_contains "$args_string" "JAVA_DEFAULT=17.0.14-zulu" "Should include JAVA_DEFAULT"
}

test_build_args_for_minimal() {
    log_test "Testing BUILD_ARGS for minimal profile"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-profiles/minimal.yaml"

    local args_string
    args_string=$(printf '%s ' "${BUILD_ARGS[@]}")

    assert_contains "$args_string" "ENABLE_JAVA=false" "Should have ENABLE_JAVA=false"
    assert_contains "$args_string" "ENABLE_NODEJS=false" "Should have ENABLE_NODEJS=false"
    assert_contains "$args_string" "ENABLE_MAVEN=false" "Should have ENABLE_MAVEN=false"
}

#===============================================================================
# TEST CASES: Image Size Estimation
#===============================================================================

test_estimate_image_size_minimal() {
    log_test "Testing image size estimation for minimal"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-profiles/minimal.yaml"

    local size
    size=$(estimate_image_size)

    # Minimal should be smallest
    assert_contains "$size" "MB" "Minimal size should be in MB"
    assert_not_contains "$size" "GB" "Minimal should not be in GB range"
}

test_estimate_image_size_full() {
    log_test "Testing image size estimation for full-stack"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-profiles/full-stack.yaml"

    local size
    size=$(estimate_image_size)

    # Full-stack should be larger
    assert_contains "$size" "GB" "Full-stack size should be in GB"
}

#===============================================================================
# TEST CASES: JSON Export
#===============================================================================

test_json_export_format() {
    log_test "Testing JSON export format"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-config.yaml"

    local json_output
    json_output=$(export_config_json)

    # Verify JSON structure
    assert_contains "$json_output" '"languages"' "Should have languages key"
    assert_contains "$json_output" '"java"' "Should have java key"
    assert_contains "$json_output" '"build_tools"' "Should have build_tools key"
    assert_contains "$json_output" '"estimated_size"' "Should have estimated_size"

    # Verify it's valid JSON (if jq is available)
    if command -v jq &>/dev/null; then
        if ! echo "$json_output" | jq . &>/dev/null; then
            log_fail "JSON output should be valid JSON"
            return 1
        fi
    fi
}

#===============================================================================
# TEST CASES: Config Summary
#===============================================================================

test_config_summary_output() {
    log_test "Testing config summary output"

    if ! check_yq_installed; then
        return 0
    fi

    unset _KAPSIS_BUILD_CONFIG_LOADED
    source "$BUILD_CONFIG_LIB"

    parse_build_config "$CONFIGS_DIR/build-config.yaml"

    local summary
    summary=$(print_config_summary)

    assert_contains "$summary" "Languages:" "Should have Languages section"
    assert_contains "$summary" "Build Tools:" "Should have Build Tools section"
    assert_contains "$summary" "Java:" "Should mention Java"
    assert_contains "$summary" "Maven:" "Should mention Maven"
}

#===============================================================================
# TEST CASES: CLI Tool (configure-deps.sh)
#===============================================================================

test_configure_deps_help() {
    log_test "Testing configure-deps.sh --help"

    local output
    output=$("$CONFIGURE_DEPS" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should show usage"
    assert_contains "$output" "--profile" "Help should mention --profile"
    assert_contains "$output" "--json" "Help should mention --json"
}

test_configure_deps_list_profiles() {
    log_test "Testing configure-deps.sh --list-profiles"

    local output
    output=$("$CONFIGURE_DEPS" --list-profiles 2>&1) || true

    assert_contains "$output" "minimal" "Should list minimal profile"
    assert_contains "$output" "java-dev" "Should list java-dev profile"
    assert_contains "$output" "full-stack" "Should list full-stack profile"
}

test_configure_deps_dry_run() {
    log_test "Testing configure-deps.sh --dry-run"

    if ! check_yq_installed; then
        return 0
    fi

    local output
    output=$("$CONFIGURE_DEPS" --profile minimal --dry-run 2>&1) || true

    assert_contains "$output" "Dry Run" "Should mention dry run"
    assert_contains "$output" "minimal" "Should show minimal profile"
}

test_configure_deps_json_output() {
    log_test "Testing configure-deps.sh --json output"

    if ! check_yq_installed; then
        return 0
    fi

    local output
    output=$("$CONFIGURE_DEPS" --profile java-dev --dry-run --json 2>&1) || true

    # Should output JSON
    assert_contains "$output" '"success"' "Should have success field"
    assert_contains "$output" '"profile"' "Should have profile field"
}

test_configure_deps_invalid_profile() {
    log_test "Testing configure-deps.sh with invalid profile"

    local exit_code=0
    "$CONFIGURE_DEPS" --profile nonexistent --dry-run 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" "Should fail with invalid profile"
}

#===============================================================================
# TEST CASES: All Profiles Exist
#===============================================================================

test_all_profiles_exist() {
    log_test "Testing all expected profiles exist"

    local profiles=(
        "minimal"
        "java-dev"
        "java8-legacy"
        "full-stack"
        "backend-go"
        "backend-rust"
        "ml-python"
        "frontend"
    )

    for profile in "${profiles[@]}"; do
        local profile_file="$CONFIGS_DIR/build-profiles/${profile}.yaml"
        assert_file_exists "$profile_file" "Profile $profile should exist"
    done
}

test_all_profiles_valid_yaml() {
    log_test "Testing all profiles are valid YAML"

    if ! check_yq_installed; then
        return 0
    fi

    for profile_file in "$CONFIGS_DIR/build-profiles"/*.yaml; do
        if ! yq eval '.' "$profile_file" &>/dev/null; then
            log_fail "Profile $(basename "$profile_file") has invalid YAML"
            return 1
        fi
    done
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Build Configuration Parsing"

    # Config parsing tests
    run_test test_parse_default_config
    run_test test_parse_minimal_profile
    run_test test_parse_java_dev_profile
    run_test test_parse_full_stack_profile
    run_test test_parse_backend_rust_profile
    run_test test_parse_frontend_profile
    run_test test_parse_java_versions_array
    run_test test_invalid_yaml_syntax
    run_test test_missing_config_uses_defaults

    # Build args tests
    run_test test_build_args_generation
    run_test test_build_args_for_minimal

    # Size estimation tests
    run_test test_estimate_image_size_minimal
    run_test test_estimate_image_size_full

    # JSON export tests
    run_test test_json_export_format

    # Config summary tests
    run_test test_config_summary_output

    # CLI tool tests
    run_test test_configure_deps_help
    run_test test_configure_deps_list_profiles
    run_test test_configure_deps_dry_run
    run_test test_configure_deps_json_output
    run_test test_configure_deps_invalid_profile

    # Profile existence tests
    run_test test_all_profiles_exist
    run_test test_all_profiles_valid_yaml

    # Summary
    print_summary
}

main "$@"
