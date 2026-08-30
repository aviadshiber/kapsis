#!/usr/bin/env bash
#===============================================================================
# Test: Agent Shortcut (--agent flag)
#
# Verifies that the --agent shortcut correctly resolves to config files
# and displays the agent name in output.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_agent_claude() {
    log_test "Testing --agent claude"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "CLAUDE" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/claude.yaml" "Should use claude.yaml config"
}

test_agent_codex() {
    log_test "Testing --agent codex"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent codex --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "CODEX" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/codex.yaml" "Should use codex.yaml config"
}

test_agent_gemini() {
    log_test "Testing --agent gemini"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent gemini --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "GEMINI" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/gemini.yaml" "Should use gemini.yaml config"
}

test_agent_codex_binds_codex_image() {
    log_test "Testing --agent codex selects the codex provider image"

    # Unset KAPSIS_IMAGE: CI's container-test job exports it (kapsis-test:ci), which
    # would override the config's image and mask the binding we are asserting.
    local output
    output=$(env -u KAPSIS_IMAGE "$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent codex --task "test" --dry-run 2>&1) || true

    # Image binding is the linchpin fix: without an image: block in the config,
    # the codex command would run in kapsis-sandbox (no codex binary).
    assert_contains "$output" "kapsis-codex-cli" "codex config must select the kapsis-codex-cli image"
    assert_contains "$output" "codex exec" "codex config must run the non-interactive 'codex exec' command"
}

test_agent_gemini_binds_gemini_image() {
    log_test "Testing --agent gemini selects the gemini provider image"

    local output
    output=$(env -u KAPSIS_IMAGE "$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent gemini --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "kapsis-gemini-cli" "gemini config must select the kapsis-gemini-cli image"
    assert_contains "$output" "skip-trust" "gemini config must pass --skip-trust for headless runs"
}

test_agent_codex_stages_only_oauth_file() {
    log_test "Testing codex.yaml injects ONLY the OAuth session file (security regression guard)"

    # Inspect the config directly (deterministic; does not depend on a host ~/.codex
    # login, which CI runners lack — a dry-run would silently skip absent includes).
    local inc
    inc=$(yq -r '.filesystem.include[]' "$KAPSIS_ROOT/configs/codex.yaml" 2>/dev/null || echo "")

    assert_contains "$inc" ".codex/auth.json" "must include the OAuth session file"
    # config.toml can carry MCP `env` secrets + hook commands — must not be injected.
    assert_not_contains "$inc" "config.toml" "must NOT include codex config.toml (use --ignore-user-config)"
    # Whole-dir include leaks history/sqlite/other-agent state. Count entries that are
    # exactly the ~/.codex directory (lines ending in .codex, not .codex/<file>).
    local whole; whole=$(printf '%s\n' "$inc" | grep -cE '\.codex/?$' || true)
    assert_equals "0" "$whole" "must NOT include the whole ~/.codex directory"
    # command must disable user config loading.
    assert_contains "$(yq -r '.agent.command' "$KAPSIS_ROOT/configs/codex.yaml")" "ignore-user-config" \
        "codex command must pass --ignore-user-config"
}

test_agent_codex_allowlists_chatgpt_backend() {
    log_test "Testing codex.yaml filtered allowlist includes the ChatGPT backend"

    # Without this the ChatGPT-subscription auth breaks in the default filtered mode.
    # Assert the effective per-config allowlist, not the reference network-allowlist.yaml.
    local allow
    allow=$(yq -r '(.network.allowlist.ai // [])[]' "$KAPSIS_ROOT/configs/codex.yaml" 2>/dev/null || echo "")
    assert_contains "$allow" "chatgpt.com" "codex filtered mode must allowlist the ChatGPT backend"
}

test_agent_gemini_stages_only_oauth_files() {
    log_test "Testing gemini.yaml injects ONLY the OAuth session files (security regression guard)"

    local inc
    inc=$(yq -r '.filesystem.include[]' "$KAPSIS_ROOT/configs/gemini.yaml" 2>/dev/null || echo "")

    assert_contains "$inc" ".gemini/oauth_creds.json" "must include the OAuth session file"
    # settings.json can carry mcpServers (env secrets) + hook commands — must not be injected.
    assert_not_contains "$inc" "settings.json" "must NOT include gemini settings.json"
    local whole; whole=$(printf '%s\n' "$inc" | grep -cE '\.gemini/?$' || true)
    assert_equals "0" "$whole" "must NOT include the whole ~/.gemini directory"
}

test_agent_gemini_allowlist_is_narrow() {
    log_test "Testing --agent gemini allowlist is narrow (no broad Google API host)"

    local allow
    allow=$(yq -r '(.network.allowlist.ai // [])[], (.network.allowlist.custom // [])[]' "$KAPSIS_ROOT/configs/gemini.yaml" 2>/dev/null || echo "")

    assert_contains "$allow" "cloudcode-pa.googleapis.com" "gemini must allowlist the Code Assist backend"
    assert_contains "$allow" "oauth2.googleapis.com" "gemini must allowlist the OAuth token endpoint"
    # The OAuth token carries broad cloud-platform scope; a generic Google API host
    # would be an exfil channel. Guard against it being re-added.
    assert_not_contains "$allow" "www.googleapis.com" "gemini must NOT allowlist the broad www.googleapis.com host"
}

test_agent_aider() {
    log_test "Testing --agent aider"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent aider --task "test" --dry-run 2>&1) || true

    assert_contains "$output" "AIDER" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/aider.yaml" "Should use aider.yaml config"
}

test_agent_interactive() {
    log_test "Testing --agent interactive"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent interactive --interactive --dry-run 2>&1) || true

    assert_contains "$output" "INTERACTIVE" "Agent name should be displayed in uppercase"
    assert_contains "$output" "configs/interactive.yaml" "Should use interactive.yaml config"
}

test_agent_display_in_banner() {
    log_test "Testing agent name in configuration summary"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent claude --task "test" --dry-run 2>&1) || true

    # In dry-run mode, check config summary shows agent (banner only shows during actual launch)
    assert_contains "$output" "Agent:         CLAUDE" "Config summary should show agent name"
}

test_agent_in_config_summary() {
    log_test "Testing agent in configuration summary"

    local output
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --agent codex --task "test" --dry-run 2>&1) || true

    # Check configuration summary shows agent
    assert_contains "$output" "Agent:" "Configuration should show Agent line"
    assert_contains "$output" "CODEX" "Configuration should show agent name"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Agent Shortcut (--agent flag)"

    # Setup
    setup_test_project

    # Run tests
    run_test test_agent_claude
    run_test test_agent_codex
    run_test test_agent_gemini
    run_test test_agent_codex_binds_codex_image
    run_test test_agent_gemini_binds_gemini_image
    run_test test_agent_codex_stages_only_oauth_file
    run_test test_agent_codex_allowlists_chatgpt_backend
    run_test test_agent_gemini_stages_only_oauth_files
    run_test test_agent_gemini_allowlist_is_narrow
    run_test test_agent_aider
    run_test test_agent_interactive
    run_test test_agent_display_in_banner
    run_test test_agent_in_config_summary

    # Cleanup
    cleanup_test_project

    # Summary
    print_summary
}

main "$@"
