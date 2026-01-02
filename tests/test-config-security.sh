#!/usr/bin/env bash
#===============================================================================
# Test: Config Security Validation
#
# Tests for the validate_config_security() function in launch-agent.sh.
#
# Verifies:
#   - Trusted locations are accepted (KAPSIS_ROOT, HOME config, project local)
#   - Untrusted locations are rejected
#   - World-writable config files generate warnings
#   - Suspicious filenames are rejected
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

# Test temp directory
TEST_TEMP_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_config_security_tests() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-config-security-test.XXXXXX")
    log_info "Test temp directory: $TEST_TEMP_DIR"

    # Create minimal valid config content
    cat > "$TEST_TEMP_DIR/valid-config.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF
}

cleanup_config_security_tests() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

#===============================================================================
# TRUSTED LOCATION TESTS
#===============================================================================

test_config_in_kapsis_configs() {
    log_test "Config security: accepts config in KAPSIS_ROOT/configs/"

    # Use an existing config in the trusted location
    local config_file="$KAPSIS_ROOT/configs/claude.yaml"

    if [[ -f "$config_file" ]]; then
        local output
        output=$("$LAUNCH_SCRIPT" /tmp --config "$config_file" --task "test" --dry-run 2>&1) || true

        # Should NOT contain security error about untrusted location
        assert_not_contains "$output" "not in a trusted location" \
            "Kapsis configs should be trusted"
    else
        log_skip "claude.yaml not found in KAPSIS_ROOT/configs"
    fi
}

test_config_in_project_dir() {
    log_test "Config security: accepts config in project directory"

    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"

    # Create config in project root
    cat > "$project_dir/agent-sandbox.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    local output
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$project_dir/agent-sandbox.yaml" --task "test" --dry-run 2>&1) || true

    # Should NOT contain security error
    assert_not_contains "$output" "not in a trusted location" \
        "Project root configs should be trusted"
}

test_config_in_project_kapsis_dir() {
    log_test "Config security: accepts config in project .kapsis directory"

    local project_dir="$TEST_TEMP_DIR/project-with-kapsis"
    mkdir -p "$project_dir/.kapsis"

    # Create config in .kapsis subdir
    cat > "$project_dir/.kapsis/config.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    local output
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$project_dir/.kapsis/config.yaml" --task "test" --dry-run 2>&1) || true

    # Should NOT contain security error
    assert_not_contains "$output" "not in a trusted location" \
        "Project .kapsis configs should be trusted"
}

test_config_in_home_config() {
    log_test "Config security: accepts config in HOME/.config/kapsis"

    local home_config_dir="$HOME/.config/kapsis"

    # Only test if we can create the directory (may be restricted in some envs)
    if mkdir -p "$home_config_dir" 2>/dev/null; then
        local config_file="$home_config_dir/test-security-$$.yaml"

        cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

        local output
        output=$("$LAUNCH_SCRIPT" /tmp --config "$config_file" --task "test" --dry-run 2>&1) || true

        # Cleanup before assertions
        rm -f "$config_file"

        # Should NOT contain security error
        assert_not_contains "$output" "not in a trusted location" \
            "HOME config should be trusted"
    else
        log_skip "Cannot create HOME/.config/kapsis directory"
    fi
}

#===============================================================================
# UNTRUSTED LOCATION TESTS
#===============================================================================

test_config_in_untrusted_location() {
    log_test "Config security: rejects config in untrusted location"

    # Create config in /tmp which is NOT trusted
    local untrusted_config="/tmp/untrusted-kapsis-config-$$.yaml"

    cat > "$untrusted_config" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    # Create a trusted project path (different from config location)
    local project_dir="$TEST_TEMP_DIR/trusted-project"
    mkdir -p "$project_dir"

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$untrusted_config" --task "test" --dry-run 2>&1) || exit_code=$?

    # Cleanup
    rm -f "$untrusted_config"

    # Should contain security error
    assert_contains "$output" "not in a trusted location" \
        "Untrusted config location should be rejected"
    assert_not_equals "0" "$exit_code" "Should exit with error for untrusted config"
}

test_config_path_traversal_rejected() {
    log_test "Config security: rejects path traversal attempts"

    local project_dir="$TEST_TEMP_DIR/traversal-test"
    mkdir -p "$project_dir"

    # Create config in project
    cat > "$project_dir/config.yaml" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    # Try to use path traversal (../../etc/passwd style)
    # The config should be resolved and checked against trusted locations
    local traversal_path="$project_dir/../../../tmp/bad.yaml"

    # Create the target to ensure it exists
    mkdir -p /tmp
    cat > /tmp/bad.yaml << 'EOF'
agent:
  command: "echo malicious"
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$traversal_path" --task "test" --dry-run 2>&1) || exit_code=$?

    # Cleanup
    rm -f /tmp/bad.yaml

    # Should reject (resolved path is /tmp/bad.yaml which is not trusted)
    assert_contains "$output" "not in a trusted location" \
        "Path traversal should be detected and rejected"
}

#===============================================================================
# FILENAME VALIDATION TESTS
#===============================================================================

test_config_with_valid_filename() {
    log_test "Config security: accepts valid filenames"

    local project_dir="$TEST_TEMP_DIR/valid-names"
    mkdir -p "$project_dir"

    # Valid names: alphanumeric, dots, dashes, underscores
    local valid_names=(
        "config.yaml"
        "my-agent.yaml"
        "agent_v2.yaml"
        "claude-code.yaml"
        "test.config.yaml"
    )

    for name in "${valid_names[@]}"; do
        cat > "$project_dir/$name" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

        local output
        output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$project_dir/$name" --task "test" --dry-run 2>&1) || true

        assert_not_contains "$output" "suspicious characters" \
            "Valid filename '$name' should be accepted"

        rm -f "$project_dir/$name"
    done
}

test_config_with_suspicious_filename() {
    log_test "Config security: rejects suspicious filenames"

    local project_dir="$TEST_TEMP_DIR/suspicious-names"
    mkdir -p "$project_dir"

    # Note: Some of these may not even be creatable on filesystem
    # We test what we can
    local suspicious_name="config;malicious.yaml"

    # Try to create (may fail on some filesystems)
    if echo "agent: {command: echo}" > "$project_dir/$suspicious_name" 2>/dev/null; then
        local output
        local exit_code=0
        output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$project_dir/$suspicious_name" --task "test" --dry-run 2>&1) || exit_code=$?

        rm -f "$project_dir/$suspicious_name"

        assert_contains "$output" "suspicious characters" \
            "Filename with semicolon should be rejected"
    else
        log_info "Could not create file with suspicious name (filesystem restriction)"
    fi
}

#===============================================================================
# PERMISSION TESTS
#===============================================================================

test_config_world_writable_warning() {
    log_test "Config security: warns about world-writable config"

    local project_dir="$TEST_TEMP_DIR/writable-test"
    mkdir -p "$project_dir"

    local config_file="$project_dir/agent-sandbox.yaml"
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    # Make world-writable
    chmod 666 "$config_file"

    local output
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$config_file" --task "test" --dry-run 2>&1) || true

    # Reset permissions
    chmod 644 "$config_file"

    # Should warn about world-writable
    assert_contains "$output" "world-writable" \
        "Should warn about world-writable config"
}

test_config_secure_permissions_no_warning() {
    log_test "Config security: no warning for secure permissions"

    local project_dir="$TEST_TEMP_DIR/secure-test"
    mkdir -p "$project_dir"

    local config_file="$project_dir/agent-sandbox.yaml"
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
EOF

    # Ensure secure permissions (owner read-write only)
    chmod 600 "$config_file"

    local output
    output=$("$LAUNCH_SCRIPT" "$project_dir" --config "$config_file" --task "test" --dry-run 2>&1) || true

    # Should NOT warn about permissions
    assert_not_contains "$output" "world-writable" \
        "Secure permissions should not generate warning"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Config Security Validation"

    # Setup
    setup_config_security_tests

    # Ensure cleanup on exit
    trap cleanup_config_security_tests EXIT

    # Trusted location tests
    run_test test_config_in_kapsis_configs
    run_test test_config_in_project_dir
    run_test test_config_in_project_kapsis_dir
    run_test test_config_in_home_config

    # Untrusted location tests
    run_test test_config_in_untrusted_location
    run_test test_config_path_traversal_rejected

    # Filename validation tests
    run_test test_config_with_valid_filename
    run_test test_config_with_suspicious_filename

    # Permission tests
    run_test test_config_world_writable_warning
    run_test test_config_secure_permissions_no_warning

    # Summary
    print_summary
}

main "$@"
