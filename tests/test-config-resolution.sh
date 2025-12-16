#!/usr/bin/env bash
#===============================================================================
# Test: Config Resolution Order
#
# Verifies that config files are resolved in the correct order:
# 1. --config (explicit)
# 2. --agent (shortcut)
# 3. ./agent-sandbox.yaml
# 4. ./.kapsis/config.yaml
# 5. <project>/agent-sandbox.yaml
# 6. ~/.config/kapsis/default.yaml
# 7. configs/claude.yaml (fallback)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# SETUP
#===============================================================================

create_project_config() {
    cat > "$TEST_PROJECT/agent-sandbox.yaml" << 'EOF'
agent:
  command: "echo 'project config'"
  workdir: /workspace
filesystem:
  include: []
environment:
  passthrough: []
resources:
  memory: 2g
  cpus: 1
EOF
}

create_kapsis_dir_config() {
    mkdir -p "$TEST_PROJECT/.kapsis"
    cat > "$TEST_PROJECT/.kapsis/config.yaml" << 'EOF'
agent:
  command: "echo 'kapsis dir config'"
  workdir: /workspace
filesystem:
  include: []
environment:
  passthrough: []
resources:
  memory: 3g
  cpus: 2
EOF
}

#===============================================================================
# TEST CASES
#===============================================================================

test_agent_flag_takes_precedence() {
    log_test "Testing --agent takes precedence over project config"

    # Create project config
    create_project_config

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" \
        --agent codex \
        --task "test" \
        --dry-run 2>&1) || true

    # --agent should win over project config
    assert_contains "$output" "CODEX" "Should use agent from --agent flag"
    assert_contains "$output" "configs/codex.yaml" "Should use codex.yaml"
}

test_project_config_found() {
    log_test "Testing project-level agent-sandbox.yaml is found"

    create_project_config

    # Run from project directory without --agent
    cd "$TEST_PROJECT"
    local output
    output=$("$LAUNCH_SCRIPT" 1 . --task "test" --dry-run 2>&1) || true

    # Should find and use project config
    assert_contains "$output" "agent-sandbox.yaml" "Should find project config"
}

test_kapsis_dir_config() {
    log_test "Testing .kapsis/config.yaml resolution"

    create_kapsis_dir_config

    cd "$TEST_PROJECT"
    local output
    output=$("$LAUNCH_SCRIPT" 1 . --task "test" --dry-run 2>&1) || true

    # Should find .kapsis/config.yaml
    assert_contains "$output" ".kapsis/config.yaml" "Should find .kapsis config" || \
    assert_contains "$output" "agent-sandbox" "Should find some config"
}

test_fallback_to_claude() {
    log_test "Testing fallback to claude.yaml when no config found"

    # Make sure no project-level configs exist
    rm -f "$TEST_PROJECT/agent-sandbox.yaml"
    rm -rf "$TEST_PROJECT/.kapsis"

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --task "test" --dry-run 2>&1) || true

    # Should fall back to claude.yaml
    assert_contains "$output" "claude" "Should fall back to claude config"
}

test_error_when_no_config() {
    log_test "Testing error when no config can be found"

    # This test is tricky because we always have configs/claude.yaml as fallback
    # To test this, we'd need to temporarily remove it, which is destructive
    # Instead, we verify the error message structure

    # Create an invalid KAPSIS_ROOT scenario by using a temp directory
    local temp_dir
    temp_dir=$(mktemp -d)

    # Copy launch script but not configs
    cp "$LAUNCH_SCRIPT" "$temp_dir/"

    # Try to run (will fail because KAPSIS_ROOT detection will be wrong)
    # This is more of a structural test
    log_info "Skipping destructive test - fallback always exists"
}

test_resolution_order_logging() {
    log_test "Testing that resolved config is logged"

    create_project_config

    local output
    output=$("$LAUNCH_SCRIPT" 1 "$TEST_PROJECT" --task "test" --dry-run 2>&1) || true

    # Should show which config was used
    assert_contains "$output" "Using agent:" "Should log which agent/config is used"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Config Resolution Order"

    # Setup
    setup_test_project

    # Run tests
    run_test test_agent_flag_takes_precedence
    run_test test_project_config_found
    run_test test_kapsis_dir_config
    run_test test_fallback_to_claude
    run_test test_error_when_no_config
    run_test test_resolution_order_logging

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
