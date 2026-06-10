#!/usr/bin/env bash
#===============================================================================
# Test: Container Plugin Hook Injection (real-image e2e)
#
# Verifies that Claude Code plugin hook injection actually works inside the
# built container image — same prior-art pattern as test-container-libs.sh,
# but targeting a different lib file and a richer end-to-end path.
#
# Catches the class of bug where:
#   - scripts/lib/inject-plugin-hooks.sh is added to the source tree
#   - scripts/entrypoint.sh starts sourcing it
#   - the matching COPY line in Containerfile is forgotten
#   - install_plugin_hooks() silently log_debug-skips at runtime
#   - plugin hooks never fire for any agent, no matter what the yaml says
#
# Original instance: commit 8d5eea8 (feat(plugins): inject Claude Code plugin
# hooks into settings.local.json) + PR #380 (fix(image): ship
# inject-plugin-hooks.sh in container + build-time guard).
#
# This test exercises the SAME image the user's agent uses (kapsis-sandbox via
# $KAPSIS_TEST_IMAGE), with the SAME env-var triggers launch-agent.sh sets
# (KAPSIS_INSTALL_PLUGINS=true, KAPSIS_AGENT_TYPE=claude-cli, KAPSIS_PLUGIN_WHITELIST=[]).
#
# REQUIRES: Container environment (Podman) — auto-skipped via skip_if_no_overlay_rw.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES: File presence + executable + sourceable
#===============================================================================

test_inject_plugin_hooks_lib_exists() {
    log_test "Testing inject-plugin-hooks.sh exists in container image"

    setup_container_test "plugin-hooks-exists"

    local output
    output=$(run_in_container "test -f /opt/kapsis/lib/inject-plugin-hooks.sh && echo EXISTS || echo MISSING")

    cleanup_container_test

    assert_contains "$output" "EXISTS" \
        "inject-plugin-hooks.sh should exist at /opt/kapsis/lib/ — Containerfile needs a COPY line for it (this is exactly the bug PR #380 fixed)"
}

test_inject_plugin_hooks_lib_executable() {
    log_test "Testing inject-plugin-hooks.sh is executable (chmod 755)"

    setup_container_test "plugin-hooks-exec"

    local output
    output=$(run_in_container "test -x /opt/kapsis/lib/inject-plugin-hooks.sh && echo EXECUTABLE || echo NOT_EXECUTABLE")

    cleanup_container_test

    assert_contains "$output" "EXECUTABLE" \
        "inject-plugin-hooks.sh should be executable — covered by the Containerfile chmod 755 step"
}

test_inject_plugin_hooks_function_callable() {
    log_test "Testing inject_plugin_hooks function is sourceable + callable"

    setup_container_test "plugin-hooks-func"

    local output
    output=$(run_in_container "
        source /opt/kapsis/lib/logging.sh
        source /opt/kapsis/lib/inject-plugin-hooks.sh
        type inject_plugin_hooks >/dev/null && echo SOURCEABLE
    ")

    cleanup_container_test

    assert_contains "$output" "SOURCEABLE" \
        "inject_plugin_hooks function should be available after sourcing the lib"
}

#===============================================================================
# TEST CASES: Entrypoint helper finds the script (NOT silent skip)
#===============================================================================

test_install_plugin_hooks_finds_script_when_enabled() {
    log_test "Testing entrypoint's install_plugin_hooks() locates the script (no silent skip)"

    setup_container_test "plugin-hooks-finds"

    # The bug: install_plugin_hooks() does `[ ! -f "$inject_script" ]` and
    # silently returns 0 with a log_debug line that the user never sees. We
    # detect that by running install_plugin_hooks with KAPSIS_LOG_LEVEL=debug
    # and asserting we see "Installing Claude Code plugin hooks..." (success
    # path) — NOT "Plugin hook injection script not found" (silent-skip path).
    local output
    output=$(run_in_container "
        set +e
        export KAPSIS_LOG_LEVEL=debug
        export KAPSIS_AGENT_TYPE=claude-cli
        export KAPSIS_INSTALL_PLUGINS=true
        export HOME=/tmp/fakehome
        mkdir -p \$HOME/.claude
        source /opt/kapsis/lib/logging.sh
        # Source entrypoint.sh selectively — extract just install_plugin_hooks
        # function definition. Avoids running the whole entrypoint flow which
        # would need a real workspace mount.
        eval \"\$(awk '/^install_plugin_hooks\\(\\) \\{\$/,/^\\}\$/' /opt/kapsis/entrypoint.sh)\"
        install_plugin_hooks 2>&1
    ")

    cleanup_container_test

    assert_not_contains "$output" "Plugin hook injection script not found" \
        "install_plugin_hooks should find the script — silent skip means Containerfile COPY is missing"
    assert_contains "$output" "Installing Claude Code plugin hooks" \
        "install_plugin_hooks should reach the 'Installing ...' log line (success path)"
}

#===============================================================================
# TEST CASES: End-to-end — fixture plugin actually lands in settings.json
#===============================================================================

# Stage a minimal plugin fixture in a host tmpdir, bind-mount it as the
# container's $HOME/.claude, run install_plugin_hooks, then read the
# modified settings.json from the host side and assert it now contains
# the fixture plugin's hook command.
test_plugin_hook_injected_into_settings_e2e() {
    log_test "Testing fixture plugin hook ends up in settings.json after injection"

    setup_container_test "plugin-hooks-e2e"

    # Build the fixture in a host tmpdir
    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-plugin-e2e-XXXXXX")
    # shellcheck disable=SC2064  # we WANT the path expanded now
    trap "rm -rf '$fixture_root'" RETURN

    # Plugin id encodes the marker we'll grep for in the output settings.json.
    local marker_cmd="MARKER_PLUGIN_HOOK_FIRED_$$"
    local plugin_id="test-plugin@e2e-marketplace"
    local plugin_install_path="/home/developer/.claude/plugins/cache/e2e-marketplace/test-plugin/1.0.0"

    mkdir -p "$fixture_root/.claude/plugins/cache/e2e-marketplace/test-plugin/1.0.0/hooks"

    # installed_plugins.json — already path-rewritten to container-internal paths.
    # v2 shape: each plugin id maps to an ARRAY of version entries (the injector
    # reads .value[0].installPath; a bare object here would be silently filtered
    # out by the schema-defense check in inject-plugin-hooks.sh).
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

    cat > "$fixture_root/.claude/plugins/cache/e2e-marketplace/test-plugin/1.0.0/hooks/hooks.json" <<EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit",
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

    # settings.json — must already exist (per inject-plugin-hooks.sh comment:
    # "settings.json should already exist (inject-status-hooks.sh ran first)").
    # The injector ALSO requires enabledPlugins[id] == true to inject the hook.
    cat > "$fixture_root/.claude/settings.json" <<EOF
{
  "enabledPlugins": {
    "$plugin_id": true
  },
  "hooks": {}
}
EOF

    # Make the fixture world-readable so the developer user (UID 1000) inside
    # the container can read it via --userns=keep-id mapping.
    chmod -R a+rwX "$fixture_root"

    # Run install_plugin_hooks against the fixture and let it mutate the
    # bind-mounted settings.json in place. Dump the final settings.json
    # content to stdout via a SETTINGS_CONTENT marker — the host-side bind
    # mount read is unreliable in CI (rootful Podman + --userns=keep-id
    # uid-mapping makes the post-merge mode-600 file owned by a uid the
    # runner cannot read, so cat falls back to "{}").
    local container_output exit_code=0
    container_output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$fixture_root/.claude:/home/developer/.claude:rw" \
        -e CI="${CI:-true}" \
        -e KAPSIS_NETWORK_MODE="${KAPSIS_NETWORK_MODE:-open}" \
        -e KAPSIS_AGENT_TYPE=claude-cli \
        -e KAPSIS_INSTALL_PLUGINS=true \
        -e KAPSIS_PLUGIN_WHITELIST='[]' \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-plugin-hooks.sh
            inject_plugin_hooks
            echo "----SETTINGS_CONTENT_START----"
            cat /home/developer/.claude/settings.json
            echo "----SETTINGS_CONTENT_END----"
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "inject_plugin_hooks should complete without error (container output: $container_output)"
    assert_contains "$container_output" "$marker_cmd" \
        "settings.json (in-container) should contain the fixture plugin's hook command after injection — container output was: $container_output"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container Plugin Hook Injection (real-image e2e)"

    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests — prerequisites not met"
        exit 0
    fi

    setup_test_project

    # Presence + sourceability
    run_test test_inject_plugin_hooks_lib_exists
    run_test test_inject_plugin_hooks_lib_executable
    run_test test_inject_plugin_hooks_function_callable

    # Helper resolution
    run_test test_install_plugin_hooks_finds_script_when_enabled

    # End-to-end: fixture plugin hook actually lands in settings.json
    run_test test_plugin_hook_injected_into_settings_e2e

    cleanup_test_project

    print_summary
}

main "$@"
