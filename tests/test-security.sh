#!/usr/bin/env bash
#===============================================================================
# Test: Security Library (security.sh)
#
# Tests the security hardening library functions:
#   - Security profile validation
#   - Capability argument generation
#   - Seccomp profile selection
#   - Process isolation arguments
#   - LSM detection
#   - Resource limit arguments
#   - YAML config parsing integration
#
# Note: These are unit tests for the security.sh functions. Container-level
# enforcement tests are in test-security-no-root.sh.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the security library
source "$KAPSIS_ROOT/scripts/lib/security.sh"

# Source logging (required by security.sh)
source "$KAPSIS_ROOT/scripts/lib/logging.sh"

# Test temp directory
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_security_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-security-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"

    # Reset environment to defaults before each test group
    unset KAPSIS_SECURITY_PROFILE
    unset KAPSIS_CAPS_DROP_ALL
    unset KAPSIS_CAPS_ADD
    unset KAPSIS_SECCOMP_ENABLED
    unset KAPSIS_SECCOMP_PROFILE
    unset KAPSIS_SECCOMP_AUDIT
    unset KAPSIS_NO_NEW_PRIVILEGES
    unset KAPSIS_PIDS_LIMIT
    unset KAPSIS_NOEXEC_TMP
    unset KAPSIS_READONLY_ROOT
    unset KAPSIS_REQUIRE_LSM
    unset KAPSIS_LSM_MODE
    unset KAPSIS_TMP_SIZE
    unset KAPSIS_VARTMP_SIZE
    unset KAPSIS_ULIMIT_NOFILE
    unset KAPSIS_MEMORY_RESERVATION
    unset KAPSIS_CPU_SHARES
}

cleanup_security_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Reset env for a single test
reset_security_env() {
    unset KAPSIS_SECURITY_PROFILE
    unset KAPSIS_CAPS_DROP_ALL
    unset KAPSIS_CAPS_ADD
    unset KAPSIS_SECCOMP_ENABLED
    unset KAPSIS_SECCOMP_PROFILE
    unset KAPSIS_NO_NEW_PRIVILEGES
    unset KAPSIS_PIDS_LIMIT
    unset KAPSIS_NOEXEC_TMP
    unset KAPSIS_READONLY_ROOT
    unset KAPSIS_REQUIRE_LSM
}

#===============================================================================
# PROFILE VALIDATION TESTS
#===============================================================================

test_valid_profiles_accepted() {
    log_test "Security profiles: valid profiles pass validation"

    local profiles=(minimal standard strict paranoid)

    for profile in "${profiles[@]}"; do
        reset_security_env
        export KAPSIS_SECURITY_PROFILE="$profile"

        if ! validate_security_config 2>/dev/null; then
            log_fail "Profile '$profile' should be valid"
            return 1
        fi
    done

    return 0
}

test_invalid_profile_rejected() {
    log_test "Security profiles: invalid profile fails validation"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="invalid"

    local output
    local exit_code=0
    output=$(validate_security_config 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_fail "Invalid profile 'invalid' should be rejected"
        return 1
    fi

    assert_contains "$output" "Invalid security profile" \
        "Should mention invalid profile"
}

test_default_profile_is_standard() {
    log_test "Security profiles: default profile is 'standard'"

    reset_security_env
    # Don't set KAPSIS_SECURITY_PROFILE

    # The profile should default to standard
    local expected="standard"
    local actual="${KAPSIS_SECURITY_PROFILE:-standard}"

    assert_equals "$expected" "$actual" "Default profile should be standard"
}

#===============================================================================
# CAPABILITY ARGUMENT TESTS
#===============================================================================

test_standard_profile_drops_all_caps() {
    log_test "Capabilities: standard profile drops all and adds back minimal"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    local args
    args=$(generate_capability_args)

    assert_contains "$args" "--cap-drop=ALL" \
        "Should drop all capabilities"
    assert_contains "$args" "--cap-add=CHOWN" \
        "Should add back CHOWN"
    assert_contains "$args" "--cap-add=KILL" \
        "Should add back KILL"
    assert_contains "$args" "--cap-add=SYS_NICE" \
        "Should add back SYS_NICE"
}

test_minimal_profile_does_not_drop_caps() {
    log_test "Capabilities: minimal profile does not drop capabilities"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="minimal"

    local args
    args=$(generate_capability_args)

    if [[ -n "$args" ]]; then
        log_fail "Minimal profile should not generate capability args"
        log_info "Got: $args"
        return 1
    fi

    return 0
}

test_custom_caps_add() {
    log_test "Capabilities: KAPSIS_CAPS_ADD adds custom capabilities"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_CAPS_ADD="NET_RAW,NET_ADMIN"

    local args
    args=$(generate_capability_args)

    assert_contains "$args" "--cap-add=NET_RAW" \
        "Should add NET_RAW"
    assert_contains "$args" "--cap-add=NET_ADMIN" \
        "Should add NET_ADMIN"
}

test_caps_drop_override() {
    log_test "Capabilities: KAPSIS_CAPS_DROP_ALL=false overrides profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_CAPS_DROP_ALL="false"

    local args
    args=$(generate_capability_args)

    if [[ -n "$args" ]]; then
        log_fail "KAPSIS_CAPS_DROP_ALL=false should skip capability dropping"
        log_info "Got: $args"
        return 1
    fi

    return 0
}

#===============================================================================
# SECCOMP PROFILE TESTS
#===============================================================================

test_seccomp_disabled_by_standard() {
    log_test "Seccomp: disabled for standard profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    local args
    args=$(generate_seccomp_args "claude")

    if [[ -n "$args" ]]; then
        log_fail "Standard profile should not enable seccomp"
        log_info "Got: $args"
        return 1
    fi

    return 0
}

test_seccomp_enabled_by_strict() {
    log_test "Seccomp: enabled for strict profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local args
    args=$(generate_seccomp_args "claude")

    assert_contains "$args" "seccomp=" \
        "Strict profile should enable seccomp"
}

test_seccomp_env_override() {
    log_test "Seccomp: KAPSIS_SECCOMP_ENABLED=true overrides profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_SECCOMP_ENABLED="true"

    local args
    args=$(generate_seccomp_args "claude")

    assert_contains "$args" "seccomp=" \
        "Env override should enable seccomp"
}

test_seccomp_profile_path() {
    log_test "Seccomp: returns correct profile path"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local profile_path
    profile_path=$(get_seccomp_profile "claude")

    assert_contains "$profile_path" "seccomp" \
        "Should return a seccomp profile path"
    assert_file_exists "$profile_path" \
        "Seccomp profile file should exist"
}

test_custom_seccomp_profile() {
    log_test "Seccomp: KAPSIS_SECCOMP_PROFILE overrides default"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    # Create a custom profile
    local custom_profile="$TEST_TEMP_DIR/custom-seccomp.json"
    echo '{"defaultAction": "SCMP_ACT_ALLOW"}' > "$custom_profile"
    export KAPSIS_SECCOMP_PROFILE="$custom_profile"

    local profile_path
    profile_path=$(get_seccomp_profile "claude")

    assert_equals "$custom_profile" "$profile_path" \
        "Should use custom seccomp profile"
}

#===============================================================================
# PROCESS ISOLATION TESTS
#===============================================================================

test_process_isolation_standard() {
    log_test "Process isolation: standard profile settings"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    local args
    args=$(generate_process_isolation_args)

    assert_contains "$args" "no-new-privileges:true" \
        "Should enable no-new-privileges"
    assert_contains "$args" "--pids-limit=1000" \
        "Should set PID limit to 1000"
    assert_contains "$args" "--userns=keep-id" \
        "Should use userns keep-id"
    assert_contains "$args" "--pid=private" \
        "Should use private PID namespace"
}

test_process_isolation_strict() {
    log_test "Process isolation: strict profile has lower PID limit"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local args
    args=$(generate_process_isolation_args)

    assert_contains "$args" "--pids-limit=500" \
        "Strict profile should set PID limit to 500"
}

test_process_isolation_minimal() {
    log_test "Process isolation: minimal profile has no PID limit"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="minimal"

    local args
    args=$(generate_process_isolation_args)

    assert_not_contains "$args" "--pids-limit" \
        "Minimal profile should not set PID limit"
}

test_pids_limit_override() {
    log_test "Process isolation: KAPSIS_PIDS_LIMIT overrides profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_PIDS_LIMIT="2000"

    local args
    args=$(generate_process_isolation_args)

    assert_contains "$args" "--pids-limit=2000" \
        "Should use custom PID limit"
}

test_no_new_privileges_override() {
    log_test "Process isolation: KAPSIS_NO_NEW_PRIVILEGES=false overrides"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_NO_NEW_PRIVILEGES="false"

    local args
    args=$(generate_process_isolation_args)

    assert_not_contains "$args" "no-new-privileges" \
        "Should not enable no-new-privileges when overridden"
}

#===============================================================================
# TMPFS HARDENING TESTS
#===============================================================================

test_tmpfs_standard() {
    log_test "Tmpfs: standard profile without noexec"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    local args
    args=$(generate_tmpfs_args)

    assert_contains "$args" "--tmpfs" \
        "Should mount tmpfs"
    assert_contains "$args" "/tmp:" \
        "Should mount /tmp"
    assert_not_contains "$args" "noexec" \
        "Standard profile should not use noexec"
}

test_tmpfs_strict() {
    log_test "Tmpfs: strict profile with noexec"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local args
    args=$(generate_tmpfs_args)

    assert_contains "$args" "noexec" \
        "Strict profile should use noexec"
}

test_tmpfs_size_override() {
    log_test "Tmpfs: KAPSIS_TMP_SIZE overrides default"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_TMP_SIZE="2g"

    local args
    args=$(generate_tmpfs_args)

    assert_contains "$args" "size=2g" \
        "Should use custom tmp size"
}

#===============================================================================
# READ-ONLY ROOT TESTS
#===============================================================================

test_readonly_root_disabled_by_default() {
    log_test "Read-only root: disabled for standard profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    if should_use_readonly_root; then
        log_fail "Standard profile should not enable read-only root"
        return 1
    fi

    return 0
}

test_readonly_root_enabled_for_paranoid() {
    log_test "Read-only root: enabled for paranoid profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="paranoid"

    if ! should_use_readonly_root; then
        log_fail "Paranoid profile should enable read-only root"
        return 1
    fi

    return 0
}

test_readonly_root_override() {
    log_test "Read-only root: KAPSIS_READONLY_ROOT=true overrides profile"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"
    export KAPSIS_READONLY_ROOT="true"

    if ! should_use_readonly_root; then
        log_fail "KAPSIS_READONLY_ROOT=true should enable read-only root"
        return 1
    fi

    return 0
}

test_readonly_root_args() {
    log_test "Read-only root: generates correct arguments"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="paranoid"

    local args
    args=$(generate_readonly_root_args)

    assert_contains "$args" "--read-only" \
        "Should include --read-only flag"
    assert_contains "$args" "/run:" \
        "Should mount writable /run"
}

#===============================================================================
# LSM DETECTION TESTS
#===============================================================================

test_lsm_detection() {
    log_test "LSM: detect_lsm returns valid value"

    reset_security_env

    local lsm
    lsm=$(detect_lsm)

    # Should return one of: apparmor, selinux, none
    case "$lsm" in
        apparmor|selinux|none)
            return 0
            ;;
        *)
            log_fail "LSM detection returned unexpected value: $lsm"
            return 1
            ;;
    esac
}

test_lsm_disabled_mode() {
    log_test "LSM: disabled mode generates label=disable"

    reset_security_env
    export KAPSIS_LSM_MODE="disabled"

    local args
    args=$(generate_lsm_args)

    assert_contains "$args" "label=disable" \
        "Disabled LSM mode should use label=disable"
}

#===============================================================================
# RESOURCE LIMITS TESTS
#===============================================================================

test_resource_limits() {
    log_test "Resource limits: generates memory and CPU args"

    reset_security_env

    local args
    args=$(generate_resource_limit_args "8g" "4")

    assert_contains "$args" "--memory=8g" \
        "Should set memory limit"
    assert_contains "$args" "--memory-swap=8g" \
        "Should set swap limit equal to memory"
    assert_contains "$args" "--cpus=4" \
        "Should set CPU limit"
    assert_contains "$args" "--oom-score-adj=500" \
        "Should set OOM score adjustment"
}

test_resource_memory_reservation() {
    log_test "Resource limits: KAPSIS_MEMORY_RESERVATION override"

    reset_security_env
    export KAPSIS_MEMORY_RESERVATION="4g"

    local args
    args=$(generate_resource_limit_args "8g" "4")

    assert_contains "$args" "--memory-reservation=4g" \
        "Should use custom memory reservation"
}

test_resource_cpu_shares() {
    log_test "Resource limits: KAPSIS_CPU_SHARES override"

    reset_security_env
    export KAPSIS_CPU_SHARES="2048"

    local args
    args=$(generate_resource_limit_args "8g" "4")

    assert_contains "$args" "--cpu-shares=2048" \
        "Should use custom CPU shares"
}

#===============================================================================
# FULL SECURITY ARGS GENERATION
#===============================================================================

test_generate_security_args_standard() {
    log_test "Full args: standard profile generates expected flags"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="standard"

    local args
    args=$(generate_security_args "claude" "8g" "4")

    # Should have capabilities
    assert_contains "$args" "--cap-drop=ALL" \
        "Should drop capabilities"

    # Should have process isolation
    assert_contains "$args" "no-new-privileges:true" \
        "Should have no-new-privileges"
    assert_contains "$args" "--pids-limit=1000" \
        "Should have PID limit"

    # Should NOT have seccomp (standard profile)
    assert_not_contains "$args" "seccomp=" \
        "Standard profile should not have seccomp"

    # Should have resource limits
    assert_contains "$args" "--memory=8g" \
        "Should have memory limit"
}

test_generate_security_args_strict() {
    log_test "Full args: strict profile enables seccomp"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local args
    args=$(generate_security_args "claude" "8g" "4")

    # Should have seccomp
    assert_contains "$args" "seccomp=" \
        "Strict profile should have seccomp"

    # Should have noexec tmpfs
    assert_contains "$args" "noexec" \
        "Strict profile should have noexec tmpfs"

    # Should have lower PID limit
    assert_contains "$args" "--pids-limit=500" \
        "Strict profile should have PID limit 500"
}

#===============================================================================
# CLI INTEGRATION TESTS
#===============================================================================

test_cli_security_profile_flag() {
    log_test "CLI: --security-profile flag works"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/test-project"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo for the test
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test") && git config commit.gpgsign false

    local output
    output=$("$launch_script" "$project_dir" --security-profile strict --task "echo test" --dry-run 2>&1) || true

    # Should show strict profile in output
    assert_contains "$output" "seccomp=" \
        "--security-profile strict should enable seccomp"
}

test_cli_dry_run_shows_security() {
    log_test "CLI: dry-run shows security configuration"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/test-project2"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo for the test
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test") && git config commit.gpgsign false

    local output
    output=$("$launch_script" "$project_dir" --security-profile paranoid --task "echo test" --dry-run 2>&1) || true

    # Should show security flags
    assert_contains "$output" "--cap-drop=ALL" \
        "Dry-run should show capability dropping"
    assert_contains "$output" "seccomp=" \
        "Dry-run should show seccomp for paranoid"
}

#===============================================================================
# YAML CONFIG PARSING TESTS
#===============================================================================

test_yaml_config_security_profile() {
    log_test "YAML: security.profile is parsed"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/yaml-project"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test") && git config commit.gpgsign false

    # Create config with security section
    cat > "$project_dir/agent-sandbox.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace

security:
  profile: strict
EOF

    local output
    output=$("$launch_script" "$project_dir" --config "$project_dir/agent-sandbox.yaml" --task "echo test" --dry-run 2>&1) || true

    # Should apply strict profile from config
    assert_contains "$output" "seccomp=" \
        "Config security.profile=strict should enable seccomp"
}

test_yaml_config_security_pids_limit() {
    log_test "YAML: security.process.pids_limit is parsed"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/yaml-project2"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test") && git config commit.gpgsign false

    # Create config with custom PID limit
    cat > "$project_dir/agent-sandbox.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace

security:
  profile: standard
  process:
    pids_limit: 750
EOF

    local output
    output=$("$launch_script" "$project_dir" --config "$project_dir/agent-sandbox.yaml" --task "echo test" --dry-run 2>&1) || true

    # Should use custom PID limit
    assert_contains "$output" "--pids-limit=750" \
        "Config security.process.pids_limit should override default"
}

test_yaml_config_priority_order() {
    log_test "YAML: CLI flag overrides config file"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/yaml-project3"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test") && git config commit.gpgsign false

    # Create config with standard profile
    cat > "$project_dir/agent-sandbox.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace

security:
  profile: standard
EOF

    # Use --security-profile strict on CLI (should override config)
    local output
    output=$("$launch_script" "$project_dir" --config "$project_dir/agent-sandbox.yaml" --security-profile strict --task "echo test" --dry-run 2>&1) || true

    # CLI should win - strict enables seccomp
    assert_contains "$output" "seccomp=" \
        "CLI --security-profile should override config file"
}

#===============================================================================
# SECURITY SUMMARY TESTS
#===============================================================================

test_print_security_summary() {
    log_test "Summary: print_security_summary runs without error"

    reset_security_env
    export KAPSIS_SECURITY_PROFILE="strict"

    local output
    local exit_code=0
    output=$(print_security_summary 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_fail "print_security_summary should not fail"
        return 1
    fi

    assert_contains "$output" "Security Configuration" \
        "Should print security header"
    assert_contains "$output" "strict" \
        "Should show current profile"
}

#===============================================================================
# SECRET ENV-FILE TESTS
#===============================================================================

test_secrets_use_env_file_not_command_line() {
    log_test "Secrets: API keys use --env-file, not -e flags in command"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/test-env-file"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo for the test
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test" && git config commit.gpgsign false)

    # Create a test config that passes through API keys
    local test_config="$project_dir/agent-sandbox.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - ANTHROPIC_API_KEY
    - OPENAI_API_KEY
EOF

    # Set test API keys
    export ANTHROPIC_API_KEY="sk-ant-test-secret-key-12345"
    export OPENAI_API_KEY="sk-openai-test-secret-67890"

    local output
    output=$("$launch_script" "$project_dir" --config "$test_config" --task "test" --dry-run 2>&1) || true

    unset ANTHROPIC_API_KEY OPENAI_API_KEY

    # Command line should NOT contain the actual secret values
    assert_not_contains "$output" "sk-ant-test-secret-key-12345" \
        "ANTHROPIC_API_KEY value should NOT appear in command line"
    assert_not_contains "$output" "sk-openai-test-secret-67890" \
        "OPENAI_API_KEY value should NOT appear in command line"

    # Dry-run should mention secrets will be passed via --env-file
    assert_contains "$output" "via --env-file" \
        "Should mention secrets use --env-file"
    assert_contains "$output" "ANTHROPIC_API_KEY" \
        "Should list ANTHROPIC_API_KEY as a secret"
    assert_contains "$output" "OPENAI_API_KEY" \
        "Should list OPENAI_API_KEY as a secret"
}

test_non_secret_vars_still_use_inline_flags() {
    log_test "Secrets: Non-secret vars still use -e flags"

    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"
    local project_dir="$TEST_TEMP_DIR/test-non-secret"
    mkdir -p "$project_dir"

    # Initialize a minimal git repo for the test
    (cd "$project_dir" && git init -q && git config user.email "test@test.com" && git config user.name "Test" && git config commit.gpgsign false)

    # Create a test config with non-secret vars
    local test_config="$project_dir/agent-sandbox.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  passthrough:
    - HOME
    - USER
  set:
    MAVEN_OPTS: "-Xmx4g"
EOF

    export HOME="${HOME:-/home/test}"
    export USER="${USER:-testuser}"

    local output
    output=$("$launch_script" "$project_dir" --config "$test_config" --task "test" --dry-run 2>&1) || true

    # Non-secret variables should appear as -e flags
    assert_contains "$output" "-e MAVEN_OPTS=-Xmx4g" \
        "MAVEN_OPTS should use -e flag (not secret)"
}

test_secret_classification_patterns() {
    log_test "Secrets: Variables matching secret patterns are classified correctly"

    # Source logging library to get is_secret_var_name
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"

    # These should be classified as secrets
    local secret_vars=("ANTHROPIC_API_KEY" "OPENAI_API_KEY" "GITHUB_TOKEN" "AWS_SECRET_ACCESS_KEY" "DB_PASSWORD" "AUTH_TOKEN" "BEARER_TOKEN" "PRIVATE_KEY")

    for var in "${secret_vars[@]}"; do
        if ! is_secret_var_name "$var"; then
            log_fail "$var should be classified as a secret"
            return 1
        fi
    done

    # These should NOT be classified as secrets
    local non_secret_vars=("HOME" "USER" "PATH" "MAVEN_OPTS" "JAVA_HOME" "KAPSIS_AGENT_ID")

    for var in "${non_secret_vars[@]}"; do
        if is_secret_var_name "$var"; then
            log_fail "$var should NOT be classified as a secret"
            return 1
        fi
    done

    return 0
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Security Library (security.sh)"

    # Setup
    setup_security_tests

    # Ensure cleanup on exit
    trap cleanup_security_tests EXIT

    # Profile validation tests
    run_test test_valid_profiles_accepted
    run_test test_invalid_profile_rejected
    run_test test_default_profile_is_standard

    # Capability tests
    run_test test_standard_profile_drops_all_caps
    run_test test_minimal_profile_does_not_drop_caps
    run_test test_custom_caps_add
    run_test test_caps_drop_override

    # Seccomp tests
    run_test test_seccomp_disabled_by_standard
    run_test test_seccomp_enabled_by_strict
    run_test test_seccomp_env_override
    run_test test_seccomp_profile_path
    run_test test_custom_seccomp_profile

    # Process isolation tests
    run_test test_process_isolation_standard
    run_test test_process_isolation_strict
    run_test test_process_isolation_minimal
    run_test test_pids_limit_override
    run_test test_no_new_privileges_override

    # Tmpfs tests
    run_test test_tmpfs_standard
    run_test test_tmpfs_strict
    run_test test_tmpfs_size_override

    # Read-only root tests
    run_test test_readonly_root_disabled_by_default
    run_test test_readonly_root_enabled_for_paranoid
    run_test test_readonly_root_override
    run_test test_readonly_root_args

    # LSM tests
    run_test test_lsm_detection
    run_test test_lsm_disabled_mode

    # Resource limits tests
    run_test test_resource_limits
    run_test test_resource_memory_reservation
    run_test test_resource_cpu_shares

    # Full args generation tests
    run_test test_generate_security_args_standard
    run_test test_generate_security_args_strict

    # CLI integration tests
    run_test test_cli_security_profile_flag
    run_test test_cli_dry_run_shows_security

    # YAML config tests
    run_test test_yaml_config_security_profile
    run_test test_yaml_config_security_pids_limit
    run_test test_yaml_config_priority_order

    # Summary test
    run_test test_print_security_summary

    # Secret env-file tests (Fix #135: prevent secret exposure in bash -x)
    run_test test_secrets_use_env_file_not_command_line
    run_test test_non_secret_vars_still_use_inline_flags
    run_test test_secret_classification_patterns

    # Summary
    print_summary
}

main "$@"
