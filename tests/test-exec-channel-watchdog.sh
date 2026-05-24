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
# Orphan protection: when the parent shell ($$) is gone, the watchdog must
# exit silently without firing — otherwise a stale watchdog could SIGTERM
# a future agent that reuses the same AGENT_ID via --agent-id resume.
#===============================================================================

test_watchdog_exits_silently_when_parent_dies() {
    log_test "Watchdog exits without firing when parent shell PID is reaped (orphan protection)"
    TEST_AGENT_ID="exec-orphan-X"
    _setup_test_env
    _install_fakes
    # Hang mode: every probe would normally accumulate failures. The orphan
    # check must take precedence so the watchdog never reaches threshold.
    export FAKE_PODMAN_EXEC_MODE=hang

    local sentinel="$TEST_TMP/exec-hang-fired"
    local pid_file="$TEST_TMP/orphan-watchdog-pid"

    # Spawn a child bash so the watchdog's parent_pid=$$ captures that child's
    # PID, NOT this test script's PID. When the child bash exits and is
    # reaped (implicitly by waiting on the foreground command), its PID is
    # gone from the process table — the watchdog's next
    # `kill -0 $parent_pid` check will fail and the watchdog must exit
    # without firing. Values are passed via env to avoid nested-quote
    # gymnastics in the inline script.
    PATH="$PATH" TEST_TMP="$TEST_TMP" \
        KAPSIS_STATUS_DIR="$KAPSIS_STATUS_DIR" \
        EXEC_ORPHAN_AGENT_ID="$TEST_AGENT_ID" \
        EXEC_ORPHAN_SENTINEL="$sentinel" \
        EXEC_ORPHAN_PID_FILE="$pid_file" \
        LIB_DIR="$LIB_DIR" \
        bash -c '
            unset _KAPSIS_STATUS_LOADED _KAPSIS_EXEC_CHANNEL_WATCHDOG_LOADED
            # shellcheck source=/dev/null
            source "$LIB_DIR/status.sh"
            log_warn()  { :; }
            log_debug() { :; }
            log_info()  { :; }
            is_macos()  { return 0; }
            # shellcheck source=/dev/null
            source "$LIB_DIR/exec-channel-watchdog.sh"
            status_init "test-project" "$EXEC_ORPHAN_AGENT_ID" "test-branch" "worktree" "$TEST_TMP/wt" >/dev/null
            # Tight knobs: interval=1, timeout=1, threshold=10 — large enough
            # that threshold would never be reached within our wait window
            # if the orphan check failed; small enough that the watchdog
            # checks the parent on every tick.
            start_exec_channel_watchdog "$EXEC_ORPHAN_AGENT_ID" "" "1" "1" "10" "$EXEC_ORPHAN_SENTINEL"
            printf "%s" "$_EXEC_CHANNEL_WATCHDOG_PID" > "$EXEC_ORPHAN_PID_FILE"
            exit 0
        '

    local watchdog_pid=""
    [[ -f "$pid_file" ]] && watchdog_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -z "$watchdog_pid" ]]; then
        log_test "FAIL: orphan watchdog never reported its PID"
        _teardown_test_env
        return 1
    fi

    # Wait up to 8s for the orphaned watchdog to detect the parent's death
    # and exit. With interval=1 and the orphan check happening at the top
    # of every loop iteration, this should complete within 1-2 ticks.
    local waited=0
    while kill -0 "$watchdog_pid" 2>/dev/null && (( waited < 8 )); do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$watchdog_pid" 2>/dev/null; then
        # Best-effort cleanup so the test framework doesn't leak processes.
        kill "$watchdog_pid" 2>/dev/null || true
        log_test "FAIL: watchdog did not exit after parent died (orphan protection broken)"
        _teardown_test_env
        return 1
    fi

    [[ ! -f "$sentinel" ]]
    assert_equals "0" "$?" "sentinel must NOT exist — orphan watchdog must exit without firing"
    [[ ! -f "$TEST_TMP/pkill.argv" ]]
    assert_equals "0" "$?" "pkill must NOT have been invoked — orphan watchdog must exit without firing"
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
# The production override block at scripts/launch-agent.sh requires:
#   1. EXIT_CODE != 0
#   2. exec-hang sentinel exists on the HOST (NOT bind-mounted, forgery-proof)
#   3. _KAPSIS_VFKIT_HANG_DETECTED boolean is not "true" (vfkit takes priority)
# Then it reads status.json and branches:
#   confirmed path: status.json has exit_code=4 + error_type=exec_channel_hang
#   fallback path:  sentinel present but status.json mismatch (status_complete
#                   failed inside the watchdog subshell, e.g. disk full)
# Both branches upgrade EXIT_CODE to 4 and set _KAPSIS_EXEC_HANG_DETECTED=true
# — the sentinel is the host-trusted authority; status.json is defense in
# depth, used only to distinguish the log message.
#
# This helper reproduces that logic faithfully so tests catch drift between
# the simulator and the production override. The branch label is written to
# $TEST_TMP/last-override-branch so tests called via $(_simulate_override ...)
# can read it back across the subshell boundary (the var alone wouldn't
# survive a command-substitution subshell).
#===============================================================================

_simulate_override() {
    local EXIT_CODE="$1"
    local status_file="$2"
    local exec_sentinel="${3:-}"
    # 4th arg is the boolean _KAPSIS_VFKIT_HANG_DETECTED state. Pass "true" to
    # simulate vfkit having fired; anything else (default "false") simulates
    # vfkit did not fire.
    local vfkit_hang_detected="${4:-false}"
    local branch="no-fire"

    if [[ "$EXIT_CODE" -ne 0 ]] \
       && [[ -n "$exec_sentinel" && -f "$exec_sentinel" ]] \
       && [[ "$vfkit_hang_detected" != "true" ]]; then
        # Read status.json defensively — both branches upgrade EXIT_CODE, but
        # the branch label differentiates confirmed-by-status-json from the
        # sentinel-only fallback. This mirrors the production override.
        local status_exit_exec status_err_exec
        status_exit_exec=""
        status_err_exec=""
        if [[ -f "$status_file" ]]; then
            local content
            content=$(<"$status_file")
            if [[ "$content" =~ \"exit_code\":\ *([0-9]+) ]]; then
                status_exit_exec="${BASH_REMATCH[1]}"
            fi
            if grep -Eq '"error_type":[[:space:]]*"exec_channel_hang"' "$status_file" 2>/dev/null; then
                status_err_exec="exec_channel_hang"
            fi
        fi
        if [[ "$status_exit_exec" == "4" && "$status_err_exec" == "exec_channel_hang" ]]; then
            branch="confirmed"
        else
            branch="fallback"
        fi
        EXIT_CODE=4
    fi
    # Persist branch label so callers using $(...) can read it back.
    [[ -n "${TEST_TMP:-}" ]] && printf '%s' "$branch" > "$TEST_TMP/last-override-branch"
    echo "$EXIT_CODE"
}

# Read the branch label set by the most recent _simulate_override call.
_last_override_branch() {
    [[ -f "$TEST_TMP/last-override-branch" ]] && cat "$TEST_TMP/last-override-branch" || echo "(unset)"
}

test_override_upgrades_signal_exit_to_4() {
    log_test "Override upgrades signal exit (143) to 4 via 'confirmed' branch when sentinel + status.json exec_channel_hang"
    TEST_AGENT_ID="exec-override-7"
    _setup_test_env
    status_set_error_type "exec_channel_hang"
    status_complete 4 "test fixture"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/exec-hang-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 143 "$status_file" "$sentinel" "false")
    assert_equals "4" "$result" "EXIT_CODE 143 must be upgraded to 4 when exec-hang sentinel + status.json"
    assert_equals "confirmed" "$(_last_override_branch)" "Branch must be 'confirmed' when status.json carries exec_channel_hang"
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
    result=$(_simulate_override 0 "$status_file" "$sentinel" "false")
    assert_equals "0" "$result" "EXIT_CODE 0 must NOT be silently upgraded to 4"
    assert_equals "no-fire" "$(_last_override_branch)" "Branch must be 'no-fire' for exit 0"
    _teardown_test_env
}

test_override_yields_to_vfkit_when_vfkit_hang_detected() {
    log_test "Override yields to vfkit when _KAPSIS_VFKIT_HANG_DETECTED is true (vfkit has more specific diagnosis)"
    TEST_AGENT_ID="exec-override-9"
    _setup_test_env
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local exec_sentinel="$TEST_TMP/exec-hang-fired"
    : > "$exec_sentinel"
    # Exec sentinel exists, but vfkit override already ran and set the
    # _KAPSIS_VFKIT_HANG_DETECTED boolean. The yield guards on the boolean
    # (not on the vfkit sentinel file) so the cleanup trap deleting the
    # sentinel before this block runs cannot cause an incorrect override.
    local result
    result=$(_simulate_override 1 "$status_file" "$exec_sentinel" "true")
    assert_equals "1" "$result" "Exec override must yield when _KAPSIS_VFKIT_HANG_DETECTED=true"
    assert_equals "no-fire" "$(_last_override_branch)" "Branch must be 'no-fire' when yielding to vfkit"
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
    result=$(_simulate_override 1 "$status_file" "$sentinel" "false")
    assert_equals "1" "$result" "EXIT_CODE must NOT be upgraded to 4 from forged status.json without host sentinel"
    assert_equals "no-fire" "$(_last_override_branch)" "Branch must be 'no-fire' when sentinel is missing"
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
    result=$(_simulate_override 1 "$status_file" "" "false")
    assert_equals "1" "$result" "EXIT_CODE must remain 1 when watchdog never fired"
    assert_equals "no-fire" "$(_last_override_branch)" "Branch must be 'no-fire' when watchdog disabled"
    _teardown_test_env
}

#-------------------------------------------------------------------------------
# Sentinel-only fallback: sentinel is present but status.json was never written
# with exec_channel_hang (e.g. disk full inside the watchdog subshell, or the
# subshell was SIGTERMed mid-write between status_set_error_type and
# status_complete). Override must still upgrade EXIT_CODE because the sentinel
# is host-trusted. Mirrors test-vfkit-watchdog.sh::test_post_container_override_fires_with_sentinel_only.
#-------------------------------------------------------------------------------
test_override_fires_with_sentinel_only_when_status_missing() {
    log_test "Override fires (fallback branch) when sentinel exists but status.json was never written (status_complete failure path)"
    TEST_AGENT_ID="exec-override-12"
    _setup_test_env
    # Don't write any status — simulate status_complete having failed inside
    # the watchdog subshell (e.g. disk full or SIGTERM mid-write).
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    rm -f "$status_file"
    local sentinel="$TEST_TMP/exec-hang-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel" "false")
    assert_equals "4" "$result" "EXIT_CODE must upgrade to 4 on sentinel alone (host-trusted, status_complete may have failed)"
    assert_equals "fallback" "$(_last_override_branch)" "Branch must be 'fallback' when status.json is missing"
    _teardown_test_env
}

#-------------------------------------------------------------------------------
# Sentinel-only fallback variant: sentinel exists AND status.json exists, but
# status.json carries the wrong error_type (e.g. mount_failure leaked in from
# an earlier vfkit fire that was then cleared, or the watchdog subshell wrote
# the file but never reached the error_type update). The host sentinel still
# wins. Exercises the production grep that the previous simpler stub omitted.
#-------------------------------------------------------------------------------
test_override_fires_with_sentinel_when_status_mismatch() {
    log_test "Override fires (fallback branch) when sentinel exists but status.json carries a mismatched error_type"
    TEST_AGENT_ID="exec-override-13"
    _setup_test_env
    # Write a DIFFERENT error_type into status.json so the grep for
    # exec_channel_hang misses. This exercises the production grep that the
    # previous simpler simulator omitted entirely.
    status_set_error_type "mount_failure"
    status_complete 4 "spurious vfkit-like leak"
    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    local sentinel="$TEST_TMP/exec-hang-fired"
    : > "$sentinel"
    local result
    result=$(_simulate_override 1 "$status_file" "$sentinel" "false")
    assert_equals "4" "$result" "EXIT_CODE must upgrade to 4 (sentinel trusted) even with status.json error_type mismatch"
    assert_equals "fallback" "$(_last_override_branch)" "Branch must be 'fallback' when status.json error_type does not match"
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

    log_info "=== Orphan protection ==="
    run_test test_watchdog_exits_silently_when_parent_dies

    log_info "=== Skip paths (input validation) ==="
    run_test test_watchdog_skipped_when_disabled
    run_test test_watchdog_skipped_when_agent_id_invalid
    run_test test_watchdog_skipped_when_container_name_invalid
    run_test test_watchdog_invalid_timing_uses_defaults

    log_info "=== Post-container exit-code override ==="
    run_test test_override_upgrades_signal_exit_to_4
    run_test test_override_preserves_exit_0
    run_test test_override_yields_to_vfkit_when_vfkit_hang_detected
    run_test test_override_does_not_fire_without_sentinel
    run_test test_override_does_not_fire_with_empty_sentinel_arg
    run_test test_override_fires_with_sentinel_only_when_status_missing
    run_test test_override_fires_with_sentinel_when_status_mismatch

    print_summary
}

main "$@"
