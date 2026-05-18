#!/usr/bin/env bash
#===============================================================================
# Integration test: gist hook fires when invoked via settings.json (#351)
#
# Regression guard for issue #351: inject-status-hooks.sh was writing hooks to
# ~/.claude/settings.local.json, which Claude Code ignores at user scope. At
# user scope only settings.json is loaded. This test exercises the full
# injection → hook-dispatch pipeline to prove the fix is correct:
#
#   1. inject_claude_hooks() writes hooks to settings.json (not .local.json)
#   2. Hook commands read from settings.json are executable
#   3. Dispatching the gist hook (as Claude Code would on PostToolUse) writes
#      gist.txt — the behavior that was silently broken before the fix
#
# Note: hooks are invoked directly (not via Claude Code). For tests that run
# a real Claude Code process see test-e2e-claude-hooks.sh.
#
# Run: ./tests/test-integration-gist-hook.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
HOOKS_SRC="$KAPSIS_ROOT/scripts/hooks"

#===============================================================================
# Shared setup / teardown
#===============================================================================

# Saved once at script start so a failed test that skips cleanup cannot corrupt
# the restore point for subsequent test functions.
_E2E_ORIG_HOME="$HOME"

setup_e2e_env() {
    # Defensive: remove any stale hooks dir left by a prior failed cleanup before
    # creating a fresh copy, so tests never see residue from previous runs.
    rm -rf "$KAPSIS_ROOT/hooks" 2>/dev/null || true
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    export KAPSIS_HOME="$KAPSIS_ROOT"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"

    mkdir -p "$TEST_HOME/.kapsis/logs"

    # Populate $KAPSIS_ROOT/hooks/ with the real hook scripts so that the
    # injected command paths point to working binaries.
    mkdir -p "$KAPSIS_ROOT/hooks"
    cp "$HOOKS_SRC/kapsis-gist-hook.sh" "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-status-hook.sh" "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-stop-hook.sh" "$KAPSIS_ROOT/hooks/"
    chmod +x "$KAPSIS_ROOT/hooks/"*.sh
}

cleanup_e2e_env() {
    export HOME="$_E2E_ORIG_HOME"
    rm -rf "$TEST_HOME" "$KAPSIS_ROOT/hooks"
    unset TEST_HOME KAPSIS_HOME KAPSIS_LIB
    _KAPSIS_LOG_FILE_PATH=""
    # shellcheck disable=SC2034
    export KAPSIS_LOG_TO_FILE="false"
    unset KAPSIS_INJECT_GIST 2>/dev/null || true
    unset KAPSIS_STATUS_AGENT_ID 2>/dev/null || true
    unset _KAPSIS_INJECT_STATUS_HOOKS_LOADED 2>/dev/null || true
}

#===============================================================================
# TEST 1: Hooks land in settings.json, never in settings.local.json (#351)
#===============================================================================

test_e2e_hooks_written_to_settings_json_not_local() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-agent-$$"
    export KAPSIS_INJECT_GIST="true"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # The fix: hooks must be in settings.json (the file Claude Code loads at
    # user scope), not in settings.local.json (which Claude Code ignores there).
    assert_file_exists "$TEST_HOME/.claude/settings.json" \
        "settings.json must exist after hook injection"
    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" \
        "settings.local.json must NOT be created — Claude Code ignores it at user scope (#351)"

    # Hooks must be present in the correct file
    local content
    content=$(cat "$TEST_HOME/.claude/settings.json")
    assert_contains "$content" "kapsis-gist-hook.sh" \
        "gist hook must be in settings.json"
    assert_contains "$content" "kapsis-status-hook.sh" \
        "status hook must be in settings.json"
    assert_contains "$content" "kapsis-stop-hook.sh" \
        "stop hook must be in settings.json"

    cleanup_e2e_env
}

#===============================================================================
# TEST 2: Hook commands read from settings.json are executable binaries
#===============================================================================

test_e2e_hook_commands_are_executable() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-agent-$$"
    export KAPSIS_INJECT_GIST="true"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Simulate what Claude Code does: read hook commands from settings.json
    local gist_cmd status_cmd stop_cmd
    gist_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' \
                   "$TEST_HOME/.claude/settings.json")
    status_cmd=$(jq -r '.hooks.PostToolUse[1].hooks[0].command' \
                    "$TEST_HOME/.claude/settings.json")
    stop_cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' \
                   "$TEST_HOME/.claude/settings.json")

    assert_true "[[ -x '$gist_cmd' ]]" \
        "Gist hook command read from settings.json must be executable"
    assert_true "[[ -x '$status_cmd' ]]" \
        "Status hook command read from settings.json must be executable"
    assert_true "[[ -x '$stop_cmd' ]]" \
        "Stop hook command read from settings.json must be executable"

    cleanup_e2e_env
}

#===============================================================================
# TEST 3: E2E — gist.txt is written when hook is invoked via settings.json path
#
# This is the core regression test for #351. Before the fix, hooks were in
# settings.local.json (ignored), so this invocation would never happen and
# gist.txt would remain null forever. After the fix, Claude Code reads the
# hook command from settings.json and invokes it — which we simulate here.
#===============================================================================

test_e2e_gist_written_when_hook_dispatched_from_settings_json() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-agent-$$"
    export KAPSIS_INJECT_GIST="true"

    local gist_file="$TEST_HOME/.kapsis/gist.txt"

    # Step 1: Inject hooks (writes to settings.json after the fix)
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Step 2: Read the gist hook command from settings.json — exactly as
    # Claude Code does after loading its settings file
    local gist_cmd
    gist_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' \
                   "$TEST_HOME/.claude/settings.json")

    assert_contains "$gist_cmd" "kapsis-gist-hook.sh" \
        "First PostToolUse hook must be the gist hook"

    # Step 3: Dispatch the hook with a tool event (simulating Claude Code's
    # PostToolUse trigger on a git commit call)
    local tool_event='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: null gist regression\""}}'
    printf '%s' "$tool_event" | \
        KAPSIS_STATUS_AGENT_ID="e2e-agent-$$" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$gist_file" \
        bash "$gist_cmd" >/dev/null 2>&1 || true

    # Step 4: Verify gist.txt was written — the observable behaviour that was
    # silently broken when hooks were injected into settings.local.json
    assert_file_exists "$gist_file" \
        "gist.txt must be written when gist hook is dispatched via command read from settings.json"

    local gist_content
    gist_content=$(cat "$gist_file")
    assert_contains "$gist_content" "Committing:" \
        "Gist must reflect the git-commit action"
    assert_contains "$gist_content" "null gist regression" \
        "Gist must include the commit message"

    cleanup_e2e_env
}

#===============================================================================
# TEST 4: E2E — status hook invoked via settings.json path exits 0 (smoke test)
#===============================================================================

test_e2e_status_hook_invocable_from_settings_json() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-agent-$$"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Read the status hook command from settings.json (gist disabled → index 0 is status hook)
    local status_cmd
    status_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' \
                    "$TEST_HOME/.claude/settings.json")

    assert_contains "$status_cmd" "kapsis-status-hook.sh" \
        "PostToolUse[0] must be the status hook when gist is disabled"

    # Invoke with empty agent ID: hook validates and exits 0 without touching
    # any status volume. Proves the binary is reachable and executable via the
    # command path written to settings.json.
    local exit_code=0
    printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/workspace/foo.java"}}' | \
        KAPSIS_STATUS_AGENT_ID="" \
        bash "$status_cmd" >/dev/null 2>&1 || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Status hook invoked from command read from settings.json must exit 0"

    cleanup_e2e_env
}

#===============================================================================
# TEST 5: Regression — settings.local.json is never created even with gist disabled
#===============================================================================

test_e2e_no_settings_local_json_created_gist_disabled() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-agent-$$"
    # KAPSIS_INJECT_GIST not set (defaults to false)

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" \
        "settings.local.json must never be created (regression guard for #351)"
    assert_file_exists "$TEST_HOME/.claude/settings.json" \
        "settings.json must exist after injection even when gist is disabled"

    cleanup_e2e_env
}

#===============================================================================
# Run
#===============================================================================

run_tests() {
    print_test_header "Integration: Gist hook fires via settings.json (#351 regression guard)"

    run_test test_e2e_hooks_written_to_settings_json_not_local
    run_test test_e2e_hook_commands_are_executable
    run_test test_e2e_gist_written_when_hook_dispatched_from_settings_json
    run_test test_e2e_status_hook_invocable_from_settings_json
    run_test test_e2e_no_settings_local_json_created_gist_disabled

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
