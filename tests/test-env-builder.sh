#!/usr/bin/env bash
#===============================================================================
# Test: Environment Variable Builder (scripts/lib/env-builder.sh)
#
# Unit tests for environment variable generation:
#   - _env_process_passthrough() — passthrough env vars
#   - _env_is_already_set() — duplicate detection
#   - _env_add_kapsis_core() — core env vars
#   - _env_resolve_agent_type() — agent type resolution
#   - generate_env_vars() — orchestrator
#
# Tests the split env-builder that was extracted from launch-agent.sh.
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source dependencies
source "$KAPSIS_ROOT/scripts/lib/logging.sh"
log_init "test-env-builder"

# Source constants for default values
source "$KAPSIS_ROOT/scripts/lib/constants.sh"

# Mock secret store query (not available in test environment)
query_secret_store_with_fallbacks() { return 1; }

# Source the library under test
source "$KAPSIS_ROOT/scripts/lib/env-builder.sh"

#===============================================================================
# SETUP
#===============================================================================

# shellcheck disable=SC2034  # Globals consumed by sourced env-builder.sh library
setup_env_vars() {
    # Reset global arrays
    ENV_VARS=()
    SECRET_ENV_VARS=()
    ENV_PASSTHROUGH=""
    ENV_KEYCHAIN=""
    ENV_SET=""
    AGENT_ID="test-001"
    PROJECT_PATH="/tmp/test-project"
    SANDBOX_MODE="worktree"
    WORKTREE_PATH="/tmp/test-worktree"
    SANDBOX_DIR=""
    BRANCH="feature/test"
    REMOTE_BRANCH=""
    BASE_BRANCH=""
    GIT_REMOTE="origin"
    DO_PUSH="false"
    TASK_INLINE=""
    STAGED_CONFIGS=""
    CLAUDE_HOOKS_INCLUDE=""
    CLAUDE_MCP_INCLUDE=""
    INJECT_GIST=""
    CONFIG_FILE=""
    AGENT_NAME="claude"
    IMAGE_NAME="kapsis-sandbox:latest"
    KAPSIS_ROOT="/opt/kapsis"
    GLOBAL_INJECT_TO=""
}

#===============================================================================
# _env_process_passthrough() TESTS
#===============================================================================

test_passthrough_empty() {
    setup_env_vars
    ENV_PASSTHROUGH=""

    _env_process_passthrough

    assert_equals "0" "${#ENV_VARS[@]}" "Empty passthrough should add no env vars"
}

test_passthrough_existing_var() {
    setup_env_vars
    export TEST_PASSTHROUGH_VAR="hello"
    ENV_PASSTHROUGH="TEST_PASSTHROUGH_VAR"

    _env_process_passthrough

    assert_contains "${ENV_VARS[*]}" "TEST_PASSTHROUGH_VAR=hello" "Should pass through existing env var"

    unset TEST_PASSTHROUGH_VAR
}

test_passthrough_missing_var() {
    setup_env_vars
    unset NONEXISTENT_VAR 2>/dev/null || true
    ENV_PASSTHROUGH="NONEXISTENT_VAR"

    _env_process_passthrough

    assert_equals "0" "${#ENV_VARS[@]}" "Missing var should not be added"
}

test_passthrough_secret_var() {
    setup_env_vars
    export MY_SECRET_TOKEN="secret123"
    ENV_PASSTHROUGH="MY_SECRET_TOKEN"

    _env_process_passthrough

    # Secret vars go to SECRET_ENV_VARS, not ENV_VARS
    assert_contains "${SECRET_ENV_VARS[*]}" "MY_SECRET_TOKEN=secret123" "Secret var should go to SECRET_ENV_VARS"

    unset MY_SECRET_TOKEN
}

#===============================================================================
# _env_is_already_set() TESTS
#===============================================================================

test_is_already_set_true() {
    setup_env_vars
    ENV_VARS+=("-e" "MY_VAR=value")

    local result=0
    _env_is_already_set "MY_VAR" || result=$?
    assert_equals "0" "$result" "Should detect existing var in ENV_VARS"
}

test_is_already_set_false() {
    setup_env_vars

    local result=0
    _env_is_already_set "NONEXISTENT_VAR" || result=$?
    assert_equals "1" "$result" "Should not find nonexistent var"
}

#===============================================================================
# _env_add_kapsis_core() TESTS
#===============================================================================

test_add_kapsis_core() {
    setup_env_vars

    _env_add_kapsis_core

    local joined="${ENV_VARS[*]}"
    assert_contains "$joined" "KAPSIS_AGENT_ID=test-001" "Should set KAPSIS_AGENT_ID"
    assert_contains "$joined" "KAPSIS_SANDBOX_MODE=worktree" "Should set KAPSIS_SANDBOX_MODE"
}

#===============================================================================
# _env_resolve_agent_type() TESTS
#===============================================================================

test_resolve_agent_type_claude() {
    setup_env_vars
    AGENT_NAME="claude"

    _env_resolve_agent_type

    local joined="${ENV_VARS[*]}"
    assert_contains "$joined" "KAPSIS_AGENT_TYPE=" "Should set agent type"
}

#===============================================================================
# generate_env_vars() TESTS
#===============================================================================

test_generate_env_vars_basic() {
    setup_env_vars

    generate_env_vars

    local joined="${ENV_VARS[*]}"
    assert_contains "$joined" "KAPSIS_AGENT_ID=test-001" "Should include core vars"
    assert_contains "$joined" "KAPSIS_BRANCH=feature/test" "Should include branch"
}

#===============================================================================
# GUARD TESTS
#===============================================================================

test_guard_prevents_double_source() {
    assert_equals "1" "$_KAPSIS_ENV_BUILDER_LOADED" "Guard variable should be set to 1"
}

#===============================================================================
# RUN
#===============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo "TEST: Environment Variable Builder (scripts/lib/env-builder.sh)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Passthrough tests
run_test test_passthrough_empty
run_test test_passthrough_existing_var
run_test test_passthrough_missing_var
run_test test_passthrough_secret_var

# Duplicate detection tests
run_test test_is_already_set_true
run_test test_is_already_set_false

# Core env vars
run_test test_add_kapsis_core

# Agent type resolution
run_test test_resolve_agent_type_claude

# Full orchestrator
run_test test_generate_env_vars_basic

# Guard
run_test test_guard_prevents_double_source

print_summary
