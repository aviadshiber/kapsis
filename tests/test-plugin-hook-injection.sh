#!/usr/bin/env bash
#===============================================================================
# Tests for Plugin Hook Injection (scripts/lib/inject-plugin-hooks.sh)
#
# Verifies that user-installed Claude Code plugin hooks are merged into
# ~/.claude/settings.local.json alongside Kapsis's own status/gist hooks,
# with proper filtering by enabledPlugins and the optional whitelist.
#
# Run: ./tests/test-plugin-hook-injection.sh
#===============================================================================

# Intentional single-quoted ${CLAUDE_PLUGIN_ROOT} placeholders in test
# fixtures — they're JSON-literal strings, NOT shell expansions.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

# Save original values to restore after each test
_ORIG_HOME="$HOME"

setup_test_home() {
    TEST_HOME=$(mktemp -d)
    mkdir -p "$TEST_HOME/.claude/plugins"
}

cleanup_test_home() {
    HOME="$_ORIG_HOME"
    [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
    TEST_HOME=""
    unset KAPSIS_INSTALL_PLUGINS 2>/dev/null || true
    unset KAPSIS_PLUGIN_WHITELIST 2>/dev/null || true
    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
}

# Helpers — build a fully-formed plugin registry / cache fixture.
#   $1: plugin id (e.g. "foo@m")
#   $2: install path (absolute)
#   $3: hooks.json contents (raw JSON)
make_plugin() {
    local plugin_id="$1" install_path="$2" hooks_contents="$3"
    mkdir -p "$install_path/hooks"
    printf '%s' "$hooks_contents" > "$install_path/hooks/hooks.json"
}

# Append a plugin to installed_plugins.json. Idempotent enough for tests.
add_to_registry() {
    local plugin_id="$1" install_path="$2"
    local plugins_file="$TEST_HOME/.claude/plugins/installed_plugins.json"
    if [[ ! -f "$plugins_file" ]]; then
        echo '{"version":2,"plugins":{}}' > "$plugins_file"
    fi
    local tmp
    tmp=$(mktemp)
    jq --arg id "$plugin_id" --arg path "$install_path" \
        '.plugins[$id] = [{"scope":"user","installPath":$path,"version":"1.0.0"}]' \
        "$plugins_file" > "$tmp" && mv "$tmp" "$plugins_file"
}

# Set host enabledPlugins. Pass plugin ids as args.
set_enabled() {
    local settings="$TEST_HOME/.claude/settings.json"
    local map='{}'
    local id
    for id in "$@"; do
        map=$(printf '%s' "$map" | jq --arg id "$id" '. + {($id): true}')
    done
    printf '{"enabledPlugins":%s}\n' "$map" > "$settings"
}

# Pre-seed settings.local.json with the Kapsis status hook (simulates running
# AFTER inject-status-hooks.sh).
seed_kapsis_settings_local() {
    cat > "$TEST_HOME/.claude/settings.local.json" <<'JSON'
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/opt/kapsis/hooks/kapsis-status-hook.sh","timeout":5}]}]}}
JSON
}

# Run the function under test in a subshell. The source guard
# (_KAPSIS_INJECT_PLUGIN_HOOKS_LOADED) is reset in the parent so the module
# is re-evaluated for every test rather than carrying state across runs.
# Captures stderr to $TEST_HOME/inject.stderr so tests can assert log_warn
# messages appeared (run_inject_stderr returns the captured path).
run_inject() {
    unset _KAPSIS_INJECT_PLUGIN_HOOKS_LOADED 2>/dev/null || true
    HOME="$TEST_HOME" \
    KAPSIS_INSTALL_PLUGINS="${KAPSIS_INSTALL_PLUGINS:-true}" \
    KAPSIS_PLUGIN_WHITELIST="${KAPSIS_PLUGIN_WHITELIST:-}" \
    bash -c "
        source '$LIB_DIR/inject-plugin-hooks.sh'
        inject_plugin_hooks
    " 2> "$TEST_HOME/inject.stderr"
}

# Run inject AND return the captured stderr for WARN assertions.
run_inject_stderr() {
    run_inject
    cat "$TEST_HOME/inject.stderr"
}

count_commands() {
    jq '[.hooks // {} | to_entries[] | .value[] | .hooks | length] | add // 0' \
        "$TEST_HOME/.claude/settings.local.json"
}

#===============================================================================
# TEST: Single enabled plugin, no whitelist → merged with concrete path
#===============================================================================

test_single_plugin_no_whitelist() {
    log_test "Single host-enabled plugin, no whitelist, merges with concrete path"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"python3 ${CLAUDE_PLUGIN_ROOT}/hooks/lint.py"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$foo_path/hooks/lint.py" "Concrete path should be substituted into command"
    assert_not_contains "$result" 'CLAUDE_PLUGIN_ROOT' "Placeholder should be fully substituted"
    assert_contains "$result" "kapsis-status-hook.sh" "Kapsis hook should be preserved"

    cleanup_test_home
}

#===============================================================================
# TEST: Plugin disabled in host enabledPlugins → NOT merged
#===============================================================================

test_disabled_plugin_not_merged() {
    log_test "Host-disabled plugin is skipped even if installed"
    setup_test_home

    local bar_path="$TEST_HOME/.claude/plugins/cache/m/bar/1.0.0"
    make_plugin "bar@m" "$bar_path" \
        '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo ${CLAUDE_PLUGIN_ROOT}"}]}]}}'
    add_to_registry "bar@m" "$bar_path"
    # NOT calling set_enabled — host has no enabledPlugins entry for bar@m
    set_enabled  # writes empty enabledPlugins
    seed_kapsis_settings_local

    run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_not_contains "$result" "$bar_path" "Disabled plugin's path should not appear"
    # Kapsis hook still present
    assert_contains "$result" "kapsis-status-hook.sh" "Kapsis hook preserved"

    cleanup_test_home
}

#===============================================================================
# TEST: Whitelist=[a], two enabled plugins → only a merged
#===============================================================================

test_whitelist_filters() {
    log_test "Whitelist limits to listed plugins only"
    setup_test_home

    local a_path="$TEST_HOME/.claude/plugins/cache/m/a/1.0.0"
    local b_path="$TEST_HOME/.claude/plugins/cache/m/b/1.0.0"
    make_plugin "a@m" "$a_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/a.sh"}]}]}}'
    make_plugin "b@m" "$b_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/b.sh"}]}]}}'
    add_to_registry "a@m" "$a_path"
    add_to_registry "b@m" "$b_path"
    set_enabled "a@m" "b@m"
    seed_kapsis_settings_local

    KAPSIS_PLUGIN_WHITELIST='["a@m"]' run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$a_path/a.sh" "Whitelisted plugin a should be merged"
    assert_not_contains "$result" "$b_path/b.sh" "Non-whitelisted plugin b should be skipped"

    cleanup_test_home
}

#===============================================================================
# TEST: Whitelist=[] (empty) → behaves like unset (all host-enabled merged)
#===============================================================================

test_empty_whitelist_allows_all() {
    log_test "Empty whitelist array is treated as 'no filter' (allow all)"
    setup_test_home

    local a_path="$TEST_HOME/.claude/plugins/cache/m/a/1.0.0"
    local b_path="$TEST_HOME/.claude/plugins/cache/m/b/1.0.0"
    make_plugin "a@m" "$a_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/a.sh"}]}]}}'
    make_plugin "b@m" "$b_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/b.sh"}]}]}}'
    add_to_registry "a@m" "$a_path"
    add_to_registry "b@m" "$b_path"
    set_enabled "a@m" "b@m"
    seed_kapsis_settings_local

    KAPSIS_PLUGIN_WHITELIST='[]' run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$a_path/a.sh" "Plugin a should be merged"
    assert_contains "$result" "$b_path/b.sh" "Plugin b should be merged"

    cleanup_test_home
}

#===============================================================================
# TEST: Whitelist references plugin not installed → no error
#===============================================================================

test_whitelist_missing_plugin_no_error() {
    log_test "Whitelist references an uninstalled plugin — handled silently"
    setup_test_home

    local a_path="$TEST_HOME/.claude/plugins/cache/m/a/1.0.0"
    make_plugin "a@m" "$a_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/a.sh"}]}]}}'
    add_to_registry "a@m" "$a_path"
    set_enabled "a@m"
    seed_kapsis_settings_local

    KAPSIS_PLUGIN_WHITELIST='["nonexistent@m","a@m"]' \
        assert_command_succeeds "$(declare -f run_inject); run_inject" \
        "Whitelist with one missing plugin should not error"

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$a_path/a.sh" "Plugin a (in whitelist + installed) should still merge"

    cleanup_test_home
}

#===============================================================================
# TEST: Plugin with malformed hooks.json → warning + others still merged
#===============================================================================

test_malformed_hooks_json() {
    log_test "Malformed plugin hooks.json doesn't break injection of other plugins"
    setup_test_home

    local bad_path="$TEST_HOME/.claude/plugins/cache/m/bad/1.0.0"
    local good_path="$TEST_HOME/.claude/plugins/cache/m/good/1.0.0"
    mkdir -p "$bad_path/hooks"
    echo 'this is not valid JSON {' > "$bad_path/hooks/hooks.json"
    make_plugin "good@m" "$good_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/good.sh"}]}]}}'
    add_to_registry "bad@m" "$bad_path"
    add_to_registry "good@m" "$good_path"
    set_enabled "bad@m" "good@m"
    seed_kapsis_settings_local

    run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$good_path/good.sh" "Good plugin should still merge"
    assert_not_contains "$result" "$bad_path" "Bad plugin should not appear"

    cleanup_test_home
}

#===============================================================================
# TEST: Idempotency — second run produces identical settings.local.json
#===============================================================================

test_idempotency() {
    log_test "Running injection twice produces identical settings.local.json"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/lint.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/start.sh"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    run_inject
    local first_run
    first_run=$(cat "$TEST_HOME/.claude/settings.local.json")
    local count_after_first
    count_after_first=$(count_commands)

    run_inject
    local second_run
    second_run=$(cat "$TEST_HOME/.claude/settings.local.json")
    local count_after_second
    count_after_second=$(count_commands)

    assert_equals "$count_after_first" "$count_after_second" \
        "Command count should be identical after running injection twice"
    assert_equals "$first_run" "$second_run" \
        "settings.local.json byte-identical after re-run"

    cleanup_test_home
}

#===============================================================================
# TEST: KAPSIS_INSTALL_PLUGINS=false → settings.local.json untouched
#===============================================================================

test_gate_off_no_op() {
    log_test "Gate off (KAPSIS_INSTALL_PLUGINS=false): settings.local.json untouched"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/start.sh"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    local before
    before=$(cat "$TEST_HOME/.claude/settings.local.json")

    KAPSIS_INSTALL_PLUGINS=false run_inject

    local after
    after=$(cat "$TEST_HOME/.claude/settings.local.json")

    assert_equals "$before" "$after" "settings.local.json should be byte-identical when gate is off"
    assert_not_contains "$after" "$foo_path" "Plugin should NOT be merged when gate is off"

    cleanup_test_home
}

#===============================================================================
# TEST: Plugin with missing hooks.json → skipped silently
#===============================================================================

test_missing_hooks_json() {
    log_test "Plugin without hooks.json is skipped (no error)"
    setup_test_home

    local nohooks_path="$TEST_HOME/.claude/plugins/cache/m/nohooks/1.0.0"
    mkdir -p "$nohooks_path"
    # No hooks/hooks.json created
    add_to_registry "nohooks@m" "$nohooks_path"
    set_enabled "nohooks@m"
    seed_kapsis_settings_local

    local before
    before=$(cat "$TEST_HOME/.claude/settings.local.json")
    run_inject
    local after
    after=$(cat "$TEST_HOME/.claude/settings.local.json")

    assert_equals "$before" "$after" \
        "Plugin without hooks.json shouldn't change settings.local.json"

    cleanup_test_home
}

#===============================================================================
# TEST: Whitelist must do EXACT match, NOT substring (regression for
# jq inside() bug — see PR #326 review)
#===============================================================================

test_whitelist_exact_match_not_substring() {
    log_test "Whitelist uses exact-match (substring 'a@b' must NOT match ['alpha@beta'])"
    setup_test_home

    local short_path="$TEST_HOME/.claude/plugins/cache/m/a/1.0.0"
    local long_path="$TEST_HOME/.claude/plugins/cache/m/alpha/1.0.0"
    make_plugin "a@b" "$short_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/short.sh"}]}]}}'
    make_plugin "alpha@beta" "$long_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/long.sh"}]}]}}'
    add_to_registry "a@b" "$short_path"
    add_to_registry "alpha@beta" "$long_path"
    set_enabled "a@b" "alpha@beta"
    seed_kapsis_settings_local

    # Whitelist contains ONLY the longer id. The shorter id is a substring,
    # so a `jq inside()` based check would erroneously let it through.
    KAPSIS_PLUGIN_WHITELIST='["alpha@beta"]' run_inject

    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$long_path/long.sh" "Whitelisted plugin must merge"
    assert_not_contains "$result" "$short_path/short.sh" \
        "Substring-only plugin id must NOT merge (regression for substring bypass)"

    cleanup_test_home
}

#===============================================================================
# TEST: installPath outside ~/.claude/plugins/ is rejected
#===============================================================================

test_installpath_containment() {
    log_test "Plugin with installPath outside ~/.claude/plugins/ is refused"
    setup_test_home

    # Plugin "lives" outside the trusted cache prefix
    local evil_path="$TEST_HOME/elsewhere/plugins/evil/1.0.0"
    make_plugin "evil@m" "$evil_path" \
        '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/evil.sh"}]}]}}'
    add_to_registry "evil@m" "$evil_path"
    set_enabled "evil@m"
    seed_kapsis_settings_local

    local stderr
    stderr=$(run_inject_stderr)
    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")

    assert_not_contains "$result" "$evil_path" \
        "Plugin outside trusted cache prefix must NOT be merged"
    assert_contains "$stderr" "outside" \
        "Must log a warning when refusing an installPath outside the cache prefix"

    cleanup_test_home
}

#===============================================================================
# TEST: installPath traversal (../) is rejected (realpath normalization)
#===============================================================================

test_installpath_traversal_blocked() {
    log_test "installPath with ../ that escapes the cache prefix is refused"
    setup_test_home

    # Build a real plugin OUTSIDE the cache, then reference it via a path
    # that LOOKS rooted at .claude/plugins/cache/ but escapes via .. components.
    local real_path="$TEST_HOME/escaped/plugin/1.0.0"
    make_plugin "trav@m" "$real_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/x.sh"}]}]}}'

    # Reference path with .. that escapes the trusted prefix
    local traversed="$TEST_HOME/.claude/plugins/cache/../../../escaped/plugin/1.0.0"
    add_to_registry "trav@m" "$traversed"
    set_enabled "trav@m"
    seed_kapsis_settings_local

    run_inject
    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_not_contains "$result" "/escaped/plugin" \
        "Traversed installPath must NOT bypass the trusted prefix check"

    cleanup_test_home
}

#===============================================================================
# TEST: Corrupted KAPSIS_PLUGIN_WHITELIST fails CLOSED (no plugins injected)
#===============================================================================

test_whitelist_corruption_fails_closed() {
    log_test "Corrupted KAPSIS_PLUGIN_WHITELIST fails closed (refuses all plugins)"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/x.sh"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    local before
    before=$(cat "$TEST_HOME/.claude/settings.local.json")

    # Not a JSON array — should be treated as a hard error, not "allow all".
    KAPSIS_PLUGIN_WHITELIST='"not-an-array"' run_inject || true

    local after
    after=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_equals "$before" "$after" \
        "Corrupted whitelist must NOT cause plugin hooks to be injected (fail closed)"

    cleanup_test_home
}

#===============================================================================
# TEST: Whitelist with non-string entries also fails closed
#===============================================================================

test_whitelist_non_string_entries_fail_closed() {
    log_test "Whitelist with non-string entries (e.g. numbers) fails closed"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/x.sh"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    local before
    before=$(cat "$TEST_HOME/.claude/settings.local.json")

    KAPSIS_PLUGIN_WHITELIST='[42,"foo@m"]' run_inject || true

    local after
    after=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_equals "$before" "$after" \
        "Whitelist with non-string entry must NOT inject any plugin (fail closed)"

    cleanup_test_home
}

#===============================================================================
# TEST: ${CLAUDE_PLUGIN_ROOT} appearing TWICE in one command is substituted both times
#===============================================================================

test_multiple_plugin_root_occurrences() {
    log_test "Multiple \${CLAUDE_PLUGIN_ROOT} occurrences in one command are all substituted"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/run.sh --lib ${CLAUDE_PLUGIN_ROOT}/lib/x.so"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    run_inject
    local merged_cmd
    merged_cmd=$(jq -r '.hooks.PostToolUse[] | .hooks[]? | .command | select(contains("run.sh"))' \
                 "$TEST_HOME/.claude/settings.local.json")

    assert_contains "$merged_cmd" "$foo_path/run.sh" "First \${CLAUDE_PLUGIN_ROOT} substituted"
    assert_contains "$merged_cmd" "$foo_path/lib/x.so" "Second \${CLAUDE_PLUGIN_ROOT} also substituted"
    assert_not_contains "$merged_cmd" 'CLAUDE_PLUGIN_ROOT' \
        "No \${CLAUDE_PLUGIN_ROOT} placeholder should remain"

    cleanup_test_home
}

#===============================================================================
# TEST: settings.local.json absent at start — created by injection
#===============================================================================

test_settings_local_absent_at_start() {
    log_test "settings.local.json absent at start is created during injection"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/x.sh"}]}]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    # NOTE: deliberately NOT calling seed_kapsis_settings_local — file absent
    assert_file_not_exists "$TEST_HOME/.claude/settings.local.json" "Precondition: settings.local.json absent"

    run_inject

    assert_file_exists "$TEST_HOME/.claude/settings.local.json" "settings.local.json created"
    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$result" "$foo_path/x.sh" "Plugin hook merged into new settings.local.json"

    cleanup_test_home
}

#===============================================================================
# TEST: Multi-plugin (5 plugins) — order preserved + all merged
#===============================================================================

test_multi_plugin_merge() {
    log_test "Five plugins merged in one run — all present, kapsis hook first"
    setup_test_home

    local p
    for p in p1 p2 p3 p4 p5; do
        local pp="$TEST_HOME/.claude/plugins/cache/m/$p/1.0.0"
        make_plugin "$p@m" "$pp" \
            "$(printf '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"%s"}]}]}}' \
                '${CLAUDE_PLUGIN_ROOT}/'"$p"'.sh')"
        add_to_registry "$p@m" "$pp"
    done
    set_enabled "p1@m" "p2@m" "p3@m" "p4@m" "p5@m"
    seed_kapsis_settings_local

    run_inject

    # kapsis-status-hook must be FIRST in PostToolUse (ordering invariant)
    local first_cmd
    first_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$TEST_HOME/.claude/settings.local.json")
    assert_contains "$first_cmd" "kapsis-status-hook.sh" "kapsis-status-hook must remain at index 0 in PostToolUse"

    # All 5 plugin commands present
    local result
    result=$(cat "$TEST_HOME/.claude/settings.local.json")
    for p in p1 p2 p3 p4 p5; do
        assert_contains "$result" "/$p.sh" "Plugin $p@m's command present"
    done

    cleanup_test_home
}

#===============================================================================
# TEST: Malformed hooks.json triggers WARN message (not just silent skip)
#===============================================================================

test_malformed_hooks_logs_warn() {
    log_test "Malformed hooks.json logs a WARN message (audit signal)"
    setup_test_home

    local bad_path="$TEST_HOME/.claude/plugins/cache/m/bad/1.0.0"
    mkdir -p "$bad_path/hooks"
    echo 'this is not valid JSON {' > "$bad_path/hooks/hooks.json"
    add_to_registry "bad@m" "$bad_path"
    set_enabled "bad@m"
    seed_kapsis_settings_local

    local stderr
    stderr=$(run_inject_stderr)

    assert_contains "$stderr" "bad@m" \
        "WARN must name the offending plugin id"
    assert_contains "$stderr" "WARN" \
        "Must log at WARN level (not silently skipped)"

    cleanup_test_home
}

#===============================================================================
# TEST: Intra-plugin duplicate commands are deduped in a single run
#===============================================================================

test_intra_plugin_dedup() {
    log_test "Plugin with two groups referencing the same command — dedupes in a single run"
    setup_test_home

    local foo_path="$TEST_HOME/.claude/plugins/cache/m/foo/1.0.0"
    # Two PostToolUse groups, different matchers, SAME command. After
    # substitution both reference the same concrete path; the merger should
    # dedupe within this single run, not just on a second pass.
    make_plugin "foo@m" "$foo_path" \
        '{"hooks":{"PostToolUse":[
          {"matcher":"Edit","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/lint.sh"}]},
          {"matcher":"Write","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/lint.sh"}]}
        ]}}'
    add_to_registry "foo@m" "$foo_path"
    set_enabled "foo@m"
    seed_kapsis_settings_local

    run_inject
    local occurrences
    occurrences=$(jq '[.hooks.PostToolUse[] | .hooks[]? | .command | select(contains("lint.sh"))] | length' \
                  "$TEST_HOME/.claude/settings.local.json")
    assert_equals "1" "$occurrences" \
        "lint.sh command must appear exactly once even though plugin lists it in two groups"

    cleanup_test_home
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Plugin Hook Injection (inject-plugin-hooks.sh)"

    log_info "=== Basic injection ==="
    run_test test_single_plugin_no_whitelist
    run_test test_disabled_plugin_not_merged
    run_test test_settings_local_absent_at_start

    log_info "=== Whitelist filtering ==="
    run_test test_whitelist_filters
    run_test test_empty_whitelist_allows_all
    run_test test_whitelist_missing_plugin_no_error
    run_test test_whitelist_exact_match_not_substring
    run_test test_whitelist_corruption_fails_closed
    run_test test_whitelist_non_string_entries_fail_closed

    log_info "=== installPath containment (security) ==="
    run_test test_installpath_containment
    run_test test_installpath_traversal_blocked

    log_info "=== Substitution + merge correctness ==="
    run_test test_multiple_plugin_root_occurrences
    run_test test_intra_plugin_dedup
    run_test test_multi_plugin_merge

    log_info "=== Robustness ==="
    run_test test_malformed_hooks_json
    run_test test_malformed_hooks_logs_warn
    run_test test_missing_hooks_json
    run_test test_idempotency
    run_test test_gate_off_no_op

    print_summary
}

main "$@"
