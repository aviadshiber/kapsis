#!/usr/bin/env bash
#===============================================================================
# Tier 1 (host) test: Claude Code dispatches Kapsis hooks via settings.json
#                     (mock Anthropic API — no real credentials needed)
#
# Starts a local mock API server that speaks the Anthropic streaming protocol
# and returns a predictable Bash tool call. Claude Code executes the tool, which
# fires the PostToolUse hook, then finishes (end_turn), which fires the Stop hook.
#
# This proves Claude Code's hook machinery reads and dispatches hooks from
# settings.json without requiring a real API key or CLAUDE_CODE_OAUTH_TOKEN.
# It is therefore runnable in any CI environment after `npm install -g
# @anthropic-ai/claude-code`.
#
# Sources inject scripts from the host source tree (fast, no container). Renamed
# from test-integration-claude-hooks.sh. For tests that verify the Claude CLI
# with real API credentials see test-host-claude-live-api.sh. For tests that
# verify hook injection inside the container image see test-container-status-hooks.sh.
#
# Prerequisites:
#   claude CLI  — must be installed (npm install -g @anthropic-ai/claude-code)
#   python3     — standard library only, no pip deps
#
# Skips gracefully when prerequisites are absent.
#
# Run: ./tests/test-host-claude-mock-api.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"
HOOKS_SRC="$KAPSIS_ROOT/scripts/hooks"
MOCK_SERVER="$KAPSIS_ROOT/tests/lib/mock-api-server.py"

#===============================================================================
# Prerequisite guard — skip gracefully rather than fail
#===============================================================================

_prereqs_ok=true
if ! command -v claude &>/dev/null;  then _prereqs_ok=false; fi
if ! command -v python3 &>/dev/null; then _prereqs_ok=false; fi

if [[ "$_prereqs_ok" == "false" ]]; then
    print_test_header "Integration: Claude Code hook dispatch via mock API"
    if ! command -v claude &>/dev/null; then
        log_skip "claude CLI not installed — skipping (npm install -g @anthropic-ai/claude-code)"
    else
        log_skip "python3 not found — skipping"
    fi
    print_summary
    exit 0
fi

#===============================================================================
# Shared setup / teardown
#===============================================================================

# Saved once at script start so a failed test that skips cleanup cannot corrupt
# the restore point for subsequent test functions.
_ORIG_HOME="$HOME"
TEST_HOME=""
TEST_WORKSPACE=""
_mock_pid=""
_mock_port=""

_start_mock_server() {
    # Let the server pick its own free port — eliminates the TOCTOU race that
    # occurs when we find a port, release the socket, and hope no one grabs it
    # before the server binds it.
    local ready_file
    ready_file=$(mktemp)

    python3 "$MOCK_SERVER" > "$ready_file" 2>&1 &
    _mock_pid=$!

    # Wait up to 3 seconds for "READY:{port}" on stdout
    local waited=0
    while [[ $waited -lt 30 ]]; do
        grep -q "^READY:" "$ready_file" 2>/dev/null && break
        sleep 0.1
        (( waited++ )) || true
    done

    local ready_line
    ready_line=$(grep "^READY:" "$ready_file" 2>/dev/null | head -1 || true)
    rm -f "$ready_file"

    if [[ -z "$ready_line" ]] || ! kill -0 "$_mock_pid" 2>/dev/null; then
        log_fail "Mock API server failed to start"
        return 1
    fi

    _mock_port="${ready_line#READY:}"
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${_mock_port}"
    export ANTHROPIC_API_KEY="mock-key-kapsis-test"
}

_stop_mock_server() {
    if [[ -n "$_mock_pid" ]]; then
        kill "$_mock_pid" 2>/dev/null || true
        wait "$_mock_pid" 2>/dev/null || true
        _mock_pid=""
    fi
    # Unset only when defined — safe under set -u
    [[ -n "${ANTHROPIC_BASE_URL+x}" ]] && unset ANTHROPIC_BASE_URL || true
    [[ -n "${ANTHROPIC_API_KEY+x}" ]]  && unset ANTHROPIC_API_KEY  || true
}

setup_mock_env() {
    # Reset any state left by a prior failed test (HOME, dirs, env vars, guards).
    # Safe to call before first test because _ORIG_HOME, TEST_HOME, and
    # TEST_WORKSPACE are initialised at script level above.
    cleanup_mock_env 2>/dev/null || true
    TEST_HOME=$(mktemp -d)
    TEST_WORKSPACE=$(mktemp -d)
    export HOME="$TEST_HOME"
    export KAPSIS_HOME="$KAPSIS_ROOT"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"

    mkdir -p "$TEST_HOME/.kapsis/logs"
    mkdir -p "$TEST_HOME/.claude"

    # Install real hook scripts at the paths inject-status-hooks.sh will write.
    # tool-phase-mapping.sh must ship alongside kapsis-status-hook.sh: it's
    # sourced from $SCRIPT_DIR (the hook's own directory) and defines
    # map_tool_to_category(), which main() calls unconditionally before
    # reaching the audit branch. Without it, kapsis-status-hook.sh aborts
    # under set -e on the undefined function before ever getting to audit.
    mkdir -p "$KAPSIS_ROOT/hooks"
    cp "$HOOKS_SRC/kapsis-gist-hook.sh"     "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-status-hook.sh"   "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-stop-hook.sh"     "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/tool-phase-mapping.sh"   "$KAPSIS_ROOT/hooks/"
    chmod +x "$KAPSIS_ROOT/hooks/"*.sh

    # Stage audit.sh/audit-patterns.sh (+ their own same-directory dependencies:
    # logging.sh, json-utils.sh, compat.sh, constants.sh) at $KAPSIS_HOME/lib/,
    # mirroring the flattened installed-container layout (KAPSIS_HOME=/opt/kapsis,
    # libs directly under lib/) that kapsis-status-hook.sh's audit branch expects
    # via `[[ -f "$KAPSIS_HOME/lib/audit.sh" ]]`. audit.sh sources its deps
    # relative to its own directory, so all of them must be staged together.
    # Without this, the audit branch is silently skipped (or aborts on a
    # missing source) in this harness since KAPSIS_HOME here is the repo
    # root, where libs live under scripts/lib/, not lib/.
    mkdir -p "$KAPSIS_ROOT/lib"
    cp "$LIB_DIR/audit.sh" "$LIB_DIR/audit-patterns.sh" \
       "$LIB_DIR/logging.sh" "$LIB_DIR/json-utils.sh" \
       "$LIB_DIR/compat.sh" "$LIB_DIR/constants.sh" \
       "$KAPSIS_ROOT/lib/"

    _start_mock_server
}

cleanup_mock_env() {
    _stop_mock_server
    export HOME="$_ORIG_HOME"
    rm -rf "${TEST_HOME:-}" "${TEST_WORKSPACE:-}" "$KAPSIS_ROOT/hooks" "${KAPSIS_ROOT:?}/lib"
    unset TEST_HOME TEST_WORKSPACE KAPSIS_HOME KAPSIS_LIB
    unset KAPSIS_STATUS_AGENT_ID KAPSIS_INJECT_GIST KAPSIS_GIST_FILE \
          KAPSIS_AUDIT_ENABLED KAPSIS_AUDIT_DIR 2>/dev/null || true
    _KAPSIS_INJECT_STATUS_HOOKS_LOADED=""
    # shellcheck disable=SC2034
    export KAPSIS_LOG_TO_FILE="false"
}

#===============================================================================
# TEST 1: PostToolUse hook fires — gist.txt written
#
# The mock API returns a Bash tool call. Claude Code executes it, which triggers
# PostToolUse. The injected kapsis-gist-hook.sh writes gist.txt. This proves
# that Claude Code reads hooks from settings.json and dispatches them — the
# exact guarantee the #351 fix provides — without any real credentials.
#===============================================================================

test_mock_posttooluse_gist_hook_fires() {
    setup_mock_env || return 1

    local agent_id="mock-e2e-$$"
    local gist_file="$TEST_HOME/.kapsis/gist.txt"
    local audit_dir="$TEST_HOME/.kapsis/audit"
    mkdir -p "$audit_dir"

    export KAPSIS_STATUS_AGENT_ID="$agent_id"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_GIST_FILE="$gist_file"
    # Exercise the real hook-dispatch path with audit logging enabled — this is
    # the crash-regression coverage for #431 (audit_log_event previously could
    # abort kapsis-status-hook.sh under set -e before its mandatory `echo "{}"`).
    export KAPSIS_AUDIT_ENABLED="true"
    export KAPSIS_AUDIT_DIR="$audit_dir"

    # Seed settings.json with allowedTools so Claude Code doesn't prompt
    printf '{"allowedTools":["Bash"]}\n' > "$TEST_HOME/.claude/settings.json"
    chmod 600 "$TEST_HOME/.claude/settings.json"

    # Inject Kapsis hooks (merges into existing settings.json, preserves allowedTools)
    # shellcheck source=/dev/null
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    assert_file_exists "$TEST_HOME/.claude/settings.json" \
        "settings.json must exist after injection"
    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" \
        "settings.local.json must NOT be created (#351 regression guard)"

    # Run Claude Code against the mock API.  The mock returns a Bash tool_use,
    # Claude Code executes it, PostToolUse hook fires, gist.txt is written.
    cd "$TEST_WORKSPACE" && \
        KAPSIS_STATUS_AGENT_ID="$agent_id" \
        KAPSIS_INJECT_GIST="true" \
        KAPSIS_GIST_FILE="$gist_file" \
        KAPSIS_AUDIT_ENABLED="true" \
        KAPSIS_AUDIT_DIR="$audit_dir" \
        ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
        ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        claude --print \
               --max-turns 3 \
               --output-format text \
               'Use the Bash tool to run: echo kapsis-mock-hook-test' \
               >/dev/null 2>&1 || true

    assert_file_exists "$gist_file" \
        "gist.txt must be written by PostToolUse hook when Claude Code uses a tool (mock API)"

    local gist_content
    gist_content=$(cat "$gist_file")
    assert_not_empty "$gist_content" "gist.txt must not be empty"

    # #431 crash-regression: kapsis-status-hook.sh must have run its audit
    # branch to completion (not aborted under set -e) and recorded a real
    # post-genesis tool-use event, not just the genesis session_start line.
    # kapsis-status-hook.sh calls audit_log_event with event_type="auto", which
    # audit.sh auto-classifies into a concrete type (e.g. "shell_command") before
    # writing — "auto" itself never appears in the JSONL. Detect a real
    # post-genesis event by tool_name instead (genesis events use
    # tool_name="audit_init"; a real tool call from Claude Code uses the
    # actual tool name, e.g. "Bash").
    local audit_files_found="false"
    local audit_file
    for audit_file in "$audit_dir"/*.audit.jsonl; do
        [[ -f "$audit_file" ]] || continue
        if grep -q '"tool_name":"Bash"' "$audit_file" 2>/dev/null; then
            audit_files_found="true"
            break
        fi
    done
    assert_equals "true" "$audit_files_found" \
        "At least one *.audit.jsonl must contain a real tool-use event (tool_name=Bash) when KAPSIS_AUDIT_ENABLED=true (mock API)"

    cleanup_mock_env
}

#===============================================================================
# TEST 2: Stop hook fires — marker file written
#
# A custom Stop hook that touches a marker file is written directly into
# settings.json. Claude Code runs, finishes (the mock returns end_turn), and
# the Stop hook fires. Proves Stop hook dispatch without touching the real
# kapsis-stop-hook.sh (which needs a status volume).
#===============================================================================

test_mock_stop_hook_fires() {
    setup_mock_env || return 1

    local stop_marker="$TEST_HOME/.kapsis/stop_fired"
    local stop_hook="$TEST_HOME/marker_stop.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "$stop_marker" > "$stop_hook"
    chmod +x "$stop_hook"

    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
        "$stop_hook" > "$TEST_HOME/.claude/settings.json"
    chmod 600 "$TEST_HOME/.claude/settings.json"

    cd "$TEST_WORKSPACE" && \
        ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
        ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        claude --print \
               --max-turns 3 \
               --output-format text \
               'Reply with only the word: done' \
               >/dev/null 2>&1 || true

    assert_file_exists "$stop_marker" \
        "Stop hook must fire when Claude Code session ends (mock API)"

    cleanup_mock_env
}

#===============================================================================
# TEST 3: PostToolUse receives tool event JSON from Claude Code
#
# A capture hook appends its stdin to a file. Claude Code sends the tool event
# JSON when calling the PostToolUse hook. Verifies the JSON structure matches
# what kapsis-gist-hook.sh and kapsis-status-hook.sh expect to parse.
#===============================================================================

test_mock_posttooluse_receives_tool_event_json() {
    setup_mock_env || return 1

    local capture="$TEST_HOME/.kapsis/capture.json"
    local capture_hook="$TEST_HOME/capture.sh"
    printf '#!/usr/bin/env bash\ncat >> "%s"\n' "$capture" > "$capture_hook"
    chmod +x "$capture_hook"

    printf '{"allowedTools":["Bash"],"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}]}}\n' \
        "$capture_hook" > "$TEST_HOME/.claude/settings.json"
    chmod 600 "$TEST_HOME/.claude/settings.json"

    cd "$TEST_WORKSPACE" && \
        ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
        ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        claude --print \
               --max-turns 3 \
               --output-format text \
               'Use the Bash tool to run: echo kapsis-capture-test' \
               >/dev/null 2>&1 || true

    assert_file_exists "$capture" \
        "Capture file must be written when Claude Code dispatches PostToolUse (mock API)"

    local captured
    captured=$(cat "$capture")
    assert_contains "$captured" "tool_name" \
        "PostToolUse payload must contain tool_name"
    assert_contains "$captured" "tool_input" \
        "PostToolUse payload must contain tool_input"

    cleanup_mock_env
}

#===============================================================================
# Run
#===============================================================================

run_tests() {
    print_test_header "Integration: Claude Code hook dispatch via mock API"

    run_test test_mock_posttooluse_gist_hook_fires
    run_test test_mock_stop_hook_fires
    run_test test_mock_posttooluse_receives_tool_event_json

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
