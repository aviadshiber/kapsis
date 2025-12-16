#!/usr/bin/env bash
#===============================================================================
# Test: Path with Spaces
#
# Verifies that paths containing spaces are handled correctly.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_project_path_with_spaces() {
    log_test "Testing project path with spaces"

    # Create project with spaces in name
    local project_with_spaces="/tmp/kapsis test project with spaces"
    mkdir -p "$project_with_spaces"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$project_with_spaces" --task "test" --dry-run 2>&1) || true

    rm -rf "$project_with_spaces"

    # Should handle path with spaces
    assert_contains "$output" "kapsis test project" "Should handle path with spaces"
    assert_not_contains "$output" "not exist" "Should not fail on path with spaces"
}

test_spec_file_with_spaces() {
    log_test "Testing spec file path with spaces"

    # Create spec file with spaces in name
    local spec_file="$TEST_PROJECT/my spec file.md"
    echo "# Test Spec" > "$spec_file"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --spec "$spec_file" --dry-run 2>&1) || true

    rm -f "$spec_file"

    # Should handle spec file with spaces - check that it's shown in output
    # Note: "yq not found" warning may appear, so check for specific error
    assert_not_contains "$output" "Spec file not found" "Should find spec file with spaces"
    assert_contains "$output" "Spec File:" "Should show spec file in output"
}

test_config_file_with_spaces() {
    log_test "Testing config file path with spaces"

    # Create config file with spaces in name
    local config_file="$TEST_PROJECT/my config file.yaml"
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
  workdir: /workspace
filesystem:
  include: []
environment:
  passthrough: []
resources:
  memory: 2g
  cpus: 1
EOF

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --config "$config_file" --task "test" --dry-run 2>&1) || true

    rm -f "$config_file"

    # Should handle config file with spaces
    assert_not_contains "$output" "not found" "Should find config file with spaces"
    assert_contains "$output" "my config file" "Should use config file with spaces"
}

test_nested_path_with_spaces() {
    log_test "Testing nested path with multiple spaces"

    # Create deeply nested path with spaces
    local nested_path="/tmp/kapsis tests/sub folder/another level"
    mkdir -p "$nested_path"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$nested_path" --task "test" --dry-run 2>&1) || true

    rm -rf "/tmp/kapsis tests"

    # Should handle nested path with spaces
    assert_contains "$output" "another level" "Should handle nested path with spaces"
}

test_path_with_special_chars() {
    log_test "Testing path with special characters"

    # Create path with special chars (but not truly problematic ones)
    local special_path="/tmp/kapsis-test_project.v2"
    mkdir -p "$special_path"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$special_path" --task "test" --dry-run 2>&1) || true

    rm -rf "$special_path"

    # Should handle path with special chars
    assert_contains "$output" "kapsis-test_project.v2" "Should handle special chars in path"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Path with Spaces and Special Characters"

    # Setup
    setup_test_project

    # Run tests
    run_test test_project_path_with_spaces
    run_test test_spec_file_with_spaces
    run_test test_config_file_with_spaces
    run_test test_nested_path_with_spaces
    run_test test_path_with_special_chars

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
