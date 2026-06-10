#!/usr/bin/env bash
#===============================================================================
# Test: Container Gist Hook — injection and dispatch inside real image
#
# Proves that the gist hook injection path works end-to-end inside the built
# container image: inject_claude_hooks() writes a gist hook entry whose command
# points to /opt/kapsis/hooks/kapsis-gist-hook.sh, and that command is both
# executable AND able to produce a gist file when dispatched with a tool event.
#
# Counterpart to test-host-inject-gist-hook.sh, which exercises the same logic
# sourced directly from the host source tree. This test exercises the same code
# from inside the packaged image, catching any COPY/chmod/path-substitution
# regression that the host-sourced test cannot detect.
#
# REQUIRES: Container environment (Podman) — auto-skipped via skip_if_no_overlay_rw.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES: Gist hook injection
#===============================================================================

# When KAPSIS_INJECT_GIST=true the gist hook must be the first PostToolUse entry
# and its command must be under /opt/kapsis/hooks/ (not a host path).
test_gist_hook_injected_when_enabled() {
    log_test "Testing gist hook appears in settings.json when KAPSIS_INJECT_GIST=true"

    setup_container_test "gist-hook-inject"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-gist-inject-XXXXXX")
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
        -e KAPSIS_STATUS_AGENT_ID="gist-inject-$$" \
        -e KAPSIS_INJECT_GIST=true \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            echo "----GIST_CMD_START----"
            jq -r ".hooks.PostToolUse[0].hooks[0].command" /home/developer/.claude/settings.json
            echo "----GIST_CMD_END----"
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "inject_claude_hooks should complete without error (output: $container_output)"
    assert_contains "$container_output" "kapsis-gist-hook.sh" \
        "Gist hook must be the first PostToolUse entry when KAPSIS_INJECT_GIST=true"
    assert_contains "$container_output" "/opt/kapsis/hooks/" \
        "Gist hook command must point to /opt/kapsis/hooks/ (container-internal path)"
}

# The gist hook command written into settings.json must be an executable binary
# at the exact path it was injected — not just any path that happens to contain
# 'kapsis-gist-hook.sh'.
test_gist_hook_command_is_executable_in_container() {
    log_test "Testing gist hook command injected into settings.json is executable in container"

    setup_container_test "gist-hook-exec"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-gist-exec-XXXXXX")
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
        -e KAPSIS_STATUS_AGENT_ID="gist-exec-$$" \
        -e KAPSIS_INJECT_GIST=true \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks
            gist_cmd=$(jq -r ".hooks.PostToolUse[0].hooks[0].command" /home/developer/.claude/settings.json)
            if [[ -x "$gist_cmd" ]]; then
                echo "GIST_CMD_EXECUTABLE"
            else
                echo "GIST_CMD_NOT_EXECUTABLE: $gist_cmd"
            fi
        ' 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "Container script should complete without error"
    assert_contains "$container_output" "GIST_CMD_EXECUTABLE" \
        "Gist hook command read from settings.json must be executable inside the container"
    assert_not_contains "$container_output" "GIST_CMD_NOT_EXECUTABLE" \
        "Gist hook at the injected path must have chmod +x inside the container image"
}

#===============================================================================
# TEST CASES: Gist hook dispatch (core regression for #351)
#===============================================================================

# End-to-end: inject hooks, read the gist command from settings.json exactly as
# Claude Code does, dispatch it with a tool event, and assert that gist.txt is
# written. This is the same dispatch path test-host-inject-gist-hook.sh exercises
# on the host — but here it runs entirely inside the container image, confirming
# that the binary is reachable and functional at the packaged path.
test_gist_hook_dispatch_creates_gist_file() {
    log_test "Testing gist hook dispatch inside container creates gist.txt"

    setup_container_test "gist-hook-dispatch"

    local fixture_root
    fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-gist-dispatch-XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$fixture_root'" RETURN

    mkdir -p "$fixture_root/.claude" "$fixture_root/.kapsis"
    chmod -R a+rwX "$fixture_root"

    local tool_event='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test: container gist dispatch\""}}'

    local container_output exit_code=0
    container_output=$(podman run --rm \
        --name "$CONTAINER_TEST_ID" \
        --userns=keep-id \
        --security-opt label=disable \
        -v "$fixture_root/.claude:/home/developer/.claude:rw" \
        -v "$fixture_root/.kapsis:/home/developer/.kapsis:rw" \
        -e CI="${CI:-true}" \
        -e KAPSIS_NETWORK_MODE="${KAPSIS_NETWORK_MODE:-open}" \
        -e KAPSIS_AGENT_TYPE=claude-cli \
        -e KAPSIS_STATUS_AGENT_ID="gist-dispatch-$$" \
        -e KAPSIS_INJECT_GIST=true \
        -e HOME=/home/developer \
        "$KAPSIS_TEST_IMAGE" \
        bash -c "
            set -e
            source /opt/kapsis/lib/logging.sh
            source /opt/kapsis/lib/inject-status-hooks.sh
            inject_claude_hooks

            # Read the gist hook command exactly as Claude Code does
            gist_cmd=\$(jq -r '.hooks.PostToolUse[0].hooks[0].command' /home/developer/.claude/settings.json)

            # Dispatch with a git-commit tool event (same event type used in the
            # host-sourced integration test to prove gist content is correct).
            # The env assignments MUST prefix the hook side of the pipeline:
            # in 'VAR=x cmd1 | cmd2' the prefix binds to cmd1 only, so placing
            # them on printf would leave the hook without KAPSIS_GIST_FILE and
            # it would write to the default /workspace path instead.
            printf '%s' '$tool_event' | \
                KAPSIS_GIST_FILE=/home/developer/.kapsis/gist.txt \
                KAPSIS_INJECT_GIST=true \
                KAPSIS_STATUS_AGENT_ID=gist-dispatch-$$ \
                bash \"\$gist_cmd\" >/dev/null 2>&1 || true

            if [[ -f /home/developer/.kapsis/gist.txt ]]; then
                echo 'GIST_CREATED'
                cat /home/developer/.kapsis/gist.txt
            else
                echo 'GIST_NOT_CREATED'
            fi
        " 2>&1) || exit_code=$?

    cleanup_container_test

    assert_exit_code 0 "$exit_code" \
        "Container dispatch script should complete without error (output: $container_output)"
    assert_contains "$container_output" "GIST_CREATED" \
        "Gist hook dispatched from the command written to settings.json must create gist.txt inside the container"
    assert_not_contains "$container_output" "GIST_NOT_CREATED" \
        "Gist hook dispatch must produce gist.txt — if this fails the hook binary at /opt/kapsis/hooks/ is broken"
    assert_contains "$container_output" "Committing:" \
        "Gist content must reflect the git-commit tool event"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Container Gist Hook — injection and dispatch (real-image e2e)"

    if ! skip_if_no_overlay_rw; then
        echo "Skipping container tests — prerequisites not met"
        exit 0
    fi

    setup_test_project

    # Injection correctness
    run_test test_gist_hook_injected_when_enabled
    run_test test_gist_hook_command_is_executable_in_container

    # End-to-end dispatch (core regression guard for #351)
    run_test test_gist_hook_dispatch_creates_gist_file

    cleanup_test_project

    print_summary
}

main "$@"
