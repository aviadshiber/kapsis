#!/usr/bin/env bash
#===============================================================================
# Integration tests: all injectable hooks fire correctly via settings.json
#
# Covers every hook and settings injection path that Kapsis writes into
# ~/.claude/settings.json inside a container:
#
#   • Status hooks  (inject-status-hooks.sh)
#       - PostToolUse: kapsis-gist-hook.sh, kapsis-status-hook.sh
#       - Stop:        kapsis-stop-hook.sh
#   • LSP servers   (inject-lsp-config.sh)
#       - settings.json → lspServers (Claude Code reads on startup)
#   • Plugin hooks  (inject-plugin-hooks.sh)
#       - PostToolUse: user-installed plugin commands
#
# Each test:
#   1. Runs the real injection script(s)
#   2. Reads the resulting command / config from settings.json (as Claude Code
#      does when loading its settings file)
#   3. Executes or inspects it to verify end-to-end correctness
#
# Note: hooks are invoked directly (not via Claude Code). For tests that run
# a real Claude Code process see test-e2e-claude-hooks.sh.
#
# All tests are quick / no-container — suitable for QUICK_TESTS and CI.
#
# Run: ./tests/test-integration-all-hooks.sh
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
_E2E_ALL_ORIG_HOME="$HOME"
TEST_HOME=""

setup_e2e_env() {
    # Reset any state left by a prior failed test (HOME, dirs, env vars, guards).
    # Safe to call before first test because _E2E_ALL_ORIG_HOME and TEST_HOME are
    # initialised at script level above.
    cleanup_e2e_env 2>/dev/null || true
    TEST_HOME=$(mktemp -d)
    export HOME="$TEST_HOME"
    export KAPSIS_HOME="$KAPSIS_ROOT"
    export KAPSIS_LIB="$KAPSIS_ROOT/scripts/lib"

    mkdir -p "$TEST_HOME/.kapsis/logs" "$TEST_HOME/.claude/plugins"

    # Populate $KAPSIS_ROOT/hooks/ with the real hook scripts so injected
    # command paths point to working binaries.
    mkdir -p "$KAPSIS_ROOT/hooks"
    cp "$HOOKS_SRC/kapsis-gist-hook.sh"   "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-status-hook.sh" "$KAPSIS_ROOT/hooks/"
    cp "$HOOKS_SRC/kapsis-stop-hook.sh"   "$KAPSIS_ROOT/hooks/"
    chmod +x "$KAPSIS_ROOT/hooks/"*.sh
}

cleanup_e2e_env() {
    export HOME="$_E2E_ALL_ORIG_HOME"
    rm -rf "${TEST_HOME:-}" "$KAPSIS_ROOT/hooks"
    unset TEST_HOME KAPSIS_HOME KAPSIS_LIB
    _KAPSIS_LOG_FILE_PATH=""
    # shellcheck disable=SC2034
    export KAPSIS_LOG_TO_FILE="false"
    unset KAPSIS_INJECT_GIST KAPSIS_STATUS_AGENT_ID KAPSIS_AGENT_TYPE \
          KAPSIS_INSTALL_PLUGINS KAPSIS_PLUGIN_WHITELIST \
          KAPSIS_LSP_SERVERS_JSON 2>/dev/null || true
    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
    unset _KAPSIS_INJECT_STATUS_HOOKS_LOADED 2>/dev/null || true
    unset _KAPSIS_INJECT_LSP_CONFIG_LOADED 2>/dev/null || true
}

# Add enabledPlugins for a plugin ID to the existing settings.json without
# destroying other keys (hooks, lspServers, etc. must be preserved).
_enable_plugin() {
    local plugin_id="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg id "$plugin_id" '.enabledPlugins[$id] = true' \
        "$TEST_HOME/.claude/settings.json" > "$tmp" && mv "$tmp" "$TEST_HOME/.claude/settings.json"
}

# Register a plugin in installed_plugins.json.
_register_plugin() {
    local plugin_id="$1" install_path="$2"
    local plugins_file="$TEST_HOME/.claude/plugins/installed_plugins.json"
    if [[ ! -f "$plugins_file" ]]; then
        printf '{"version":2,"plugins":{}}\n' > "$plugins_file"
    fi
    local tmp
    tmp=$(mktemp)
    jq --arg id "$plugin_id" --arg path "$install_path" \
        '.plugins[$id] = [{"scope":"user","installPath":$path,"version":"0.1.0"}]' \
        "$plugins_file" > "$tmp" && mv "$tmp" "$plugins_file"
}

#===============================================================================
# SECTION: Stop hook
#===============================================================================

# TEST: Stop hook command read from settings.json is invocable and exits 0.
test_e2e_stop_hook_dispatch_exits_zero() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-stop-$$"

    # Inject hooks — writes settings.json with Stop hook entry
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Read the stop hook command exactly as Claude Code would
    local stop_cmd
    stop_cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
    assert_contains "$stop_cmd" "kapsis-stop-hook.sh" \
        "Stop[0] command must point to kapsis-stop-hook.sh"
    assert_true "[[ -x '$stop_cmd' ]]" \
        "Stop hook command must be executable"

    # Dispatch the stop hook with an empty agent ID (safe: early-exits 0)
    local exit_code=0
    printf '{}' | KAPSIS_STATUS_AGENT_ID="" bash "$stop_cmd" >/dev/null 2>&1 \
        || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Stop hook dispatched via command from settings.json must exit 0"

    cleanup_e2e_env
}

# TEST: Stop hook is the sole entry in the Stop array (no duplicates).
test_e2e_stop_hook_single_entry() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-stop2-$$"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1
    inject_claude_hooks >/dev/null 2>&1   # second call — must not duplicate

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$TEST_HOME/.claude/settings.json")
    assert_equals "1" "$stop_count" \
        "Exactly one Stop entry must exist even after double injection"

    cleanup_e2e_env
}

#===============================================================================
# SECTION: LSP server injection
#===============================================================================

# TEST: LSP servers are written to settings.json and have the correct Claude
#       Code structure (extensionToLanguage, not raw languages map).
test_e2e_lsp_servers_injected_with_correct_structure() {
    setup_e2e_env
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"jdtls","args":["--stdio"],"languages":{"java":[".java",".class"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config >/dev/null 2>&1

    local settings="$TEST_HOME/.claude/settings.json"

    # lspServers key must be present
    assert_true "jq -e '.lspServers' '$settings' >/dev/null 2>&1" \
        "settings.json must contain lspServers key after LSP injection"

    # Server command must be preserved
    local cmd
    cmd=$(jq -r '.lspServers["java-lsp"].command' "$settings")
    assert_equals "jdtls" "$cmd" \
        "LSP server command must be preserved in settings.json"

    # args must be preserved
    local args
    args=$(jq -r '.lspServers["java-lsp"].args[0]' "$settings")
    assert_equals "--stdio" "$args" \
        "LSP server args must be preserved in settings.json"

    # extensionToLanguage must be the inverted mapping (Claude Code's format)
    local ext_java
    ext_java=$(jq -r '.lspServers["java-lsp"].extensionToLanguage[".java"]' "$settings")
    assert_equals "java" "$ext_java" \
        ".java extension must map to 'java' language in extensionToLanguage"

    local ext_class
    ext_class=$(jq -r '.lspServers["java-lsp"].extensionToLanguage[".class"]' "$settings")
    assert_equals "java" "$ext_class" \
        ".class extension must also map to 'java' language in extensionToLanguage"

    # Raw 'languages' key must NOT appear (it's an input-only field)
    local has_languages
    has_languages=$(jq '.lspServers["java-lsp"] | has("languages")' "$settings")
    assert_equals "false" "$has_languages" \
        "Raw 'languages' key must not leak into the Claude Code lspServers entry"

    cleanup_e2e_env
}

# TEST: LSP injection and hook injection coexist in settings.json without
#       either overwriting the other.
test_e2e_lsp_and_hooks_coexist_in_settings_json() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-lsp-coexist-$$"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"ts-lsp":{"command":"typescript-language-server","args":["--stdio"],"languages":{"typescript":[".ts",".tsx"]}}}'

    # Inject status hooks first
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Inject LSP servers second — must merge, not replace
    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config >/dev/null 2>&1

    local settings="$TEST_HOME/.claude/settings.json"

    # Both keys must coexist
    assert_true "jq -e '.hooks' '$settings' >/dev/null 2>&1" \
        "hooks key must survive LSP injection"
    assert_true "jq -e '.lspServers' '$settings' >/dev/null 2>&1" \
        "lspServers key must be added by LSP injection"

    # Kapsis hooks must still be present
    local hook_count
    hook_count=$(jq '[.hooks.PostToolUse[] | .hooks[].command] | length' "$settings")
    assert_true "[[ $hook_count -ge 2 ]]" \
        "PostToolUse hooks (gist + status) must still be present after LSP injection"

    # File must still be valid JSON
    assert_true "jq empty '$settings' >/dev/null 2>&1" \
        "settings.json must remain valid JSON after both injections"

    cleanup_e2e_env
}

# TEST: LSP injection into non-Claude agents is a no-op (agent type guard).
test_e2e_lsp_skipped_for_non_claude_agent() {
    setup_e2e_env
    export KAPSIS_AGENT_TYPE="codex-cli"
    export KAPSIS_LSP_SERVERS_JSON='{"java-lsp":{"command":"jdtls","args":["--stdio"],"languages":{"java":[".java"]}}}'

    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config >/dev/null 2>&1

    # settings.json must not have been created (codex-cli agent type → skip)
    assert_false "[[ -f '$TEST_HOME/.claude/settings.json' ]]" \
        "settings.json must not be created for non-Claude agents"

    cleanup_e2e_env
}

#===============================================================================
# SECTION: Plugin hook dispatch
#===============================================================================

# TEST: A plugin hook injected into settings.json can be dispatched and
#       produces its expected side effect (writing a marker file).
test_e2e_plugin_hook_dispatch_writes_marker() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-plugin-$$"
    export KAPSIS_INSTALL_PLUGINS="true"

    local marker_file="$TEST_HOME/.kapsis/plugin-fired.txt"
    local plugin_id="marker@m"
    local plugin_root="$TEST_HOME/.claude/plugins/cache/m/marker/0.1.0"

    # Inject Kapsis status hooks first (creates settings.json with hooks)
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # Build plugin fixture:
    #   hooks/run.sh     — the hook command (touches marker file)
    #   hooks/hooks.json — hook definition referencing ${CLAUDE_PLUGIN_ROOT}
    mkdir -p "$plugin_root/hooks"
    cat > "$plugin_root/hooks/run.sh" << HOOKEOF
#!/usr/bin/env bash
touch "$marker_file"
HOOKEOF
    chmod +x "$plugin_root/hooks/run.sh"

    # Use single-quoted heredoc so ${CLAUDE_PLUGIN_ROOT} is written literally
    # (inject-plugin-hooks.sh substitutes it at merge time via jq)
    cat > "$plugin_root/hooks/hooks.json" << 'JSONEOF'
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh"}]}]}}
JSONEOF

    # Register in installed_plugins.json and enable in settings.json
    _register_plugin "$plugin_id" "$plugin_root"
    _enable_plugin   "$plugin_id"

    # Inject plugin hooks — appends to settings.json alongside Kapsis hooks
    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
    source "$LIB_DIR/inject-plugin-hooks.sh"
    inject_plugin_hooks >/dev/null 2>&1

    # Read plugin hook command from settings.json (substituted path)
    local plugin_cmd
    plugin_cmd=$(jq -r '[.hooks.PostToolUse[] | .hooks[].command] | map(select(contains("run.sh"))) | first' \
                     "$TEST_HOME/.claude/settings.json")

    assert_contains "$plugin_cmd" "hooks/run.sh" \
        "Plugin hook command with substituted path must be in settings.json"
    assert_not_contains "$plugin_cmd" 'CLAUDE_PLUGIN_ROOT' \
        "CLAUDE_PLUGIN_ROOT placeholder must be fully substituted"

    # Dispatch: simulate Claude Code's PostToolUse trigger
    printf '{"tool_name":"Read","tool_input":{}}' | bash "$plugin_cmd" >/dev/null 2>&1 || true

    assert_file_exists "$marker_file" \
        "Plugin hook dispatched via command from settings.json must create marker file"

    # Kapsis own hooks must still be present alongside the plugin hook
    local kapsis_present
    kapsis_present=$(jq '[.hooks.PostToolUse[] | .hooks[].command] | map(select(contains("kapsis-status-hook"))) | length' \
                        "$TEST_HOME/.claude/settings.json")
    assert_equals "1" "$kapsis_present" \
        "Kapsis status hook must coexist with plugin hook in PostToolUse"

    cleanup_e2e_env
}

# TEST: Plugin hook and Kapsis hooks appear in PostToolUse in the right order
#       (Kapsis hooks first — gist must fire before status; then plugin hooks).
test_e2e_plugin_hook_ordering() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-order-$$"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_INSTALL_PLUGINS="true"

    local plugin_id="ordering@m"
    local plugin_root="$TEST_HOME/.claude/plugins/cache/m/ordering/0.1.0"

    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    mkdir -p "$plugin_root/hooks"
    printf '#!/usr/bin/env bash\n: # no-op hook\n' > "$plugin_root/hooks/noop.sh"
    chmod +x "$plugin_root/hooks/noop.sh"
    cat > "$plugin_root/hooks/hooks.json" << 'JSONEOF'
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/noop.sh"}]}]}}
JSONEOF

    _register_plugin "$plugin_id" "$plugin_root"
    _enable_plugin   "$plugin_id"

    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
    source "$LIB_DIR/inject-plugin-hooks.sh"
    inject_plugin_hooks >/dev/null 2>&1

    # Extract ordered command list from PostToolUse
    local commands
    commands=$(jq -r '[.hooks.PostToolUse[] | .hooks[].command] | join(",")' \
                   "$TEST_HOME/.claude/settings.json")

    # Gist hook must appear before status hook
    local gist_pos status_pos plugin_pos
    gist_pos=$(printf '%s' "$commands" | tr ',' '\n' | grep -n "gist-hook"   | cut -d: -f1 | head -1)
    status_pos=$(printf '%s' "$commands" | tr ',' '\n' | grep -n "status-hook" | cut -d: -f1 | head -1)
    plugin_pos=$(printf '%s' "$commands" | tr ',' '\n' | grep -n "noop.sh"     | cut -d: -f1 | head -1)

    assert_true "[[ ${gist_pos:-99} -lt ${status_pos:-100} ]]" \
        "Gist hook must appear before status hook in PostToolUse order"
    assert_true "[[ ${status_pos:-99} -lt ${plugin_pos:-100} ]]" \
        "Kapsis hooks must appear before plugin hooks in PostToolUse order"

    cleanup_e2e_env
}

#===============================================================================
# SECTION: All injections combined
#===============================================================================

# TEST: Status hooks + LSP servers + plugin hooks all coexist in one
#       settings.json — three top-level keys, valid JSON throughout.
test_e2e_all_hooks_combined_single_settings_json() {
    setup_e2e_env
    export KAPSIS_STATUS_AGENT_ID="e2e-all-$$"
    export KAPSIS_INJECT_GIST="true"
    export KAPSIS_AGENT_TYPE="claude-cli"
    export KAPSIS_INSTALL_PLUGINS="true"
    export KAPSIS_LSP_SERVERS_JSON='{"rust-analyzer":{"command":"rust-analyzer","args":["--stdio"],"languages":{"rust":[".rs"]}}}'

    local plugin_id="combined@m"
    local plugin_root="$TEST_HOME/.claude/plugins/cache/m/combined/0.1.0"

    # 1. Status hooks
    source "$LIB_DIR/inject-status-hooks.sh"
    inject_claude_hooks >/dev/null 2>&1

    # 2. LSP servers
    source "$LIB_DIR/inject-lsp-config.sh"
    inject_lsp_config >/dev/null 2>&1

    # 3. Plugin hook
    mkdir -p "$plugin_root/hooks"
    printf '#!/usr/bin/env bash\n: # combined test no-op\n' > "$plugin_root/hooks/noop.sh"
    chmod +x "$plugin_root/hooks/noop.sh"
    cat > "$plugin_root/hooks/hooks.json" << 'JSONEOF'
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/noop.sh"}]}]}}
JSONEOF

    _register_plugin "$plugin_id" "$plugin_root"
    _enable_plugin   "$plugin_id"

    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
    source "$LIB_DIR/inject-plugin-hooks.sh"
    inject_plugin_hooks >/dev/null 2>&1

    local settings="$TEST_HOME/.claude/settings.json"

    # All three top-level keys present
    assert_true "jq -e '.hooks' '$settings' >/dev/null 2>&1" \
        "hooks key must be present after combined injection"
    assert_true "jq -e '.lspServers' '$settings' >/dev/null 2>&1" \
        "lspServers key must be present after combined injection"
    assert_true "jq -e '.enabledPlugins' '$settings' >/dev/null 2>&1" \
        "enabledPlugins key must be present after combined injection"

    # At least 3 PostToolUse commands: gist + status + plugin
    local cmd_count
    cmd_count=$(jq '[.hooks.PostToolUse[] | .hooks[].command] | length' "$settings")
    assert_true "[[ $cmd_count -ge 3 ]]" \
        "PostToolUse must have at least 3 commands (gist + status + plugin hook)"

    # LSP entry correct
    local rs_lang
    rs_lang=$(jq -r '.lspServers["rust-analyzer"].extensionToLanguage[".rs"]' "$settings")
    assert_equals "rust" "$rs_lang" \
        ".rs extension must map to 'rust' in combined settings.json"

    # Exactly one Stop entry
    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$settings")
    assert_equals "1" "$stop_count" \
        "Exactly one Stop entry must be present in combined settings.json"

    # File must be valid JSON throughout
    assert_true "jq empty '$settings' >/dev/null 2>&1" \
        "settings.json must be valid JSON after all three injections"

    # settings.local.json must never have been created
    assert_false "[[ -f '$TEST_HOME/.claude/settings.local.json' ]]" \
        "settings.local.json must not exist — regression guard for #351"

    cleanup_e2e_env
}

#===============================================================================
# Run
#===============================================================================

run_tests() {
    print_test_header "Integration: All hooks fire correctly via settings.json"

    log_info "=== Stop hook ==="
    run_test test_e2e_stop_hook_dispatch_exits_zero
    run_test test_e2e_stop_hook_single_entry

    log_info "=== LSP server injection ==="
    run_test test_e2e_lsp_servers_injected_with_correct_structure
    run_test test_e2e_lsp_and_hooks_coexist_in_settings_json
    run_test test_e2e_lsp_skipped_for_non_claude_agent

    log_info "=== Plugin hook dispatch ==="
    run_test test_e2e_plugin_hook_dispatch_writes_marker
    run_test test_e2e_plugin_hook_ordering

    log_info "=== All injections combined ==="
    run_test test_e2e_all_hooks_combined_single_settings_json

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
