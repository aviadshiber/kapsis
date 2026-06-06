#!/usr/bin/env bash
#===============================================================================
# Test: Container All Hooks — combined injection inside real image
#
# Verifies that all three Kapsis injection libs (inject-status-hooks.sh,
# inject-lsp-config.sh, inject-plugin-hooks.sh) are shipped in the container
# image and produce the correct combined settings.json when run IN ORDER inside
# the built kapsis-sandbox image.
#
# Catches the class of bug where:
#   - One or more inject-*.sh files are present on the host source tree
#   - The matching COPY line in Containerfile is forgotten for one of them
#   - The missing injector silently no-ops at runtime
#   - The combined settings.json is missing one of its expected top-level keys
#
# Counterpart to test-host-inject-all-hooks.sh, which exercises the same logic
# sourced directly from the host source tree. This test exercises the packaged
# image and catches any COPY/chmod regression the host-sourced test cannot detect.
#
# REQUIRES: Container environment (Podman) — auto-skipped via skip_if_no_overlay_rw.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES: All three inject libs present in the image
#===============================================================================

test_all_inject_libs_exist_in_container() {
    log_test "Testing all three inject-*.sh libs exist in container image"

    setup_container_test "all-hooks-libs"

    local output
    output=$(run_in_container "
        ok=true
        for lib in inject-status-hooks.sh inject-lsp-config.sh inject-plugin-hooks.sh; do
            if [[ ! -f /opt/kapsis/lib/\$lib ]]; then
                echo \"MISSING: \$lib\"
                ok=false
            fi
        done
        \$ok && echo ALL_PRESENT
    ")

    cleanup_container_test

    assert_contains "$output" "ALL_PRESENT" \
        "All three inject libs must exist at /opt/kapsis/lib/ — each needs its own COPY line in Containerfile (container output: $output)"
    assert_not_contains "$output" "MISSING:" \
        "No inject lib should be missing from the container image"
}

test_all_inject_libs_executable_in_container() {
    log_test "Testing all three inject-*.sh libs are executable in container"

    setup_container_test "all-hooks-exec"

    local output
    output=$(run_in_container "
        ok=true
        for lib in inject-status-hooks.sh inject-lsp-config.sh inject-plugin-hooks.sh; do
            if [[ ! -x /opt/kapsis/lib/\$lib ]]; then
                echo \"NOT_EXECUTABLE: \$lib\"
                ok=false
            fi
        done
        \$ok && echo ALL_EXECUTABLE
    ")

    cleanup_container_test

    assert_contains "$output" "ALL_EXECUTABLE" \
        "All three inject libs must be chmod 755 in the container (container output: $output)"
}

#===============================================================================
# TEST CASES: Combined injection produces correct settings.json
#===============================================================================

# Run all three injectors in sequence in one container invocation. Assert that
# the resulting settings.json has all three expected top-level keys coexisting.
# This is the combined-scenario counterpart to test_e2e_all_hooks_combined_single_settings_json
# in test-host-inject-all-hooks.sh — but running entirely inside the image.
test_combined_injection_all_keys_coexist() {
    log_test "Testing status + LSP + plugin injection all coexist in settings.json (in-container)"

    setup_container_test "all-hooks-combined"

    local fixture_root marker_cmd plugin_id plugin_install_path
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-all-hooks-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    marker_cmd="MARKER_ALL_HOOKS_$$"
    plugin_id="test-combined@marketplace"
    plugin_install_path="/home/developer/.claude/plugins/cache/marketplace/test-combined/1.0.0"

    mkdir -p "$fixture_root/.claude/plugins/cache/marketplace/test-combined/1.0.0/hooks"

    # installed_plugins.json — v2 shape (array of version entries)
    cat > "$fixture_root/.claude/plugins/installed_plugins.json" <<EOF
{
  "plugins": {
    "$plugin_id": [
      {
        "installPath": "$plugin_install_path",
        "version": "1.0.0",
        "scope": "user"
      }
    ]
  }
}
EOF

    # Plugin hooks.json — marker command so we can detect it in the output
    cat > "$fixture_root/.claude/plugins/cache/marketplace/test-combined/1.0.0/hooks/hooks.json" <<EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "echo $marker_cmd"
          }
        ]
      }
    ]
  }
}
EOF

    # settings.json — must pre-exist with enabledPlugins so the injector picks it up
    cat > "$fixture_root/.claude/settings.json" <<EOF
{
  "enabledPlugins": {
    "$plugin_id": true
  }
}
EOF

    chmod -R a+rwX "$fixture_root"

    local container_output exit_code=0
    container_output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$fixture_root/.claude:/home/developer/.claude:rw" \
        -e CI="${CI:-true}" \
        -e KAPSIS_NETWORK_MODE="${KAPSIS_NETWORK_MODE:-open}" \
        -e KAPSIS_AGENT_TYPE=claude-cli \
        -e KAPSIS_STATUS_AGENT_ID="all-hooks-$$" \
        -e KAPSIS_INJECT_GIST=true \
        -e KAPSIS_INSTALL_PLUGINS=true \
        -e KAPSIS_PLUGIN_WHITELIST='[]' \
        -e 'KAPSIS_LSP_SERVERS_JSON={"rust-analyzer":{"command":"rust-analyzer","args":["--stdio"],"languages":{"rust":[".rs"]}}}' \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh

            # 1. Status hooks (creates settings.json with .hooks)
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks

            # 2. LSP servers (merges .lspServers into existing settings.json)
            source /opt/kapsis/lib/inject-lsp-config.sh
            inject_lsp_config

            # 3. Plugin hooks (appends to .hooks.PostToolUse in settings.json)
            source /opt/kapsis/lib/inject-plugin-hooks.sh
            inject_plugin_hooks

            echo "----SETTINGS_CONTENT_START----"
            cat /home/developer/.claude/settings.json
            echo "----SETTINGS_CONTENT_END----"

            # Structural checks emitted as markers (one line per check)
            jq -e ".hooks" /home/developer/.claude/settings.json >/dev/null && echo "HAS_HOOKS"
            jq -e ".lspServers" /home/developer/.claude/settings.json >/dev/null && echo "HAS_LSP"
            jq -e ".enabledPlugins" /home/developer/.claude/settings.json >/dev/null && echo "HAS_PLUGINS"
            jq empty /home/developer/.claude/settings.json >/dev/null && echo "VALID_JSON"
            [[ ! -f /home/developer/.claude/settings.local.json ]] && echo "NO_LOCAL_JSON"
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "Combined injection should complete without error (output: $container_output)"
    assert_contains "$container_output" "HAS_HOOKS" \
        ".hooks key must be present after status hook injection"
    assert_contains "$container_output" "HAS_LSP" \
        ".lspServers key must be present after LSP injection"
    assert_contains "$container_output" "HAS_PLUGINS" \
        ".enabledPlugins key must survive all three injections"
    assert_contains "$container_output" "VALID_JSON" \
        "settings.json must remain valid JSON after all three injections"
    assert_contains "$container_output" "NO_LOCAL_JSON" \
        "settings.local.json must never be created — regression guard for #351"
    assert_contains "$container_output" "$marker_cmd" \
        "Plugin hook command (marker) must appear in the combined settings.json"
}

# Regression guard: the Stop hook must appear exactly once even when all three
# injectors run. (Status hooks write Stop[0]; no other injector should add more.)
test_combined_injection_exactly_one_stop_hook() {
    log_test "Testing exactly one Stop hook entry after combined injection"

    setup_container_test "all-hooks-stop"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-all-hooks-stop-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    mkdir -p "$fixture_root/.claude"
    # Minimal settings.json so injectors can read/write it
    printf '{"enabledPlugins":{}}\n' > "$fixture_root/.claude/settings.json"
    chmod -R a+rwX "$fixture_root"

    local container_output exit_code=0
    container_output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$fixture_root/.claude:/home/developer/.claude:rw" \
        -e CI="${CI:-true}" \
        -e KAPSIS_NETWORK_MODE="${KAPSIS_NETWORK_MODE:-open}" \
        -e KAPSIS_AGENT_TYPE=claude-cli \
        -e KAPSIS_STATUS_AGENT_ID="stop-count-$$" \
        -e KAPSIS_INSTALL_PLUGINS=false \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            # Second call must be idempotent — no duplicate Stop entries
            inject_claude_hooks
            stop_count=$(jq ".hooks.Stop | length" /home/developer/.claude/settings.json)
            echo "STOP_COUNT:$stop_count"
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "Container script should complete without error"
    assert_contains "$container_output" "STOP_COUNT:1" \
        "Exactly one Stop entry must exist even after double injection (no duplicates)"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container All Hooks — combined injection (real-image e2e)"

    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests — prerequisites not met"
        exit 0
    fi

    setup_test_project

    # Structural: all libs present and executable
    run_test test_all_inject_libs_exist_in_container
    run_test test_all_inject_libs_executable_in_container

    # Combined injection end-to-end
    run_test test_combined_injection_all_keys_coexist
    run_test test_combined_injection_exactly_one_stop_hook

    cleanup_test_project

    print_summary
}

main "$@"
