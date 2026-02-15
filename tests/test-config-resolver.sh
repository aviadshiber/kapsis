#!/usr/bin/env bash
#===============================================================================
# Test: Configuration Resolver Library (scripts/lib/config-resolver.sh)
#
# Unit tests for the unified config resolution functions:
#   - resolve_agent_config() — agent config with 7-location fallback
#   - resolve_build_config_file() — build config with 3-priority search
#
# These functions eliminate duplication across launch-agent.sh,
# build-image.sh, and build-agent-image.sh.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source dependencies
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-config-resolver"

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/config-resolver.sh"

# Temp dirs for test fixtures
FIXTURE_DIR=""

#===============================================================================
# SETUP / TEARDOWN
#===============================================================================

setup_fixtures() {
    FIXTURE_DIR=$(mktemp -d)

    # Create mock Kapsis root with agent configs
    mkdir -p "$FIXTURE_DIR/kapsis-root/configs/agents"
    mkdir -p "$FIXTURE_DIR/kapsis-root/configs/build-profiles"
    echo "agent: claude" > "$FIXTURE_DIR/kapsis-root/configs/claude.yaml"
    echo "agent: codex" > "$FIXTURE_DIR/kapsis-root/configs/codex.yaml"
    echo "agent: aider" > "$FIXTURE_DIR/kapsis-root/configs/aider.yaml"

    # Create mock project directory
    mkdir -p "$FIXTURE_DIR/project"
    mkdir -p "$FIXTURE_DIR/project/.kapsis"

    # Create build profiles
    echo "profile: java-dev" > "$FIXTURE_DIR/kapsis-root/configs/build-profiles/java-dev.yaml"
    echo "profile: minimal" > "$FIXTURE_DIR/kapsis-root/configs/build-profiles/minimal.yaml"

    # Create default build config
    echo "default: true" > "$FIXTURE_DIR/kapsis-root/configs/build-config.yaml"
}

cleanup_fixtures() {
    [[ -n "${FIXTURE_DIR:-}" ]] && rm -rf "$FIXTURE_DIR"
}

#===============================================================================
# resolve_agent_config() TESTS
#===============================================================================

test_resolve_explicit_config() {
    setup_fixtures

    local explicit_config="$FIXTURE_DIR/kapsis-root/configs/claude.yaml"
    local resolved_config=""
    local resolved_agent=""

    resolve_agent_config "$explicit_config" "" "$FIXTURE_DIR/project" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_equals "$explicit_config" "$resolved_config" "Should use explicit config path"
    assert_equals "claude" "$resolved_agent" "Should extract agent name from config filename"

    cleanup_fixtures
}

test_resolve_explicit_config_with_agent() {
    setup_fixtures

    local explicit_config="$FIXTURE_DIR/kapsis-root/configs/claude.yaml"
    local resolved_config=""
    local resolved_agent=""

    resolve_agent_config "$explicit_config" "my-agent" "$FIXTURE_DIR/project" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_equals "$explicit_config" "$resolved_config" "Should use explicit config path"
    assert_equals "my-agent" "$resolved_agent" "Should prefer explicit agent name over filename"

    cleanup_fixtures
}

test_resolve_agent_shortcut() {
    setup_fixtures

    local resolved_config=""
    local resolved_agent=""

    resolve_agent_config "" "claude" "$FIXTURE_DIR/project" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_equals "$FIXTURE_DIR/kapsis-root/configs/claude.yaml" "$resolved_config" "Should find agent config by shortcut"
    assert_equals "claude" "$resolved_agent" "Should set agent name from shortcut"

    cleanup_fixtures
}

test_resolve_agent_sandbox_yaml() {
    setup_fixtures

    # Create agent-sandbox.yaml in current directory
    local saved_dir
    saved_dir=$(pwd)
    cd "$FIXTURE_DIR/project"
    echo "agent: custom" > agent-sandbox.yaml

    local resolved_config=""
    local resolved_agent=""

    resolve_agent_config "" "" "$FIXTURE_DIR/project" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_contains "$resolved_config" "agent-sandbox.yaml" "Should find agent-sandbox.yaml"

    cd "$saved_dir"
    cleanup_fixtures
}

test_resolve_project_kapsis_config() {
    setup_fixtures

    echo "agent: project-config" > "$FIXTURE_DIR/project/.kapsis/config.yaml"

    # Ensure no agent-sandbox.yaml exists in the resolution locations
    local saved_dir
    saved_dir=$(pwd)
    cd "$FIXTURE_DIR"

    local resolved_config=""
    local resolved_agent=""

    resolve_agent_config "" "" "$FIXTURE_DIR/project" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_contains "$resolved_config" ".kapsis/config.yaml" "Should find project .kapsis/config.yaml"

    cd "$saved_dir"
    cleanup_fixtures
}

test_resolve_fallback_to_default() {
    setup_fixtures

    # Use a directory with no config files as CWD
    local saved_dir
    saved_dir=$(pwd)
    cd "$FIXTURE_DIR"

    local resolved_config=""
    local resolved_agent=""

    # No agent-sandbox.yaml, no .kapsis/config.yaml → falls through to default
    resolve_agent_config "" "" "/nonexistent" "$FIXTURE_DIR/kapsis-root" resolved_config resolved_agent

    assert_contains "$resolved_config" "claude.yaml" "Should fall back to default claude.yaml"
    assert_equals "claude" "$resolved_agent" "Should default to claude agent"

    cd "$saved_dir"
    cleanup_fixtures
}

#===============================================================================
# resolve_build_config_file() TESTS
#===============================================================================

test_resolve_build_explicit_config() {
    setup_fixtures

    local resolved=""
    resolve_build_config_file "$FIXTURE_DIR/kapsis-root/configs/build-config.yaml" "" "$FIXTURE_DIR/kapsis-root" resolved

    assert_equals "$FIXTURE_DIR/kapsis-root/configs/build-config.yaml" "$resolved" "Should use explicit build config"

    cleanup_fixtures
}

test_resolve_build_profile() {
    setup_fixtures

    local resolved=""
    resolve_build_config_file "" "java-dev" "$FIXTURE_DIR/kapsis-root" resolved

    assert_equals "$FIXTURE_DIR/kapsis-root/configs/build-profiles/java-dev.yaml" "$resolved" "Should resolve profile to build-profiles dir"

    cleanup_fixtures
}

test_resolve_build_default() {
    setup_fixtures

    local resolved=""
    resolve_build_config_file "" "" "$FIXTURE_DIR/kapsis-root" resolved

    assert_equals "$FIXTURE_DIR/kapsis-root/configs/build-config.yaml" "$resolved" "Should find default build config"

    cleanup_fixtures
}

test_resolve_build_no_default() {
    FIXTURE_DIR=$(mktemp -d)
    mkdir -p "$FIXTURE_DIR/kapsis-root/configs"
    # No build-config.yaml

    local resolved=""
    resolve_build_config_file "" "" "$FIXTURE_DIR/kapsis-root" resolved

    assert_equals "" "$resolved" "Should return empty when no default config exists"

    cleanup_fixtures
}

#===============================================================================
# GUARD TESTS
#===============================================================================

test_guard_prevents_double_source() {
    assert_equals "1" "$_KAPSIS_CONFIG_RESOLVER_LOADED" "Guard variable should be set to 1"
}

#===============================================================================
# RUN
#===============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo "TEST: Configuration Resolver Library (scripts/lib/config-resolver.sh)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# resolve_agent_config tests
run_test test_resolve_explicit_config
run_test test_resolve_explicit_config_with_agent
run_test test_resolve_agent_shortcut
run_test test_resolve_agent_sandbox_yaml
run_test test_resolve_project_kapsis_config
run_test test_resolve_fallback_to_default

# resolve_build_config_file tests
run_test test_resolve_build_explicit_config
run_test test_resolve_build_profile
run_test test_resolve_build_default
run_test test_resolve_build_no_default

# Guard test
run_test test_guard_prevents_double_source

print_summary
