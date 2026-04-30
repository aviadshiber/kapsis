#!/usr/bin/env bash
#===============================================================================
# Tests for the host-side vfkit watchdog (Issue #303)
#
# Verifies the algorithmic core of the watchdog inserted in launch-agent.sh:
# - When the watched PID exits, the subshell writes exit_code=4 +
#   error_type=mount_failure to status.json via the status library.
# - When the watched PID exits, the subshell SIGTERMs the local podman
#   client matching the AGENT_ID-bearing argv (anchored pattern).
# - The post-container override block correctly upgrades EXIT_CODE 143/137
#   to 4 when status.json carries exit_code=4.
# - Killing the watchdog before the watched PID exits leaves status.json
#   untouched (idempotent cleanup).
#
# The watchdog body is reproduced inline here because the production
# implementation lives inside scripts/launch-agent.sh main() and is not
# directly sourceable. Production and test bodies must stay in sync — see
# Issue #303 PR description for rationale.
#
# Run: ./tests/test-vfkit-watchdog.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

#-------------------------------------------------------------------------------
# _watchdog_subshell <vfkit_pid> <interval> <agent_id>
#
# Re-implements the production subshell at scripts/launch-agent.sh
# (the body wrapped in `( set +e; while kill -0 ... ) &`). Tests run this
# in the foreground (no `&`) so we can wait on it deterministically.
#-------------------------------------------------------------------------------
_watchdog_subshell() {
    local _vfkit_pid="$1"
    local _watchdog_interval="$2"
    local _agent_id="$3"
    (
        set +e
        while kill -0 "$_vfkit_pid" 2>/dev/null; do
            sleep "$_watchdog_interval"
        done
        status_set_error_type "mount_failure" 2>/dev/null || true
        status_complete 4 "Workspace mount lost: vfkit (PID $_vfkit_pid) exited (host-side watchdog). Recovery: podman machine stop && podman machine start, then re-run." 2>/dev/null || true
        log_warn "KAPSIS_MOUNT_FAILURE[vfkit_watchdog]: vfkit (PID $_vfkit_pid) exited — virtio-fs mounts lost" 2>/dev/null || true
        pkill -TERM -f "podman run .*--name kapsis-${_agent_id}\b" 2>/dev/null || true
    )
}

#-------------------------------------------------------------------------------
# Per-test isolated env: scoped status dir and stub logging.
#-------------------------------------------------------------------------------
_setup_test_env() {
    TEST_TMP=$(mktemp -d)
    export KAPSIS_STATUS_DIR="$TEST_TMP/status"
    export KAPSIS_STATUS_ENABLED="true"
    mkdir -p "$KAPSIS_STATUS_DIR"
    # Force a fresh status state per test by re-sourcing the module.
    unset _KAPSIS_STATUS_LOADED
    # shellcheck source=/dev/null
    source "$LIB_DIR/status.sh"
    # Quiet logging
    log_warn()  { :; }
    log_debug() { :; }
    log_info()  { :; }
    status_init "test-project" "${TEST_AGENT_ID:-vfkit-test-1}" "test-branch" "worktree" "$TEST_TMP/wt"
}

_teardown_test_env() {
    rm -rf "$TEST_TMP"
}

#===============================================================================
# Core: watchdog writes mount_failure to status.json on watched PID exit
#===============================================================================

test_watchdog_writes_status_on_pid_exit() {
    log_test "Watchdog writes exit_code=4 + error_type=mount_failure when watched PID exits"
    TEST_AGENT_ID="vfkit-watch-1"
    _setup_test_env

    # Spawn a long sleep — stand-in for vfkit. Capture its PID.
    sleep 30 &
    local fake_vfkit_pid=$!

    # Schedule the kill so the watchdog's first sleep tick observes the exit.
    ( sleep 1; kill "$fake_vfkit_pid" 2>/dev/null || true ) &
    local killer_pid=$!

    # Run the watchdog body in the foreground with a tight 1s poll interval.
    _watchdog_subshell "$fake_vfkit_pid" 1 "$TEST_AGENT_ID"

    wait "$killer_pid" 2>/dev/null || true

    # Read status.json
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json must be written by the watchdog"
    local content
    content=$(<"$status_file")
    assert_contains "$content" '"exit_code": 4' "status.json must carry exit_code=4"
    assert_contains "$content" '"error_type": "mount_failure"' "status.json must carry error_type=mount_failure"
    assert_contains "$content" "vfkit" "status message must mention vfkit for diagnostic clarity"
    assert_contains "$content" "host-side watchdog" "status message must identify the watchdog as the source"

    _teardown_test_env
}

#===============================================================================
# pkill targets the right podman client process
#===============================================================================

test_watchdog_pkills_correct_target() {
    log_test "Watchdog invokes pkill with a pattern uniquely matching the agent's podman run"
    TEST_AGENT_ID="vfkit-pkill-2"
    _setup_test_env

    # PATH override: a fake pkill that records its argv to a file.
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/pkill" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$TEST_TMP/pkill.argv"
exit 0
EOF
    chmod +x "$fake_bin/pkill"
    local saved_path="$PATH"
    export PATH="$fake_bin:$PATH"

    sleep 30 &
    local fake_vfkit_pid=$!
    ( sleep 1; kill "$fake_vfkit_pid" 2>/dev/null || true ) &
    local killer_pid=$!

    _watchdog_subshell "$fake_vfkit_pid" 1 "$TEST_AGENT_ID"

    wait "$killer_pid" 2>/dev/null || true
    export PATH="$saved_path"

    assert_file_exists "$TEST_TMP/pkill.argv" "pkill must be invoked by the watchdog"
    local argv
    argv=$(<"$TEST_TMP/pkill.argv")
    assert_contains "$argv" "-TERM" "pkill must be invoked with -TERM (graceful)"
    assert_contains "$argv" "-f" "pkill must use -f to match against full command line"
    assert_contains "$argv" "kapsis-${TEST_AGENT_ID}" "pkill pattern must contain the agent-scoped container name"
    assert_contains "$argv" "podman run" "pkill pattern must be anchored to 'podman run' to avoid matching incidental podman ps/inspect"

    _teardown_test_env
}

#===============================================================================
# Post-container override: 143/137 + status.json exit_code=4 → EXIT_CODE=4
#===============================================================================

test_post_container_override_to_4_when_status_says_4() {
    log_test "Post-container override upgrades signal exit (143) to 4 when status.json reports 4"
    TEST_AGENT_ID="vfkit-override-3"
    _setup_test_env

    # Seed a complete status.json with exit_code=4 (as the watchdog would have written)
    status_set_error_type "mount_failure"
    status_complete 4 "test fixture: vfkit exited"

    # Reproduce the override block from launch-agent.sh
    local EXIT_CODE=143
    if [[ "$EXIT_CODE" -eq 143 || "$EXIT_CODE" -eq 137 ]]; then
        local status_exit_vfkit
        status_exit_vfkit=$(status_get_exit_code 2>/dev/null || echo "")
        if [[ "$status_exit_vfkit" == "4" ]]; then
            EXIT_CODE=4
        fi
    fi

    assert_equals "4" "$EXIT_CODE" "EXIT_CODE must be upgraded from 143 to 4 when status.json reports 4"

    _teardown_test_env
}

test_post_container_override_does_not_fire_for_normal_exit() {
    log_test "Post-container override leaves EXIT_CODE alone when not a signal exit"
    TEST_AGENT_ID="vfkit-override-4"
    _setup_test_env

    status_set_error_type "mount_failure"
    status_complete 4 "test fixture"

    # Non-signal exit must not be touched even if status.json says 4
    local EXIT_CODE=1
    if [[ "$EXIT_CODE" -eq 143 || "$EXIT_CODE" -eq 137 ]]; then
        local status_exit_vfkit
        status_exit_vfkit=$(status_get_exit_code 2>/dev/null || echo "")
        if [[ "$status_exit_vfkit" == "4" ]]; then
            EXIT_CODE=4
        fi
    fi

    assert_equals "1" "$EXIT_CODE" "EXIT_CODE=1 must not be silently upgraded to 4 (preserves agent-failure semantics)"

    _teardown_test_env
}

test_post_container_override_does_not_fire_when_status_clean() {
    log_test "Post-container override leaves EXIT_CODE alone when status.json has no exit_code=4"
    TEST_AGENT_ID="vfkit-override-5"
    _setup_test_env

    # Don't write status_complete — status.json has no exit_code (or exit_code != 4)
    local EXIT_CODE=143
    if [[ "$EXIT_CODE" -eq 143 || "$EXIT_CODE" -eq 137 ]]; then
        local status_exit_vfkit
        status_exit_vfkit=$(status_get_exit_code 2>/dev/null || echo "")
        if [[ "$status_exit_vfkit" == "4" ]]; then
            EXIT_CODE=4
        fi
    fi

    assert_equals "143" "$EXIT_CODE" "EXIT_CODE must remain 143 when status.json does not report mount failure"

    _teardown_test_env
}

#===============================================================================
# Cleanup: killing the watchdog before vfkit exits leaves status.json untouched
#===============================================================================

test_watchdog_killed_early_does_not_write_status() {
    log_test "Watchdog killed before watched PID exits does NOT touch status.json"
    TEST_AGENT_ID="vfkit-cleanup-6"
    _setup_test_env

    sleep 30 &
    local fake_vfkit_pid=$!

    # Run watchdog in the background (production pattern: '( ... ) &')
    _watchdog_subshell "$fake_vfkit_pid" 5 "$TEST_AGENT_ID" &
    local watchdog_pid=$!

    # Give the watchdog a moment to enter its kill -0 loop, then kill it
    sleep 1
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    # Now kill the fake vfkit — too late, the watchdog is already gone
    kill "$fake_vfkit_pid" 2>/dev/null || true
    wait "$fake_vfkit_pid" 2>/dev/null || true

    # Confirm fake vfkit got cleaned up (no zombie children)
    sleep 1

    # status.json should reflect only status_init (running), not the watchdog's complete-with-exit_code-4
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json from status_init must exist"
    local content
    content=$(<"$status_file")
    assert_not_contains "$content" '"exit_code": 4' "status.json must NOT carry exit_code=4 when watchdog was killed before fire"
    assert_not_contains "$content" '"error_type": "mount_failure"' "status.json must NOT carry mount_failure when watchdog was killed before fire"

    _teardown_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "vfkit Watchdog (Issue #303)"

    log_info "=== Watchdog core behavior ==="
    run_test test_watchdog_writes_status_on_pid_exit
    run_test test_watchdog_pkills_correct_target
    run_test test_watchdog_killed_early_does_not_write_status

    log_info "=== Post-container exit-code override ==="
    run_test test_post_container_override_to_4_when_status_says_4
    run_test test_post_container_override_does_not_fire_for_normal_exit
    run_test test_post_container_override_does_not_fire_when_status_clean

    print_summary
}

main "$@"
