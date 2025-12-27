#!/usr/bin/env bash
#===============================================================================
# Test: Agent Config Mounts
#
# Verifies that agent profiles properly handle config file mounts.
# Tests filesystem.include configuration and mount behaviors.
#
# REQUIRES: Container environment (Podman)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_config_mount_in_dry_run() {
    log_test "Testing config mount appears in dry-run output"

    # Create a test config file
    local test_file="$HOME/.kapsis-mount-test-file"
    echo "test-content" > "$test_file"

    local test_config="$TEST_PROJECT/.kapsis-mount-test.yaml"
    cat > "$test_config" << EOF
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.kapsis-mount-test-file
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config" "$test_file"

    # Mount should appear in output
    assert_contains "$output" "kapsis-mount-test-file" "Config mount should appear in dry-run"
}

test_multiple_config_mounts() {
    log_test "Testing multiple config mounts"

    # Create test files
    local test_file1="$HOME/.kapsis-multi-mount-1"
    local test_file2="$HOME/.kapsis-multi-mount-2"
    echo "content1" > "$test_file1"
    echo "content2" > "$test_file2"

    local test_config="$TEST_PROJECT/.kapsis-multi-mount.yaml"
    cat > "$test_config" << EOF
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.kapsis-multi-mount-1
    - ~/.kapsis-multi-mount-2
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config" "$test_file1" "$test_file2"

    # Both mounts should appear
    assert_contains "$output" "kapsis-multi-mount-1" "First mount should appear"
    assert_contains "$output" "kapsis-multi-mount-2" "Second mount should appear"
}

test_staging_pattern_for_home_paths() {
    log_test "Testing staging pattern for home paths"

    local test_file="$HOME/.kapsis-staging-test"
    echo "staging-test" > "$test_file"

    local test_config="$TEST_PROJECT/.kapsis-staging-test.yaml"
    cat > "$test_config" << EOF
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.kapsis-staging-test
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config" "$test_file"

    # Should use staging pattern for home paths
    assert_contains "$output" "/kapsis-staging/" "Home paths should use staging pattern"
}

test_absolute_path_mount() {
    log_test "Testing absolute path mount"

    local test_config="$TEST_PROJECT/.kapsis-abs-mount.yaml"
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

    # Absolute paths should mount directly
    assert_contains "$output" "/etc/hosts:/etc/hosts" "Absolute paths should mount directly"
}

test_config_mount_accessible_in_container() {
    log_test "Testing config file is accessible in container"

    if ! skip_if_no_container; then
        return 0
    fi

    setup_container_test "config-mount"

    # Create test config
    local test_file="$HOME/.kapsis-container-test-config"
    echo '{"test": true}' > "$test_file"

    # Run container with mount
    local output
    output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        -v "$test_file:/kapsis-staging/.kapsis-container-test-config:ro" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c 'cat /kapsis-staging/.kapsis-container-test-config' 2>&1) || true

    cleanup_container_test
    rm -f "$test_file"

    # File should be readable
    assert_contains "$output" '{"test": true}' "Config file should be accessible in container"
}

test_mount_readonly_by_default() {
    log_test "Testing mounts are read-only by default"

    local test_config="$TEST_PROJECT/.kapsis-readonly-test.yaml"
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

    # Should include :ro flag for read-only
    assert_contains "$output" ":ro" "Mounts should be read-only by default"
}

test_missing_optional_mount() {
    log_test "Testing missing optional mount is handled"

    local test_config="$TEST_PROJECT/.kapsis-optional-mount.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.this-file-does-not-exist-12345
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should handle gracefully - either skip the mount or complete dry-run
    # The behavior depends on implementation, but it shouldn't crash
    assert_contains "$output" "DRY RUN" "Should complete dry-run even with missing optional mount"
}

test_directory_mount() {
    log_test "Testing directory mount"

    # Create test directory
    local test_dir="$HOME/.kapsis-dir-mount-test"
    mkdir -p "$test_dir"
    echo "test" > "$test_dir/file.txt"

    local test_config="$TEST_PROJECT/.kapsis-dir-mount.yaml"
    cat > "$test_config" << EOF
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.kapsis-dir-mount-test
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config"
    rm -rf "$test_dir"

    # Directory mount should appear
    assert_contains "$output" "kapsis-dir-mount-test" "Directory mount should appear"
}

test_empty_filesystem_include() {
    log_test "Testing empty filesystem include is handled"

    local test_config="$TEST_PROJECT/.kapsis-empty-include.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
filesystem:
  include: []
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should complete successfully
    assert_equals 0 "$exit_code" "Should handle empty filesystem include"
    assert_contains "$output" "DRY RUN" "Should complete dry-run"
}

test_no_filesystem_section() {
    log_test "Testing config without filesystem section"

    local test_config="$TEST_PROJECT/.kapsis-no-fs.yaml"
    cat > "$test_config" << 'EOF'
agent:
  command: "echo test"
environment:
  set:
    MY_VAR: "value"
EOF

    local output
    local exit_code=0
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    rm -f "$test_config"

    # Should work without filesystem section
    assert_equals 0 "$exit_code" "Should work without filesystem section"
}

test_staged_configs_env_var_set() {
    log_test "Testing KAPSIS_STAGED_CONFIGS env var is set"

    local test_file="$HOME/.kapsis-staged-env-test"
    echo "test" > "$test_file"

    local test_config="$TEST_PROJECT/.kapsis-staged-env.yaml"
    cat > "$test_config" << EOF
agent:
  command: "echo test"
filesystem:
  include:
    - ~/.kapsis-staged-env-test
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || true

    rm -f "$test_config" "$test_file"

    # KAPSIS_STAGED_CONFIGS should be set
    assert_contains "$output" "KAPSIS_STAGED_CONFIGS=" "KAPSIS_STAGED_CONFIGS should be set"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Config Mounts"

    # Setup
    setup_test_project

    # Run tests
    run_test test_config_mount_in_dry_run
    run_test test_multiple_config_mounts
    run_test test_staging_pattern_for_home_paths
    run_test test_absolute_path_mount

    # Container tests
    if skip_if_no_container 2>/dev/null; then
        run_test test_config_mount_accessible_in_container
    else
        skip_test test_config_mount_accessible_in_container "No container runtime"
    fi

    run_test test_mount_readonly_by_default
    run_test test_missing_optional_mount
    run_test test_directory_mount
    run_test test_empty_filesystem_include
    run_test test_no_filesystem_section
    run_test test_staged_configs_env_var_set

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
