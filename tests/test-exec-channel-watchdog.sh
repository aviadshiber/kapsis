#!/usr/bin/env bash
#===============================================================================
# Tests for the host-side exec-channel watchdog (Issue #382)
#
# The watchdog body lives in scripts/lib/exec-channel-watchdog.sh. These tests
# source the production library directly (no body duplication), force
# is_macos=true so the macOS-only path is exercised on Linux CI, and verify:
#
# - When `podman exec <ctr> true` hangs N consecutive times, the watchdog
#   writes exit_code=4 + error_type=exec_channel_hang to status.json, touches
#   the host-only sentinel, and SIGTERMs the agent's `podman run` via a pkill
#   pattern anchored to the AGENT_ID with a BSD-portable boundary class.
# - A transient single failure that recovers before threshold does NOT cause
#   the watchdog to fire (counter reset semantics).
# - Killing the watchdog before threshold leaves the sentinel and status.json
#   untouched (idempotent cleanup).
# - When the parent shell goes away, the watchdog exits without firing
#   (orphan protection — must not fire on a future agent that reuses the same
#   AGENT_ID via resume mode).
# - Invalid AGENT_ID / container_name / timing knobs cause the watchdog to
#   skip rather than crash.
# - The post-container override block upgrades non-zero EXIT_CODE to 4 when
#   status.json reports exit_code=4 + error_type=exec_channel_hang AND the
#   host sentinel exists; leaves EXIT_CODE alone for clean exits or when
#   the sentinel is missing (forgery resistance).
#
# Run: ./tests/test-exec-channel-watchdog.sh
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
    unset _KAPSIS_STATUS_LOADED _KAPSIS_EXEC_CHANNEL_WATCHDOG_LOADED
    # shellcheck source=/dev/null
    source "$LIB_DIR/status.sh"

    # Quiet logging stubs (sourced first so exec-channel-watchdog.sh's
    # `declare -f` guards leave them untouched).
    log_warn()  { :; }
    log_debug() { :; }
    log_info()  { :; }
    # Force macOS path so the watchdog body runs on Linux CI.
    is_macos()  { return 0; }
    is_linux()  { return 1; }

    # shellcheck source=/dev/null
    source "$LIB_DIR/exec-channel-watchdog.sh"

    status_init "test-project" "${TEST_AGENT_ID:-exec-test-1}" "test-branch" "worktree" "$TEST_TMP/wt"
}

_teardown_test_env() {
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
# Helper: install a fake `podman`, `timeout`, and `pkill` on PATH.
#
# - `podman exec ... true` reads $FAKE_PODMAN_EXEC_MODE:
#     "hang"     — sleep 60 (will be killed by the fake `timeout`)
#     "ok"       — exit 0
#     "transient"— a file at $TEST_TMP/podman-fail-once toggles: present
#                  means this call fails once and removes the file, so the
#                  next call succeeds. Used to verify counter reset.
# - `timeout` is a real "kill after N seconds" stub (cheap, no GNU coreutils
#   dependency on macOS CI).
# - `pkill` records argv for assertion.
#-------------------------------------------------------------------------------
_install_fakes() {
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/podman" <<EOF
#!/usr/bin/env bash
# Only intercept "exec <ctr> true" — anything else is unexpected in tests.
if [[ "\$1" == "exec" && "\$3" == "true" ]]; then
    case "\${FAKE_PODMAN_EXEC_MODE:-ok}" in
        hang)
            sleep 60
            ;;
        ok)
            exit 0
            ;;
        transient)
            if [[ -f "$TEST_TMP/podman-fail-once" ]]; then
                rm -f "$TEST_TMP/podman-fail-once"
                sleep 60
            else
                exit 0
            fi
            ;;
        *)
            exit 0
            ;;
    esac
fi
exit 0
EOF

    # Tiny `timeout` shim: spawns child in background and kills it after N seconds.
    # Returns 124 on timeout (GNU semantics) so the watchdog's counter behavior matches prod.
    cat > "$fake_bin/timeout" <<'EOF'
#!/usr/bin/env bash
duration="$1"; shift
"$@" &
child_pid=$!
( sleep "$duration"; kill -KILL "$child_pid" 2>/dev/null ) &
killer_pid=$!
if wait "$child_pid" 2>/dev/null; then
    rc=$?
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    exit "$rc"
else
    rc=$?
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    # 137 (128+9) when killed by SIGKILL -> map to 124 (timeout semantics)
    if [[ "$rc" == "137" ]]; then exit 124; fi
    exit "$rc"
fi
EOF

    cat > "$fake_bin/pkill" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/pkill.argv"
exit 0
EOF

    chmod +x "$fake_bin/podman" "$fake_bin/timeout" "$fake_bin/pkill"
    SAVED_PATH="$PATH"
    export PATH="$fake_bin:$PATH"
}

#===============================================================================
# Core: watchdog fires after N consecutive probe timeouts
#===============================================================================

test_watchdog_fires_after_threshold() {
    log_test "Watchdog fires (status.json + sentinel + pkill) after N consecutive exec timeouts"
    TEST_AGENT_ID="exec-fire-1"
    _setup_test_env
    FAKE_PODMAN_EXEC_MODE=hang _install_fakes

    local sentinel="$TEST_TMP/exec-hang-fired"
    # Tight knobs for a fast test: 1s interval, 1s timeout, threshold 2 → ~2-3s to fire.
    export FAKE_PODMAN_EXEC_MODE=hang
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "2" "$sentinel"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    # Wait for watchdog to fire and exit on its own. Generous upper bound
    # (10s) for slow CI; with threshold=2, interval=1, timeout=1, expected
    # ~2-4s.
    local waited=0
    while kill -0 "$watchdog_pid" 2>/dev/null && (( waited < 10 )); do
        sleep 1
        waited=$((waited + 1))
    done
    wait "$watchdog_pid" 2>/dev/null || true

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json must be written by the watchdog"
    local content
    content=$(<"$status_file")
    assert_contains "$content" '"exit_code": 4' "status.json must carry exit_code=4"
    assert_contains "$content" '"error_type": "exec_channel_hang"' "status.json must carry error_type=exec_channel_hang"
    assert_contains "$content" "exec channel" "status message must mention exec channel for diagnostic clarity"
    assert_contains "$content" "host-side watchdog" "status message must identify the watchdog as the source"
    assert_file_exists "$sentinel" "host-only sentinel must be touched by the watchdog"

    assert_file_exists "$TEST_TMP/pkill.argv" "pkill must be invoked by the watchdog"
    local argv
    argv=$(<"$TEST_TMP/pkill.argv")
    assert_contains "$argv" "-TERM" "pkill must use -TERM (graceful)"
    assert_contains "$argv" "-f" "pkill must use -f to match full command line"
    assert_contains "$argv" "kapsis-${TEST_AGENT_ID}" "pkill pattern must contain the agent-scoped container name"
    assert_contains "$argv" "podman run" "pkill pattern must be anchored to 'podman run'"
    assert_not_contains "$argv" '\b' "pkill pattern must NOT use \\b (unsupported by macOS BSD pkill)"
    assert_contains "$argv" '[^a-zA-Z0-9_-]' "pkill pattern must use the portable character-class boundary"
    _teardown_test_env
}

#===============================================================================
# Counter-reset: a recovered probe must not accumulate toward threshold
#===============================================================================

test_watchdog_does_not_fire_on_transient_failure() {
    log_test "Single transient failure that recovers does NOT fire the watchdog"
    TEST_AGENT_ID="exec-transient-2"
    _setup_test_env
    _install_fakes
    # Tell fake podman: first call hangs, then succeeds on every subsequent call.
    : > "$TEST_TMP/podman-fail-once"
    export FAKE_PODMAN_EXEC_MODE=transient

    local sentinel="$TEST_TMP/exec-hang-fired"
    # threshold=3: a single failure should leave failures=1, then a success
    # resets to 0. After a few more cycles the watchdog must still be alive
    # with no sentinel.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "3" "$sentinel"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    # Give the watchdog ~6s — long enough for ~5 cycles (one fail, several
    # successes), well past where 3 consecutive failures would have fired.
    sleep 6

    # Watchdog must still be alive (no firing happened).
    if ! kill -0 "$watchdog_pid" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true
        log_test "FAIL: watchdog fired on transient failure (should have recovered)"
        _teardown_test_env
        return 1
    fi

    # Clean shutdown — kill watchdog and confirm no firing artifacts.
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    [[ ! -f "$sentinel" ]]
    assert_equals "0" "$?" "sentinel must NOT exist after transient-only failure"
    [[ ! -f "$TEST_TMP/pkill.argv" ]]
    assert_equals "0" "$?" "pkill must NOT have been invoked after transient-only failure"
    _teardown_test_env
}

#===============================================================================
# Cleanup: killing the watchdog before threshold leaves state untouched
#===============================================================================

test_watchdog_killed_early_does_not_fire() {
    log_test "Watchdog killed before threshold does NOT touch sentinel/status.json/pkill"
    TEST_AGENT_ID="exec-cleanup-3"
    _setup_test_env
    FAKE_PODMAN_EXEC_MODE=hang _install_fakes
    export FAKE_PODMAN_EXEC_MODE=hang

    local sentinel="$TEST_TMP/exec-hang-fired"
    # threshold=10 ensures we have time to kill before it fires.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "10" "$sentinel"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"

    sleep 1
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json from status_init must exist"
    local content
    content=$(<"$status_file")
    assert_not_contains "$content" '"exit_code": 4' "status.json must NOT carry exit_code=4 when watchdog was killed early"
    assert_not_contains "$content" '"error_type": "exec_channel_hang"' "status.json must NOT carry exec_channel_hang when watchdog was killed early"
    [[ ! -f "$sentinel" ]]
    assert_equals "0" "$?" "sentinel file must NOT exist when watchdog was killed early"
    [[ ! -f "$TEST_TMP/pkill.argv" ]]
    assert_equals "0" "$?" "pkill must NOT have been invoked when watchdog was killed early"
    _teardown_test_env
}

#===============================================================================
# Skip paths: invalid inputs do not crash and do not start a watchdog
#===============================================================================

test_watchdog_skipped_when_disabled() {
    log_test "Watchdog skipped when KAPSIS_EXEC_WATCHDOG_ENABLED=false"
    TEST_AGENT_ID="exec-skip-4"
    _setup_test_env
    _install_fakes
    KAPSIS_EXEC_WATCHDOG_ENABLED=false start_exec_channel_watchdog "$TEST_AGENT_ID"
    assert_equals "" "${_EXEC_CHANNEL_WATCHDOG_PID:-}" "no watchdog PID must be set when disabled"
    _teardown_test_env
}

test_watchdog_skipped_when_agent_id_invalid() {
    log_test "Watchdog skipped on malformed AGENT_ID"
    _setup_test_env
    _install_fakes
    start_exec_channel_watchdog 'agent;rm -rf /'
    assert_equals "" "${_EXEC_CHANNEL_WATCHDOG_PID:-}" "watchdog must refuse an AGENT_ID containing shell metacharacters"
    _teardown_test_env
}

test_watchdog_skipped_when_container_name_invalid() {
    log_test "Watchdog skipped on malformed container_name (defense in depth)"
    TEST_AGENT_ID="exec-skip-5"
    _setup_test_env
    _install_fakes
    start_exec_channel_watchdog "$TEST_AGENT_ID" 'ctr;evil'
    assert_equals "" "${_EXEC_CHANNEL_WATCHDOG_PID:-}" "watchdog must refuse a container name containing shell metacharacters"
    _teardown_test_env
}

test_watchdog_invalid_timing_uses_defaults() {
    log_test "Watchdog falls back to default timing on malformed interval/timeout/threshold"
    TEST_AGENT_ID="exec-skip-6"
    _setup_test_env
    _install_fakes
    # Force ok mode so the watchdog stays alive (we'll kill it immediately)
    export FAKE_PODMAN_EXEC_MODE=ok
    # Pass garbage for all three timing knobs.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "not-a-number" "also-garbage" "negative-1"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog should accept garbage and use defaults"; _teardown_test_env; return 1; }
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    _teardown_test_env
}

#===============================================================================
# Post-container exit-code override (mirrors launch-agent.sh override block)
#
# The override block at scripts/launch-agent.sh requires THREE conditions:
#   1. EXIT_CODE != 0
#   2. exec-hang sentinel exists on the HOST (NOT bind-mounted, forgery-proof)
#   3. _VFKIT_FIRED_SENTINEL is NOT present (vfkit override has priority)
#===============================================================================

_simulate_override() {
    local EXIT_CODE="$1"
    local status_file="$2"
    local exec_sentinel="${3:-}"
    local vfkit_sentinel="${4:-}"

    if [[ "$EXIT_CODE" -ne 0 ]] \
       && [[ -n "$exec_sentinel" && -f "$exec_sentinel" ]] \
       && [[ ! -f "${vfkit_sentinel:-/dev/null}" ]]; then
        # Status.json is defense-in-depth; sentinel is the trust anchor.
        EXIT_CODE=4
    fi
    echo "$EXIT_CODE"
}

test_override_upgrades_signal_exit_to_4() {
    log_test "Override upgrades signal exit (143) to 4 when exec-hang sentinel + status.json exec_channel_hang"
    TEST_AGENT_ID="exec-override-7"
    _setup_test_env
    status_set_error_type "exec_channel_hang"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/exec-hang-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 143 "$status_file" "$sentinel" "")
    assert_equals "4" "$result" "EXIT_CODE 143 must be upgraded to 4 when exec-hang sentinel + status.json"
    _teardown_test_env
}

test_override_preserves_exit_0() {
    log_test "Override preserves EXIT_CODE 0 (security: legitimate completion before exec channel wedged)"
    TEST_AGENT_ID="exec-override-8"
    _setup_test_env
    status_set_error_type "exec_channel_hang"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/exec-hang-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 0 "$status_file" "$sentinel" "")
    assert_equals "0" "$result" "EXIT_CODE 0 must NOT be silently upgraded to 4"
    _teardown_test_env
}

test_override_yields_to_vfkit_when_both_fired() {
    log_test "Override yields to vfkit when BOTH sentinels exist (vfkit has more specific diagnosis)"
    TEST_AGENT_ID="exec-override-9"
    _setup_test_env
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local exec_sentinel="$TEST_TMP/exec-hang-fired"
    local vfkit_sentinel="$TEST_TMP/vfkit-fired"
    : > "$exec_sentinel"
    : > "$vfkit_sentinel"
    # The exec override is the one being tested here — and it must NOT fire
    # when vfkit also fired (vfkit override would have already upgraded to 4
    # and set the more specific error_type=mount_failure).
    local result
    result=$(_simulate_override 1 "$status_file" "$exec_sentinel" "$vfkit_sentinel")
    assert_equals "1" "$result" "Exec override must yield to vfkit override when both sentinels fired"
    _teardown_test_env
}

test_override_does_not_fire_without_sentinel() {
    log_test "Override does NOT fire when status.json reports exec_channel_hang but no host sentinel (forgery resistance)"
    TEST_AGENT_ID="exec-override-10"
    _setup_test_env
    status_set_error_type "exec_channel_hang"
    status_complete 4 "FORGED by container"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    # Note: no sentinel file at $TEST_TMP/exec-hang-fired
    local sentinel="$TEST_TMP/exec-hang-fired-nonexistent"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel" "")
    assert_equals "1" "$result" "EXIT_CODE must NOT be upgraded to 4 from forged status.json without host sentinel"
    _teardown_test_env
}

test_override_does_not_fire_with_empty_sentinel_arg() {
    log_test "Override does NOT fire when sentinel arg is empty (watchdog disabled)"
    TEST_AGENT_ID="exec-override-11"
    _setup_test_env
    status_set_error_type "exec_channel_hang"
    status_complete 4 "test"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local result
    result=$(_simulate_override 1 "$status_file" "" "")
    assert_equals "1" "$result" "EXIT_CODE must remain 1 when watchdog never fired"
    _teardown_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "exec-channel Watchdog (Issue #382)"

    log_info "=== Watchdog core behavior ==="
    run_test test_watchdog_fires_after_threshold
    run_test test_watchdog_does_not_fire_on_transient_failure
    run_test test_watchdog_killed_early_does_not_fire

    log_info "=== Skip paths (input validation) ==="
    run_test test_watchdog_skipped_when_disabled
    run_test test_watchdog_skipped_when_agent_id_invalid
    run_test test_watchdog_skipped_when_container_name_invalid
    run_test test_watchdog_invalid_timing_uses_defaults

    log_info "=== Post-container exit-code override ==="
    run_test test_override_upgrades_signal_exit_to_4
    run_test test_override_preserves_exit_0
    run_test test_override_yields_to_vfkit_when_both_fired
    run_test test_override_does_not_fire_without_sentinel
    run_test test_override_does_not_fire_with_empty_sentinel_arg

    print_summary
}

main "$@"
