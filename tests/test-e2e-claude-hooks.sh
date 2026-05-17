#!/usr/bin/env bash
#===============================================================================
# E2E test: Claude Code reads settings.json and dispatches Kapsis hooks
#
# Unlike the integration tests (test-integration-gist-hook.sh,
# test-integration-all-hooks.sh) which invoke hook scripts directly, this test
# starts a real Claude Code process and verifies that Claude Code itself reads
# hooks from settings.json and dispatches them during a live agent session.
#
# Prerequisites:
#   CLAUDE_CODE_OAUTH_TOKEN — must be set (add to GitHub Secrets for CI)
#   claude CLI              — must be installed (npm install -g @anthropic-ai/claude-code)
#
# Skips gracefully when prerequisites are absent.
#
# Run: ./tests/test-e2e-claude-hooks.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
HOOKS_SRC="$KAPSIS_ROOT/scripts/hooks"

#===============================================================================
# Prerequisite guard — skip gracefully rather than fail
#===============================================================================

_prerequisites_met=true

if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    _prerequisites_met=false
fi

if ! command -v claude &>/dev/null; then
    _prerequisites_met=false
fi

if [[ "$_prerequisites_met" == "false" ]]; then
    print_test_header "E2E: Claude Code hook dispatch (live API)"
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        log_skip "CLAUDE_CODE_OAUTH_TOKEN not set — skipping real Claude Code e2e tests"
    else
        log_skip "claude CLI not installed — skipping (npm install -g @anthropic-ai/claude-code)"
    fi
    print_summary
    exit 0
fi

#===============================================================================
# Shared setup / teardown
#===============================================================================

_REAL_ORIG_HOME=""

setup_real_env() {
    _REAL_ORIG_HOME="$HOME"
    TEST_HOME=$(mktemp -d)
    TEST_WORKSPACE=$(mktemp -d)
    export HOME="$TEST_HOME"
    export KAPSIS_HOME="$KAPSIS_ROOT"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"

    mkdir -p "$TEST_HOME/.kapsis/logs"
    mkdir -p "$TEST_HOME/.claude"

    # Install real hook scripts at the paths inject-status-hooks.sh will write
    mkdir -p "$KAPSIS_ROOT/hooks"
    cp "$HOOKS_SRC/kapsis-gist-hook.sh"   "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-status-hook.sh" "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-stop-hook.sh"   "$KAPSIS_ROOT/hooks/"
    chmod +x "$KAPSIS_ROOT/hooks/"*.sh
}

cleanup_real_env() {
    export HOME="$_REAL_ORIG_HOME"
    rm -rf "${TEST_HOME:-}" "${TEST_WORKSPACE:-}" "$KAPSIS_ROOT/hooks"
    unset TEST_HOME TEST_WORKSPACE KAPSIS_HOME KAPSIS_LIB
    unset KAPSIS_STATUS_AGENT_ID KAPSIS_INJECT_GIST KAPSIS_GIST_FILE 2>/dev/null || true
    _KAPSIS_INJECT_STATUS_HOOKS_LOADED=""
    # shellcheck disable=SC2034
    export KAPSIS_LOG_TO_FILE="false"
}

#===============================================================================
# TEST 1: PostToolUse hook dispatched by Claude Code — gist.txt written
#
# Injects the real Kapsis gist hook via inject-status-hooks.sh (which writes
# to settings.json). Runs Claude Code with a prompt that forces a Bash tool
# call. Asserts that gist.txt was written — which can ONLY happen if Claude
# Code read hooks from settings.json and dispatched the PostToolUse hook. If
# the hooks were in settings.local.json (the #351 bug), this file would stay
# absent forever.
#===============================================================================

test_real_posttooluse_gist_hook_fires() {
    setup_real_env

    local agent_id="real-e2e-$$"
    local gist_file="$TEST_HOME/.kapsis/gist.txt"

    export KAPSIS_STATUS_AGENT_ID="$agent_id"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_GIST_FILE="$gist_file"

    # Inject Kapsis hooks into settings.json (the fix for #351)
    # shellcheck source=/dev/null
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    assert_file_exists "$TEST_HOME/.claude/settings.json" \
        "settings.json must exist after injection"
    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" \
        "settings.local.json must NOT be created (#351 regression guard)"

    # Run Claude Code with a Bash-forcing prompt.
    # --model: cheapest model to minimise CI cost (~$0.001 per run)
    # --max-turns 3: cap agentic loop to avoid runaway sessions
    # --output-format text: suppress streaming JSON noise
    cd "$TEST_WORKSPACE" && \
        KAPSIS_STATUS_AGENT_ID="$agent_id" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$gist_file" \
        claude --print \
               --model claude-haiku-4-5-20251001 \
               --max-turns 3 \
               --output-format text \
               'Use the Bash tool to run this exact command: echo kapsis-real-hook-test' \
               >/dev/null 2>&1 || true

    # gist.txt can only exist if Claude Code read hooks from settings.json and
    # dispatched the PostToolUse hook — this is the end-to-end proof of #351 fix.
    assert_file_exists "$gist_file" \
        "gist.txt must be written by the PostToolUse hook dispatched by Claude Code via settings.json"

    local gist_content
    gist_content=$(cat "$gist_file")
    assert_not_empty "$gist_content" "gist.txt must contain non-empty hook output"

    cleanup_real_env
}

#===============================================================================
# TEST 2: Stop hook dispatched by Claude Code — marker file written
#
# Writes a minimal custom Stop hook (touches a marker file) directly into
# settings.json, then runs Claude Code with a prompt that requires no tool
# calls (just a text response). Asserts that the marker file exists when the
# session ends — proving Claude Code dispatches Stop hooks from settings.json.
#
# Uses a custom script (not the real kapsis-stop-hook.sh) so the test does not
# depend on a Kapsis status volume being present in CI.
#===============================================================================

test_real_stop_hook_fires() {
    setup_real_env

    local stop_marker="$TEST_HOME/.kapsis/stop_hook_fired"

    # Minimal stop hook: just touches a marker file
    local stop_hook_script="$TEST_HOME/marker_stop_hook.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "$stop_marker" > "$stop_hook_script"
    chmod +x "$stop_hook_script"

    # Write settings.json with only the custom stop hook
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
        "$stop_hook_script" > "$TEST_HOME/.claude/settings.json"
    chmod 600 "$TEST_HOME/.claude/settings.json"

    # Run Claude Code — no tool call needed; Stop hook fires when session ends
    cd "$TEST_WORKSPACE" && \
        claude --print \
               --model claude-haiku-4-5-20251001 \
               --max-turns 1 \
               --output-format text \
               'Reply with only the word: done' \
               >/dev/null 2>&1 || true

    assert_file_exists "$stop_marker" \
        "Stop hook marker must be written when Claude Code dispatches the Stop hook from settings.json"

    cleanup_real_env
}

#===============================================================================
# TEST 3: PostToolUse hook receives tool event JSON from Claude Code
#
# Writes a custom PostToolUse hook that appends its stdin (the tool event JSON
# Claude Code passes to hooks) to a capture file. Verifies both that the hook
# fires AND that Claude Code passes a valid tool event JSON payload — matching
# the format that kapsis-gist-hook.sh and kapsis-status-hook.sh parse.
#===============================================================================

test_real_posttooluse_receives_tool_event_json() {
    setup_real_env

    local capture_file="$TEST_HOME/.kapsis/tool_event_capture.json"

    # Custom hook: append stdin to capture file
    local hook_script="$TEST_HOME/capture_hook.sh"
    printf '#!/usr/bin/env bash\ncat >> "%s"\n' "$capture_file" > "$hook_script"
    chmod +x "$hook_script"

    # Write settings.json with the custom PostToolUse hook
    printf '{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}]}}\n' \
        "$hook_script" > "$TEST_HOME/.claude/settings.json"
    chmod 600 "$TEST_HOME/.claude/settings.json"

    # Run Claude Code with a Bash-forcing prompt (guarantees PostToolUse fires)
    cd "$TEST_WORKSPACE" && \
        claude --print \
               --model claude-haiku-4-5-20251001 \
               --max-turns 3 \
               --output-format text \
               'Use the Bash tool to run: echo kapsis-posttooluse-test' \
               >/dev/null 2>&1 || true

    assert_file_exists "$capture_file" \
        "Capture file must be written by PostToolUse hook when Claude Code uses a tool"

    # Claude Code passes a JSON payload on stdin — same format Kapsis hooks parse
    local captured
    captured=$(cat "$capture_file")
    assert_contains "$captured" "tool_name" \
        "PostToolUse payload from Claude Code must contain tool_name field"
    assert_contains "$captured" "tool_input" \
        "PostToolUse payload from Claude Code must contain tool_input field"

    cleanup_real_env
}

#===============================================================================
# Run
#===============================================================================

run_tests() {
    print_test_header "E2E: Claude Code hook dispatch (live API)"

    run_test test_real_posttooluse_gist_hook_fires
    run_test test_real_stop_hook_fires
    run_test test_real_posttooluse_receives_tool_event_json

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
