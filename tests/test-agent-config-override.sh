#!/usr/bin/env bash
#===============================================================================
# Test: Config Override
#
# Verifies that --config takes precedence over --agent and that agent name
# is properly extracted from custom config files.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# SETUP
#===============================================================================

setup_custom_config() {
    # Create a custom config file for testing
    cat > "$TEST_PROJECT/my-custom-agent.yaml" << 'EOF'
agent:
  command: "echo 'custom agent'"
  workdir: /workspace

filesystem:
  include:
    - ~/.gitconfig

environment:
  passthrough: []

resources:
  memory: 4g
  cpus: 2
EOF
}

#===============================================================================
# TEST CASES
#===============================================================================

test_config_overrides_agent() {
    log_test "Testing --config overrides --agent"

    setup_custom_config

    local output

    # Provide both --agent and --config
    # --config should win
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --agent claude \
        --config "$TEST_PROJECT/my-custom-agent.yaml" \
        --task "test" \
        --dry-run 2>&1) || true

    # Should use the custom config, not claude
    assert_contains "$output" "my-custom-agent.yaml" "Should use custom config file"
    assert_not_contains "$output" "configs/claude.yaml" "Should NOT use claude.yaml"
}

test_agent_name_from_custom_config() {
    log_test "Testing agent name extracted from custom config filename"

    setup_custom_config

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --config "$TEST_PROJECT/my-custom-agent.yaml" \
        --task "test" \
        --dry-run 2>&1) || true

    # Agent name should be extracted from filename
    assert_contains "$output" "MY-CUSTOM-AGENT" "Agent name should be derived from config filename"
}

test_config_not_found_error() {
    log_test "Testing error when --config file not found"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --config "/nonexistent/path/config.yaml" \
        --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail when config not found"
    assert_contains "$output" "not found" "Should indicate file not found"
}

test_config_with_path() {
    log_test "Testing --config with absolute path"

    setup_custom_config

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --config "$TEST_PROJECT/my-custom-agent.yaml" \
        --task "test" \
        --dry-run 2>&1) || true

    # Should show full path
    assert_contains "$output" "$TEST_PROJECT/my-custom-agent.yaml" "Should show config path"
}

test_config_resources_applied() {
    log_test "Testing config resources display in output"

    setup_custom_config

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --config "$TEST_PROJECT/my-custom-agent.yaml" \
        --task "test" \
        --dry-run 2>&1) || true

    # Without yq, defaults are used - just verify resources line exists
    # When yq is available, this would show custom 4g RAM, 2 CPUs
    assert_contains "$output" "Resources:" "Should show resources line"
    assert_contains "$output" "RAM" "Should show memory setting"
    assert_contains "$output" "CPUs" "Should show CPU setting"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: Config Override (--config vs --agent)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Setup
    setup_test_project

    # Run tests
    run_test test_config_overrides_agent
    run_test test_agent_name_from_custom_config
    run_test test_config_not_found_error
    run_test test_config_with_path
    run_test test_config_resources_applied

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
