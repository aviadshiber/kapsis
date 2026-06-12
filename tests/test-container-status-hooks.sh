#!/usr/bin/env bash
#===============================================================================
# Test: Container Status Hook Injection (real-image e2e)
#
# Verifies that inject-status-hooks.sh is shipped in the container image and
# that inject_claude_hooks() produces a correct settings.json when run INSIDE
# the built kapsis-sandbox image — not sourced from the host source tree.
#
# Catches the class of bug where:
#   - scripts/lib/inject-status-hooks.sh exists on the host source tree
#   - scripts/entrypoint.sh sources it
#   - the matching COPY line in Containerfile is forgotten
#   - inject_claude_hooks() silently no-ops at runtime
#   - hooks never fire for any agent run
#
# Counterpart to the host-sourced tests in test-host-inject-gist-hook.sh and
# test-host-claude-live-api.sh; those tests prove inject-script logic on the
# host, this test proves the same scripts are correctly packaged in the image.
#
# REQUIRES: Container environment (Podman) — auto-skipped via skip_if_no_overlay_rw.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES: File presence + executable + sourceable
#===============================================================================

test_inject_status_hooks_lib_exists() {
    log_test "Testing inject-status-hooks.sh exists in container image"

    setup_container_test "status-hooks-exists"

    local output
    output=$(run_in_container "test -f /opt/kapsis/lib/inject-status-hooks.sh && echo EXISTS || echo MISSING")

    cleanup_container_test

    assert_contains "$output" "EXISTS" \
        "inject-status-hooks.sh must exist at /opt/kapsis/lib/ — Containerfile needs a COPY line for it"
}

test_inject_status_hooks_lib_executable() {
    log_test "Testing inject-status-hooks.sh is executable (chmod 755)"

    setup_container_test "status-hooks-exec"

    # Three-state markers so the failure diagnostic distinguishes a lib that
    # was never COPY'd (LIB_MISSING) from one that lost its executable bit
    # (LIB_PRESENT_NOT_EXECUTABLE). Markers are deliberately non-overlapping:
    # assert_contains is substring-based, so EXECUTABLE/NOT_EXECUTABLE-style
    # markers would make the success assertion match the failure output too.
    local output
    output=$(run_in_container "
        if [[ -x /opt/kapsis/lib/inject-status-hooks.sh ]]; then
            echo LIB_EXECUTABLE
        elif [[ -e /opt/kapsis/lib/inject-status-hooks.sh ]]; then
            echo LIB_PRESENT_NOT_EXECUTABLE
        else
            echo LIB_MISSING
        fi
    ")

    cleanup_container_test

    assert_contains "$output" "LIB_EXECUTABLE" \
        "inject-status-hooks.sh must be executable — covered by the Containerfile chmod 755 step"
    assert_not_contains "$output" "LIB_PRESENT_NOT_EXECUTABLE" \
        "inject-status-hooks.sh exists but is not executable — the Containerfile chmod 755 step was lost"
    assert_not_contains "$output" "LIB_MISSING" \
        "inject-status-hooks.sh is missing entirely — Containerfile needs a COPY line for it"
}

test_inject_claude_hooks_function_callable() {
    log_test "Testing inject_claude_hooks function is sourceable + callable"

    setup_container_test "status-hooks-func"

    local output
    output=$(run_in_container "
        source /opt/kapsis/lib/logging.sh
        source /opt/kapsis/lib/inject-status-hooks.sh
        type inject_claude_hooks >/dev/null && echo SOURCEABLE
    ")

    cleanup_container_test

    assert_contains "$output" "SOURCEABLE" \
        "inject_claude_hooks function should be available after sourcing the lib"
}

#===============================================================================
# TEST CASES: End-to-end — injection produces correct settings.json in container
#===============================================================================

# Mount a fixture ~/.claude dir into the container, run inject_claude_hooks,
# and assert the resulting settings.json contains hook commands that point to
# /opt/kapsis/hooks/ (not host paths — the bug this test catches is exactly
# when the COPY was missing and the host path leaked in via a sourced fallback).
test_inject_claude_hooks_produces_container_paths() {
    log_test "Testing inject_claude_hooks writes hooks pointing to /opt/kapsis/hooks/ (not host)"

    setup_container_test "status-hooks-paths"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-hooks-e2e-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    mkdir -p "$fixture_root/.claude"
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
        -e KAPSIS_STATUS_AGENT_ID="container-test-$$" \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            echo "----SETTINGS_CONTENT_START----"
            cat /home/developer/.claude/settings.json
            echo "----SETTINGS_CONTENT_END----"
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "inject_claude_hooks should complete without error (container output: $container_output)"
    assert_contains "$container_output" "SETTINGS_CONTENT_START" \
        "Container must produce settings.json output"
    assert_contains "$container_output" "/opt/kapsis/hooks/" \
        "Hook commands must point to /opt/kapsis/hooks/ (container-internal paths, not host paths)"
    assert_contains "$container_output" "kapsis-status-hook.sh" \
        "Status hook must be present in settings.json"
    assert_contains "$container_output" "kapsis-stop-hook.sh" \
        "Stop hook must be present in settings.json"
}

# The path-string assertions above are necessary but not sufficient: those
# strings are hardcoded via `jq --arg` in inject-status-hooks.sh and would land
# in settings.json even if the hook scripts themselves were never COPY'd into
# the image. Close the gap by reading every hook command back out of
# settings.json — exactly as Claude Code would — and asserting each resolved
# path is an executable file inside the container. Removing either
# `COPY scripts/hooks/kapsis-status-hook.sh` or
# `COPY scripts/hooks/kapsis-stop-hook.sh` from the Containerfile fails here.
# Mirrors test_gist_hook_command_is_executable_in_container in
# test-container-gist-hook.sh.
test_injected_hook_commands_are_executable_in_container() {
    log_test "Testing hook commands in settings.json resolve to executable files in container"

    setup_container_test "status-hooks-cmd-exec"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-hooks-exec-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    mkdir -p "$fixture_root/.claude"
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
        -e KAPSIS_STATUS_AGENT_ID="container-test-$$" \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            jq -r "(.hooks.PostToolUse[].hooks[].command), (.hooks.Stop[].hooks[].command)" \
                /home/developer/.claude/settings.json | while IFS= read -r hook_cmd; do
                if [[ -x "$hook_cmd" ]]; then
                    echo "HOOK_CMD_EXECUTABLE: $hook_cmd"
                elif [[ -e "$hook_cmd" ]]; then
                    echo "HOOK_CMD_PRESENT_NOT_EXECUTABLE: $hook_cmd"
                else
                    echo "HOOK_CMD_MISSING: $hook_cmd"
                fi
            done
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "Container script should complete without error (container output: $container_output)"
    assert_contains "$container_output" "HOOK_CMD_EXECUTABLE: /opt/kapsis/hooks/kapsis-status-hook.sh" \
        "Status hook command read back from settings.json must be an executable file — Containerfile needs the kapsis-status-hook.sh COPY"
    assert_contains "$container_output" "HOOK_CMD_EXECUTABLE: /opt/kapsis/hooks/kapsis-stop-hook.sh" \
        "Stop hook command read back from settings.json must be an executable file — Containerfile needs the kapsis-stop-hook.sh COPY"
    assert_not_contains "$container_output" "HOOK_CMD_MISSING" \
        "Every hook command injected into settings.json must exist inside the image"
    assert_not_contains "$container_output" "HOOK_CMD_PRESENT_NOT_EXECUTABLE" \
        "Every hook command injected into settings.json must have chmod +x inside the image"
}

# Regression guard for issue #351: inject_claude_hooks must write to settings.json
# and must never create settings.local.json (Claude Code ignores .local.json at
# user scope — hooks placed there silently never fire).
test_inject_claude_hooks_no_settings_local_json() {
    log_test "Testing inject_claude_hooks never creates settings.local.json (#351 regression)"

    setup_container_test "status-hooks-no-local"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-status-hooks-local-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    mkdir -p "$fixture_root/.claude"
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
        -e KAPSIS_STATUS_AGENT_ID="container-test-$$" \
        -e KAPSIS_INJECT_GIST=true \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            if [[ -f /home/developer/.claude/settings.local.json ]]; then
                echo "LOCAL_JSON_CREATED"
            else
                echo "NO_LOCAL_JSON"
            fi
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "inject_claude_hooks should complete without error"
    assert_contains "$container_output" "NO_LOCAL_JSON" \
        "settings.local.json must never be created — regression guard for issue #351"
    assert_not_contains "$container_output" "LOCAL_JSON_CREATED" \
        "settings.local.json was incorrectly created by inject_claude_hooks"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container Status Hook Injection (real-image e2e)"

    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests — prerequisites not met"
        exit 0
    fi

    setup_test_project

    # Presence + sourceability
    run_test test_inject_status_hooks_lib_exists
    run_test test_inject_status_hooks_lib_executable
    run_test test_inject_claude_hooks_function_callable

    # End-to-end: injection produces correct paths + regression guards
    run_test test_inject_claude_hooks_produces_container_paths
    run_test test_injected_hook_commands_are_executable_in_container
    run_test test_inject_claude_hooks_no_settings_local_json

    cleanup_test_project

    print_summary
}

main "$@"
