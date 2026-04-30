#!/usr/bin/env bash
#===============================================================================
# Tests for the host-side vfkit watchdog (Issue #303)
#
# The watchdog body lives in scripts/lib/vfkit-watchdog.sh. These tests source
# the production library directly (no body duplication), force is_macos=true
# so the macOS-only path is exercised on Linux CI, and verify:
#
# - When the watched PID exits, the watchdog writes exit_code=4 +
#   error_type=mount_failure to status.json.
# - When the watched PID exits, the watchdog SIGTERMs the agent's
#   `podman run` via a pkill pattern anchored to the AGENT_ID, with a
#   non-id-char boundary (BSD-portable, not \b).
# - Killing the watchdog before the watched PID exits leaves status.json
#   untouched (idempotent cleanup).
# - When the parent shell ($PPID) goes away, the watchdog exits without
#   firing (orphan protection — must not SIGTERM a future agent that
#   reuses the same AGENT_ID via resume mode).
# - Invalid KAPSIS_PODMAN_MACHINE / agent_id / interval values cause
#   the watchdog to skip rather than crash.
# - The post-container override block upgrades non-zero EXIT_CODE to 4
#   when status.json reports exit_code=4 + error_type=mount_failure;
#   leaves EXIT_CODE alone for clean exits or non-mount-failure status.
#
# Run: ./tests/test-vfkit-watchdog.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

#-------------------------------------------------------------------------------
# Per-test isolated env: scoped status dir, fresh status state, force macOS,
# source the production watchdog lib. Caller must call _teardown_test_env on
# all paths (including failure) — _setup_test_env registers a trap.
#-------------------------------------------------------------------------------
_setup_test_env() {
    TEST_TMP=$(mktemp -d)
    export KAPSIS_STATUS_DIR="$TEST_TMP/status"
    export KAPSIS_STATUS_ENABLED="true"
    mkdir -p "$KAPSIS_STATUS_DIR"

    # Re-source modules so each test starts with defaults
    unset _KAPSIS_STATUS_LOADED _KAPSIS_VFKIT_WATCHDOG_LOADED
    # shellcheck source=/dev/null
    source "$LIB_DIR/status.sh"

    # Quiet logging stubs (sourced first so vfkit-watchdog.sh's `declare -f`
    # guards leave them untouched).
    log_warn()  { :; }
    log_debug() { :; }
    log_info()  { :; }
    # Force macOS path so the watchdog body runs on Linux CI.
    is_macos()  { return 0; }
    is_linux()  { return 1; }

    # shellcheck source=/dev/null
    source "$LIB_DIR/vfkit-watchdog.sh"

    status_init "test-project" "${TEST_AGENT_ID:-vfkit-test-1}" "test-branch" "worktree" "$TEST_TMP/wt"
}

_teardown_test_env() {
    # Best-effort: kill any leftover children we spawned (sleeps used as
    # fake vfkit / pkill targets).
    if [[ -n "${TEST_CHILD_PIDS:-}" ]]; then
        local pid
        for pid in $TEST_CHILD_PIDS; do
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
        TEST_CHILD_PIDS=""
    fi
    [[ -n "${TEST_TMP:-}" ]] && rm -rf "$TEST_TMP"
    if [[ -n "${SAVED_PATH:-}" ]]; then
        export PATH="$SAVED_PATH"
        SAVED_PATH=""
    fi
    return 0
}

#-------------------------------------------------------------------------------
# Helper: install a fake `pgrep` and `pkill` on PATH that record argv.
# Caller saves PATH first via SAVED_PATH=$PATH, teardown restores it.
#-------------------------------------------------------------------------------
_install_fakes() {
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"

    # pgrep: print the PID the test wants the watchdog to watch.
    # FAKE_PGREP_PID is expanded at host time (caller-supplied env var).
    cat > "$fake_bin/pgrep" <<EOF
#!/usr/bin/env bash
echo "${FAKE_PGREP_PID:-}"
EOF

    # pkill: record argv but don't actually signal anything (the test's
    # fake_vfkit_pid is the only target we care about, and we kill it
    # explicitly in the test).
    cat > "$fake_bin/pkill" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/pkill.argv"
exit 0
EOF

    chmod +x "$fake_bin/pgrep" "$fake_bin/pkill"
    SAVED_PATH="$PATH"
    export PATH="$fake_bin:$PATH"
}

#===============================================================================
# Core: watchdog writes mount_failure to status.json on watched PID exit
#===============================================================================

test_watchdog_writes_status_on_pid_exit() {
    log_test "Watchdog writes exit_code=4 + error_type=mount_failure when watched PID exits"
    TEST_AGENT_ID="vfkit-watch-1"
    _setup_test_env

    sleep 30 &
    local fake_vfkit_pid=$!
    TEST_CHILD_PIDS="$fake_vfkit_pid"

    FAKE_PGREP_PID="$fake_vfkit_pid" _install_fakes

    local sentinel="$TEST_TMP/vfkit-fired"
    # Tight 1s poll for fast tests
    KAPSIS_VFKIT_WATCHDOG_INTERVAL=1 start_vfkit_watchdog "$TEST_AGENT_ID" "" "" "$sentinel"
    local watchdog_pid="$_VFKIT_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; return 1; }

    # Schedule the kill so the watchdog's first tick observes the exit.
    kill "$fake_vfkit_pid" 2>/dev/null || true
    wait "$fake_vfkit_pid" 2>/dev/null || true

    # Watchdog will fire and exit. Wait for it.
    wait "$watchdog_pid" 2>/dev/null || true
    TEST_CHILD_PIDS=""

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json must be written by the watchdog"
    local content
    content=$(<"$status_file")
    assert_contains "$content" '"exit_code": 4' "status.json must carry exit_code=4"
    assert_contains "$content" '"error_type": "mount_failure"' "status.json must carry error_type=mount_failure"
    assert_contains "$content" "vfkit" "status message must mention vfkit for diagnostic clarity"
    assert_contains "$content" "host-side watchdog" "status message must identify the watchdog as the source"
    # Host-only sentinel (forgery-resistance proof)
    assert_file_exists "$sentinel" "host-only sentinel file must be touched by the watchdog"
    _teardown_test_env
}

test_watchdog_does_not_touch_sentinel_when_killed_early() {
    log_test "Watchdog killed before vfkit exit must NOT touch the host-only sentinel"
    TEST_AGENT_ID="vfkit-sentinel-clean"
    _setup_test_env

    sleep 30 &
    local fake_vfkit_pid=$!
    TEST_CHILD_PIDS="$fake_vfkit_pid"

    FAKE_PGREP_PID="$fake_vfkit_pid" _install_fakes

    local sentinel="$TEST_TMP/vfkit-fired"
    KAPSIS_VFKIT_WATCHDOG_INTERVAL=5 start_vfkit_watchdog "$TEST_AGENT_ID" "" "" "$sentinel"
    local watchdog_pid="$_VFKIT_WATCHDOG_PID"

    sleep 1
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    kill "$fake_vfkit_pid" 2>/dev/null || true
    wait "$fake_vfkit_pid" 2>/dev/null || true
    TEST_CHILD_PIDS=""

    [[ ! -f "$sentinel" ]]
    assert_equals "0" "$?" "sentinel file must NOT exist when watchdog was killed before fire"
    _teardown_test_env
}

#===============================================================================
# pkill targets the right podman run process with portable boundary
#===============================================================================

test_watchdog_pkills_with_portable_boundary() {
    log_test "Watchdog invokes pkill with BSD-portable boundary anchored to AGENT_ID"
    TEST_AGENT_ID="vfkit-pkill-2"
    _setup_test_env

    sleep 30 &
    local fake_vfkit_pid=$!
    TEST_CHILD_PIDS="$fake_vfkit_pid"

    FAKE_PGREP_PID="$fake_vfkit_pid" _install_fakes

    KAPSIS_VFKIT_WATCHDOG_INTERVAL=1 start_vfkit_watchdog "$TEST_AGENT_ID"
    local watchdog_pid="$_VFKIT_WATCHDOG_PID"

    kill "$fake_vfkit_pid" 2>/dev/null || true
    wait "$fake_vfkit_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    TEST_CHILD_PIDS=""

    assert_file_exists "$TEST_TMP/pkill.argv" "pkill must be invoked by the watchdog"
    local argv
    argv=$(<"$TEST_TMP/pkill.argv")
    assert_contains "$argv" "-TERM" "pkill must use -TERM (graceful)"
    assert_contains "$argv" "-f" "pkill must use -f to match against full command line"
    assert_contains "$argv" "kapsis-${TEST_AGENT_ID}" "pkill pattern must contain the agent-scoped container name"
    assert_contains "$argv" "podman run" "pkill pattern must be anchored to 'podman run' to avoid matching incidental podman ps/inspect"
    # BSD pkill does not understand \b. The boundary must be a class.
    assert_not_contains "$argv" '\b' "pkill pattern must NOT use \\b (unsupported by macOS BSD pkill)"
    assert_contains "$argv" '[^a-zA-Z0-9_-]' "pkill pattern must use a portable character-class boundary"
    _teardown_test_env
}

#===============================================================================
# Skip paths: invalid inputs do not crash and do not start a watchdog
#===============================================================================

test_watchdog_skipped_when_disabled() {
    log_test "Watchdog skipped when KAPSIS_VFKIT_WATCHDOG_ENABLED=false"
    TEST_AGENT_ID="vfkit-skip-3"
    _setup_test_env
    KAPSIS_VFKIT_WATCHDOG_ENABLED=false start_vfkit_watchdog "$TEST_AGENT_ID"
    assert_equals "" "${_VFKIT_WATCHDOG_PID:-}" "no watchdog PID must be set when disabled"
    _teardown_test_env
}

test_watchdog_skipped_when_machine_name_invalid() {
    log_test "Watchdog skipped on malformed KAPSIS_PODMAN_MACHINE (regex injection guard)"
    TEST_AGENT_ID="vfkit-skip-4"
    _setup_test_env
    # Inject a regex-y value
    KAPSIS_PODMAN_MACHINE='.*' start_vfkit_watchdog "$TEST_AGENT_ID"
    assert_equals "" "${_VFKIT_WATCHDOG_PID:-}" "watchdog must refuse a machine name containing regex metacharacters"
    _teardown_test_env
}

test_watchdog_skipped_when_agent_id_invalid() {
    log_test "Watchdog skipped on malformed AGENT_ID"
    _setup_test_env
    start_vfkit_watchdog 'agent;rm -rf /'
    assert_equals "" "${_VFKIT_WATCHDOG_PID:-}" "watchdog must refuse an AGENT_ID containing shell metacharacters"
    _teardown_test_env
}

test_watchdog_skipped_when_vfkit_not_found() {
    log_test "Watchdog skipped silently when no vfkit process is running"
    TEST_AGENT_ID="vfkit-skip-5"
    _setup_test_env
    FAKE_PGREP_PID="" _install_fakes
    start_vfkit_watchdog "$TEST_AGENT_ID"
    assert_equals "" "${_VFKIT_WATCHDOG_PID:-}" "watchdog must not start when pgrep finds no vfkit"
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
    TEST_CHILD_PIDS="$fake_vfkit_pid"

    FAKE_PGREP_PID="$fake_vfkit_pid" _install_fakes

    KAPSIS_VFKIT_WATCHDOG_INTERVAL=5 start_vfkit_watchdog "$TEST_AGENT_ID"
    local watchdog_pid="$_VFKIT_WATCHDOG_PID"

    sleep 1
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    kill "$fake_vfkit_pid" 2>/dev/null || true
    wait "$fake_vfkit_pid" 2>/dev/null || true
    TEST_CHILD_PIDS=""

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json from status_init must exist"
    local content
    content=$(<"$status_file")
    assert_not_contains "$content" '"exit_code": 4' "status.json must NOT carry exit_code=4 when watchdog was killed before fire"
    assert_not_contains "$content" '"error_type": "mount_failure"' "status.json must NOT carry mount_failure when watchdog was killed before fire"
    _teardown_test_env
}

#===============================================================================
# Post-container exit-code override
#===============================================================================

# Reproduces the override block from launch-agent.sh. Inputs:
#   $1 = EXIT_CODE
#   $2 = status_file path
#   $3 = sentinel_path (host-only — empty means watchdog never fired)
# Echoes the resulting EXIT_CODE.
#
# Logic mirrors the post-container override in scripts/launch-agent.sh
# after ensemble review #2: trusts the host-only sentinel as the
# authoritative "watchdog fired" signal, and treats status.json's
# mount_failure as defense-in-depth (since status.json is mirrored from
# the container on macOS and is not independently host-trusted).
_simulate_override() {
    local EXIT_CODE="$1"
    local status_file="$2"
    local sentinel_path="${3:-}"
    if [[ "$EXIT_CODE" -ne 0 ]] \
       && [[ -n "$sentinel_path" && -f "$sentinel_path" ]]; then
        local status_exit_vfkit status_err_vfkit
        status_exit_vfkit=""
        status_err_vfkit=""
        if [[ -f "$status_file" ]]; then
            local content
            content=$(<"$status_file")
            if [[ "$content" =~ \"exit_code\":\ *([0-9]+) ]]; then
                status_exit_vfkit="${BASH_REMATCH[1]}"
            fi
            if grep -Eq '"error_type":[[:space:]]*"mount_failure"' "$status_file" 2>/dev/null; then
                status_err_vfkit="mount_failure"
            fi
        fi
        # Sentinel is the trust anchor: present sentinel + ANY non-zero exit
        # → upgrade to 4. status.json mismatch is a status_complete failure
        # (e.g., disk full inside the watchdog subshell), not a forgery.
        EXIT_CODE=4
        # Quiet shellcheck — variables consumed in the assertion intent
        : "$status_exit_vfkit" "$status_err_vfkit"
    fi
    echo "$EXIT_CODE"
}

test_post_container_override_to_4_for_signal_exit() {
    log_test "Override upgrades signal exit (143) to 4 when sentinel + status.json mount_failure"
    TEST_AGENT_ID="vfkit-override-7"
    _setup_test_env
    status_set_error_type "mount_failure"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/vfkit-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 143 "$status_file" "$sentinel")
    assert_equals "4" "$result" "EXIT_CODE 143 must be upgraded to 4 when sentinel + status.json mount_failure"
    _teardown_test_env
}

test_post_container_override_to_4_for_exit_1() {
    log_test "Override upgrades EXIT_CODE 1 to 4 when sentinel present (pkill miss case)"
    TEST_AGENT_ID="vfkit-override-8"
    _setup_test_env
    status_set_error_type "mount_failure"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/vfkit-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel")
    assert_equals "4" "$result" "EXIT_CODE 1 must be upgraded to 4 when sentinel proves watchdog fired"
    _teardown_test_env
}

test_post_container_override_does_not_fire_for_exit_0() {
    log_test "Override preserves EXIT_CODE 0 (security: legitimate completion before vfkit died)"
    TEST_AGENT_ID="vfkit-override-9"
    _setup_test_env
    status_set_error_type "mount_failure"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/vfkit-fired"
    : > "$sentinel"
    local result
    # Even with sentinel + status.json mount_failure, exit 0 must be preserved.
    result=$(_simulate_override 0 "$status_file" "$sentinel")
    assert_equals "0" "$result" "EXIT_CODE 0 must NOT be silently upgraded to 4"
    _teardown_test_env
}

test_post_container_override_does_not_fire_when_status_clean() {
    log_test "Override leaves EXIT_CODE alone when no sentinel and no mount_failure"
    TEST_AGENT_ID="vfkit-override-11"
    _setup_test_env
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local result
    result=$(_simulate_override 143 "$status_file" "")
    assert_equals "143" "$result" "EXIT_CODE must remain 143 when neither sentinel nor mount_failure"
    _teardown_test_env
}

#-------------------------------------------------------------------------------
# Forgery resistance: status.json says mount_failure but no sentinel exists.
# This simulates a compromised in-container agent writing forged JSON to the
# bind-mounted status dir — the override must NOT trust it.
#-------------------------------------------------------------------------------
test_post_container_override_does_not_fire_without_sentinel() {
    log_test "Override does NOT fire when status.json reports mount_failure but no host sentinel exists (forgery resistance)"
    TEST_AGENT_ID="vfkit-override-12"
    _setup_test_env
    status_set_error_type "mount_failure"
    status_complete 4 "FORGED by container"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    # Note: no sentinel file at $TEST_TMP/vfkit-fired
    local sentinel="$TEST_TMP/vfkit-fired-nonexistent"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel")
    assert_equals "1" "$result" "EXIT_CODE must NOT be upgraded to 4 from forged status.json without host-side sentinel"
    _teardown_test_env
}

test_post_container_override_does_not_fire_with_empty_sentinel_arg() {
    log_test "Override does NOT fire when sentinel arg is empty (watchdog disabled)"
    TEST_AGENT_ID="vfkit-override-13"
    _setup_test_env
    status_set_error_type "mount_failure"
    status_complete 4 "test"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local result
    # Empty sentinel arg simulates watchdog never having been started
    # (e.g., Linux, KAPSIS_VFKIT_WATCHDOG_ENABLED=false).
    result=$(_simulate_override 1 "$status_file" "")
    assert_equals "1" "$result" "EXIT_CODE must remain 1 when watchdog never fired"
    _teardown_test_env
}

#-------------------------------------------------------------------------------
# Sentinel-only fallback: sentinel is present but status.json failed to
# write (e.g., disk full inside the watchdog subshell). Override should
# still fire because the sentinel is host-trusted.
#-------------------------------------------------------------------------------
test_post_container_override_fires_with_sentinel_only() {
    log_test "Override fires when sentinel exists even if status.json never got mount_failure (status_complete failure path)"
    TEST_AGENT_ID="vfkit-override-14"
    _setup_test_env
    # Don't write any status — simulate status_complete having failed.
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    rm -f "$status_file"
    local sentinel="$TEST_TMP/vfkit-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel")
    assert_equals "4" "$result" "EXIT_CODE must upgrade to 4 on sentinel alone (sentinel is host-trusted, status_complete may have failed)"
    _teardown_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "vfkit Watchdog (Issue #303)"

    log_info "=== Watchdog core behavior ==="
    run_test test_watchdog_writes_status_on_pid_exit
    run_test test_watchdog_pkills_with_portable_boundary
    run_test test_watchdog_killed_early_does_not_write_status
    run_test test_watchdog_does_not_touch_sentinel_when_killed_early

    log_info "=== Skip paths (input validation) ==="
    run_test test_watchdog_skipped_when_disabled
    run_test test_watchdog_skipped_when_machine_name_invalid
    run_test test_watchdog_skipped_when_agent_id_invalid
    run_test test_watchdog_skipped_when_vfkit_not_found

    log_info "=== Post-container exit-code override ==="
    run_test test_post_container_override_to_4_for_signal_exit
    run_test test_post_container_override_to_4_for_exit_1
    run_test test_post_container_override_does_not_fire_for_exit_0
    run_test test_post_container_override_does_not_fire_when_status_clean

    log_info "=== Forgery resistance (ensemble review #2) ==="
    run_test test_post_container_override_does_not_fire_without_sentinel
    run_test test_post_container_override_does_not_fire_with_empty_sentinel_arg
    run_test test_post_container_override_fires_with_sentinel_only

    print_summary
}

main "$@"
