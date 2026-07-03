#!/usr/bin/env bash
#===============================================================================
# Tests for the host-side exec-channel watchdog (Issue #382, demoted to a
# non-lethal degraded-state reporter in Issue #414)
#
# The watchdog body lives in scripts/lib/exec-channel-watchdog.sh. These tests
# source the production library directly (no body duplication), force
# is_macos=true so the macOS-only path is exercised on Linux CI, and verify
# the post-#414 contract:
#
# - When `podman exec <ctr> true` hangs N consecutive times, the watchdog
#   enters DEGRADED: it creates the host-only degraded marker, logs a single
#   KAPSIS_EXEC_CHANNEL_DEGRADED line, and KEEPS PROBING. It never invokes
#   pkill, never writes exit_code=4 / error_type=exec_channel_hang to
#   status.json, and never marks the phase complete.
# - The marker's mtime is refreshed on every degraded tick (independent
#   host-side heartbeat).
# - Probe cadence backs off exponentially while degraded, capped by
#   KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP.
# - When a probe succeeds after degradation, the marker is removed, a
#   KAPSIS_EXEC_CHANNEL_RECOVERED line is logged, and the watchdog stays
#   alive at the base cadence.
# - A transient single failure that recovers before threshold never creates
#   the marker (counter reset semantics).
# - Killing the watchdog before threshold leaves the marker and status.json
#   untouched; when the parent shell goes away the watchdog exits silently
#   (orphan protection for --agent-id resume).
# - Invalid AGENT_ID / container_name / timing knobs (including the new
#   backoff cap) cause the watchdog to skip or fall back to defaults.
# - Static invariants: the library contains no kill path (pkill), no
#   terminal status write (status_complete), and no shared-VM restart
#   ("podman machine") in executable code — see incident #414.
# - launch-agent.sh's post-container branch is purely informational: a
#   present degraded marker NEVER modifies EXIT_CODE (the old override
#   falsely reclassified a successful exit-0 run as exit 4).
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
# all paths (including failure).
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

    # log_warn spy: the degraded/recovered contract is expressed as log
    # lines, so capture them to a file the assertions can grep. Defined
    # BEFORE sourcing the lib so its `declare -f` guard leaves it in place.
    # The watchdog subshell inherits this function (same-shell subshell).
    log_warn()  { printf '%s\n' "$*" >> "$TEST_TMP/warn.log"; }
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
    unset KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP FAKE_PODMAN_EXEC_MODE 2>/dev/null || true
    return 0
}

# Kill a watchdog subshell and drain it (best effort, never fails the test).
_kill_watchdog() {
    local pid="${1:-}"
    [[ -z "$pid" ]] && return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Helper: install a fake `podman`, `timeout`, and `pkill` on PATH.
#
# - `podman exec ... true` appends a `date +%s` line to $TEST_TMP/probe.log
#   on every probe (used by the backoff test), then reads
#   $FAKE_PODMAN_EXEC_MODE:
#     "hang"     — sleep 60 (will be killed by the fake `timeout`)
#     "ok"       — exit 0
#     "transient"— a file at $TEST_TMP/podman-fail-once toggles: present
#                  means this call fails once and removes the file, so the
#                  next call succeeds. Used to verify counter reset.
#     "flagfile" — hang while $TEST_TMP/podman-hang-flag exists, succeed
#                  once it is removed. Used to drive a degraded→recovered
#                  transition at runtime.
# - `timeout` is a real "kill after N seconds" stub (cheap, no GNU coreutils
#   dependency on macOS CI).
# - `pkill` records argv — the post-#414 contract is that it is NEVER
#   invoked by this watchdog.
#-------------------------------------------------------------------------------
_install_fakes() {
    local fake_bin="$TEST_TMP/bin"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/podman" <<EOF
#!/usr/bin/env bash
# Only intercept "exec <ctr> true" — anything else is unexpected in tests.
if [[ "\$1" == "exec" && "\$3" == "true" ]]; then
    date +%s >> "$TEST_TMP/probe.log"
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
        flagfile)
            if [[ -f "$TEST_TMP/podman-hang-flag" ]]; then
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

# Wait (up to $2 seconds) for a file to exist. Returns 0 when it appears.
_wait_for_file() {
    local path="$1" limit="${2:-15}" waited=0
    while [[ ! -f "$path" ]] && (( waited < limit )); do
        sleep 1
        waited=$((waited + 1))
    done
    [[ -f "$path" ]]
}

# Wait (up to $2 seconds) for a file to be gone. Returns 0 when removed.
_wait_for_gone() {
    local path="$1" limit="${2:-15}" waited=0
    while [[ -f "$path" ]] && (( waited < limit )); do
        sleep 1
        waited=$((waited + 1))
    done
    [[ ! -f "$path" ]]
}

#===============================================================================
# Core: threshold breached → DEGRADED (marker + single log line), NOT terminal
#===============================================================================

test_watchdog_degrades_after_threshold() {
    log_test "Threshold breached → degraded marker + single DEGRADED log line; no pkill, no terminal status, watchdog stays alive"
    TEST_AGENT_ID="exec-degrade-1"
    _setup_test_env
    _install_fakes
    export FAKE_PODMAN_EXEC_MODE=hang
    # Keep degraded ticks fast so the "logged exactly once" check sees
    # several degraded ticks within the window.
    export KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP=2

    local marker="$TEST_TMP/exec-degraded"
    # Tight knobs: 1s interval, 1s timeout, threshold 2 → degraded in ~3-4s.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "2" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    if ! _wait_for_file "$marker" 15; then
        _kill_watchdog "$watchdog_pid"
        log_test "FAIL: degraded marker never appeared"
        _teardown_test_env
        return 1
    fi

    # Let a few more degraded ticks elapse — DEGRADED must be logged exactly
    # once per episode regardless of how many ticks follow.
    sleep 6

    # Watchdog must STILL be alive (post-#414 it never exits on threshold).
    if ! kill -0 "$watchdog_pid" 2>/dev/null; then
        log_test "FAIL: watchdog exited after threshold (must keep probing forever)"
        _teardown_test_env
        return 1
    fi

    local degraded_count
    degraded_count=$(grep -c "KAPSIS_EXEC_CHANNEL_DEGRADED" "$TEST_TMP/warn.log" 2>/dev/null) || degraded_count=0
    assert_equals "1" "$degraded_count" "KAPSIS_EXEC_CHANNEL_DEGRADED must be logged exactly once per episode"

    assert_file_not_exists "$TEST_TMP/pkill.argv" "pkill must NEVER be invoked by the demoted watchdog"

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json from status_init must exist"
    local content
    content=$(<"$status_file")
    assert_not_contains "$content" '"exit_code": 4' "status.json must NOT carry exit_code=4 (watchdog is non-terminal)"
    assert_not_contains "$content" '"error_type": "exec_channel_hang"' "status.json must NOT carry exec_channel_hang (legacy, no longer emitted)"
    assert_not_contains "$content" '"phase": "complete"' "status.json phase must NOT be complete (agent still running)"

    _kill_watchdog "$watchdog_pid"
    _teardown_test_env
}

#===============================================================================
# Heartbeat: marker mtime strictly advances across subsequent degraded ticks
#===============================================================================

test_degraded_marker_mtime_advances() {
    log_test "Degraded marker mtime advances on each subsequent degraded tick (independent heartbeat)"
    TEST_AGENT_ID="exec-heartbeat-2"
    _setup_test_env
    _install_fakes
    export FAKE_PODMAN_EXEC_MODE=hang
    export KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP=2

    local marker="$TEST_TMP/exec-degraded"
    # threshold=1 → degraded on the first failed probe (fast entry).
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "1" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    if ! _wait_for_file "$marker" 15; then
        _kill_watchdog "$watchdog_pid"
        log_test "FAIL: degraded marker never appeared"
        _teardown_test_env
        return 1
    fi

    local mtime1 mtime2 waited=0
    mtime1=$(get_file_mtime "$marker")
    # Poll for the mtime to advance — with interval=1, timeout=1, cap=2 the
    # next degraded tick lands within ~2-3s; give slow CI up to 15s.
    mtime2="$mtime1"
    while [[ "$mtime2" == "$mtime1" ]] && (( waited < 15 )); do
        sleep 1
        waited=$((waited + 1))
        mtime2=$(get_file_mtime "$marker")
    done

    _kill_watchdog "$watchdog_pid"

    if (( mtime2 > mtime1 )); then
        assert_equals "advanced" "advanced" "marker mtime must strictly advance across degraded ticks"
    else
        log_test "FAIL: marker mtime did not advance (mtime1=$mtime1 mtime2=$mtime2)"
        _teardown_test_env
        return 1
    fi
    _teardown_test_env
}

#===============================================================================
# Recovery: probe succeeds after degradation → marker removed, RECOVERED
# logged, watchdog still alive
#===============================================================================

test_watchdog_recovers_after_degradation() {
    log_test "Probe recovery after degradation → marker removed, RECOVERED logged, watchdog still alive"
    TEST_AGENT_ID="exec-recover-3"
    _setup_test_env
    _install_fakes
    export FAKE_PODMAN_EXEC_MODE=flagfile
    export KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP=2
    : > "$TEST_TMP/podman-hang-flag"

    local marker="$TEST_TMP/exec-degraded"
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "2" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    if ! _wait_for_file "$marker" 15; then
        _kill_watchdog "$watchdog_pid"
        log_test "FAIL: degraded marker never appeared"
        _teardown_test_env
        return 1
    fi

    # Heal the channel: next probe succeeds.
    rm -f "$TEST_TMP/podman-hang-flag"

    if ! _wait_for_gone "$marker" 15; then
        _kill_watchdog "$watchdog_pid"
        log_test "FAIL: degraded marker was not removed after probe recovery"
        _teardown_test_env
        return 1
    fi

    local warn_content=""
    [[ -f "$TEST_TMP/warn.log" ]] && warn_content=$(<"$TEST_TMP/warn.log")
    assert_contains "$warn_content" "KAPSIS_EXEC_CHANNEL_RECOVERED" "RECOVERED must be logged on probe success after degradation"
    assert_contains "$warn_content" "s degraded" "RECOVERED line must report the degraded duration"

    # Watchdog must still be alive, back at the base cadence.
    if ! kill -0 "$watchdog_pid" 2>/dev/null; then
        log_test "FAIL: watchdog exited after recovery (must keep probing)"
        _teardown_test_env
        return 1
    fi
    assert_file_not_exists "$TEST_TMP/pkill.argv" "pkill must NEVER be invoked, including across a degraded episode"

    _kill_watchdog "$watchdog_pid"
    _teardown_test_env
}

#===============================================================================
# Backoff: degraded probe cadence slows down, capped by
# KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP
#===============================================================================

test_degraded_probe_backoff() {
    log_test "Degraded probe cadence backs off exponentially up to KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP"
    TEST_AGENT_ID="exec-backoff-4"
    _setup_test_env
    _install_fakes
    export FAKE_PODMAN_EXEC_MODE=hang
    export KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP=4

    local marker="$TEST_TMP/exec-degraded"
    # threshold=1 → degraded immediately; expected probe schedule (1s probe
    # timeout + sleep): gaps of ~2s, 3s, 5s, 5s... as interval goes 1→2→4→4.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "1" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    # Wait until at least 5 probes have been recorded (capped interval
    # reached by probe 4). Generous 40s bound for slow CI.
    local waited=0 probes=0
    while (( waited < 40 )); do
        probes=$(wc -l < "$TEST_TMP/probe.log" 2>/dev/null || echo 0)
        (( probes >= 5 )) && break
        sleep 1
        waited=$((waited + 1))
    done
    _kill_watchdog "$watchdog_pid"

    if (( probes < 5 )); then
        log_test "FAIL: only $probes probes recorded within window (backoff test needs 5)"
        _teardown_test_env
        return 1
    fi

    # The gap between the last two probes must reflect the capped interval:
    # >= cap - 1 (allow 1s of scheduling slop; without backoff it would be ~2s,
    # with cap=4 it is ~5s).
    local last prev gap
    last=$(tail -n 1 "$TEST_TMP/probe.log")
    prev=$(tail -n 2 "$TEST_TMP/probe.log" | head -n 1)
    gap=$((last - prev))
    if (( gap >= 3 )); then
        assert_equals "backed-off" "backed-off" "degraded probe gap ($gap s) must reflect the capped backoff interval"
    else
        log_test "FAIL: probe gap while degraded was ${gap}s — backoff did not engage (expected >= 3s with cap=4)"
        _teardown_test_env
        return 1
    fi
    _teardown_test_env
}

#===============================================================================
# Counter-reset: a recovered probe below threshold must not accumulate
#===============================================================================

test_watchdog_does_not_degrade_on_transient_failure() {
    log_test "Single transient failure that recovers does NOT enter degraded state"
    TEST_AGENT_ID="exec-transient-5"
    _setup_test_env
    _install_fakes
    # Tell fake podman: first call hangs, then succeeds on every subsequent call.
    : > "$TEST_TMP/podman-fail-once"
    export FAKE_PODMAN_EXEC_MODE=transient

    local marker="$TEST_TMP/exec-degraded"
    # threshold=3: a single failure should leave failures=1, then a success
    # resets to 0. After a few more cycles the watchdog must still be alive
    # with no marker.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "3" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog did not start"; _teardown_test_env; return 1; }

    # Give the watchdog ~6s — long enough for ~5 cycles (one fail, several
    # successes), well past where 3 consecutive failures would have degraded.
    sleep 6

    # Watchdog must still be alive.
    if ! kill -0 "$watchdog_pid" 2>/dev/null; then
        log_test "FAIL: watchdog exited on transient failure (should have kept probing)"
        _teardown_test_env
        return 1
    fi
    _kill_watchdog "$watchdog_pid"

    assert_file_not_exists "$marker" "degraded marker must NOT exist after transient-only failure"
    local degraded_count
    degraded_count=$(grep -c "KAPSIS_EXEC_CHANNEL_DEGRADED" "$TEST_TMP/warn.log" 2>/dev/null) || degraded_count=0
    assert_equals "0" "$degraded_count" "DEGRADED must NOT be logged for a below-threshold transient failure"
    assert_file_not_exists "$TEST_TMP/pkill.argv" "pkill must NOT have been invoked after transient-only failure"
    _teardown_test_env
}

#===============================================================================
# Cleanup: killing the watchdog before threshold leaves state untouched
#===============================================================================

test_watchdog_killed_early_leaves_no_artifacts() {
    log_test "Watchdog killed before threshold does NOT touch marker/status.json/pkill"
    TEST_AGENT_ID="exec-cleanup-6"
    _setup_test_env
    _install_fakes
    export FAKE_PODMAN_EXEC_MODE=hang

    local marker="$TEST_TMP/exec-degraded"
    # threshold=10 ensures we have time to kill before it degrades.
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "1" "1" "10" "$marker"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"

    sleep 1
    _kill_watchdog "$watchdog_pid"

    local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-$TEST_AGENT_ID.json"
    assert_file_exists "$status_file" "status.json from status_init must exist"
    local content
    content=$(<"$status_file")
    assert_not_contains "$content" '"exit_code": 4' "status.json must NOT carry exit_code=4 when watchdog was killed early"
    assert_not_contains "$content" '"error_type": "exec_channel_hang"' "status.json must NOT carry exec_channel_hang when watchdog was killed early"
    assert_file_not_exists "$marker" "degraded marker must NOT exist when watchdog was killed early"
    assert_file_not_exists "$TEST_TMP/pkill.argv" "pkill must NOT have been invoked when watchdog was killed early"
    _teardown_test_env
}

#===============================================================================
# Orphan protection: when the parent shell ($$) is gone, the watchdog must
# exit silently without reporting — otherwise a stale watchdog could mark a
# future agent (same AGENT_ID via --agent-id resume) as degraded.
#===============================================================================

test_watchdog_exits_silently_when_parent_dies() {
    log_test "Watchdog exits without creating the marker when parent shell PID is reaped (orphan protection)"
    TEST_AGENT_ID="exec-orphan-X"
    _setup_test_env
    _install_fakes
    # Hang mode: every probe would normally accumulate failures. The orphan
    # check must take precedence so the watchdog never reaches threshold.
    export FAKE_PODMAN_EXEC_MODE=hang

    local marker="$TEST_TMP/exec-degraded"
    local pid_file="$TEST_TMP/orphan-watchdog-pid"

    # Spawn a child bash so the watchdog's parent_pid=$$ captures that child's
    # PID, NOT this test script's PID. When the child bash exits and is
    # reaped (implicitly by waiting on the foreground command), its PID is
    # gone from the process table — the watchdog's next
    # `kill -0 $parent_pid` check will fail and the watchdog must exit
    # without reporting. Values are passed via env to avoid nested-quote
    # gymnastics in the inline script.
    PATH="$PATH" TEST_TMP="$TEST_TMP" \
        KAPSIS_STATUS_DIR="$KAPSIS_STATUS_DIR" \
        EXEC_ORPHAN_AGENT_ID="$TEST_AGENT_ID" \
        EXEC_ORPHAN_MARKER="$marker" \
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
            start_exec_channel_watchdog "$EXEC_ORPHAN_AGENT_ID" "" "1" "1" "10" "$EXEC_ORPHAN_MARKER"
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

    assert_file_not_exists "$marker" "degraded marker must NOT exist — orphan watchdog must exit without reporting"
    assert_file_not_exists "$TEST_TMP/pkill.argv" "pkill must NOT have been invoked — orphan watchdog must exit without reporting"
    _teardown_test_env
}

#===============================================================================
# Skip paths: invalid inputs do not crash and do not start a watchdog
#===============================================================================

test_watchdog_skipped_when_disabled() {
    log_test "Watchdog skipped when KAPSIS_EXEC_WATCHDOG_ENABLED=false (kill switch retained)"
    TEST_AGENT_ID="exec-skip-7"
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
    TEST_AGENT_ID="exec-skip-8"
    _setup_test_env
    _install_fakes
    start_exec_channel_watchdog "$TEST_AGENT_ID" 'ctr;evil'
    assert_equals "" "${_EXEC_CHANNEL_WATCHDOG_PID:-}" "watchdog must refuse a container name containing shell metacharacters"
    _teardown_test_env
}

test_watchdog_invalid_timing_uses_defaults() {
    log_test "Watchdog falls back to default timing on malformed interval/timeout/threshold/backoff-cap"
    TEST_AGENT_ID="exec-skip-9"
    _setup_test_env
    _install_fakes
    # Force ok mode so the watchdog stays alive (we'll kill it immediately)
    export FAKE_PODMAN_EXEC_MODE=ok
    # Pass garbage for all timing knobs, including the new backoff cap.
    export KAPSIS_EXEC_WATCHDOG_BACKOFF_CAP="not-a-cap"
    start_exec_channel_watchdog "$TEST_AGENT_ID" "" "not-a-number" "also-garbage" "negative-1"
    local watchdog_pid="$_EXEC_CHANNEL_WATCHDOG_PID"
    [[ -n "$watchdog_pid" ]] || { log_test "FAIL: watchdog should accept garbage and use defaults"; _teardown_test_env; return 1; }
    _kill_watchdog "$watchdog_pid"
    _teardown_test_env
}

#===============================================================================
# Static invariants (incident #414): the library must contain no kill path,
# no terminal status write, and no shared-VM restart in executable code.
# Comments are stripped first — the header deliberately documents WHY these
# are forbidden, which mentions the forbidden strings.
#===============================================================================

test_lib_static_invariants_no_lethal_code() {
    log_test "Static invariant: lib has no pkill, no status_complete, no 'podman machine' in executable code"
    local lib="$KAPSIS_ROOT/scripts/lib/exec-channel-watchdog.sh"
    local code
    # Strip full-line comments and trailing comments before scanning.
    code=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^!].*$//' "$lib")

    assert_not_contains "$code" "pkill" "lib must not invoke pkill (the kill path was removed in #414 — it was ineffective during a wedge)"
    assert_not_contains "$code" "status_complete" "lib must not call status_complete (terminal status writes caused the #414 false failure)"
    assert_not_contains "$code" "status_set_error_type" "lib must not call status_set_error_type (no terminal error classification from this lib)"
    assert_not_contains "$code" "podman machine" "lib must never invoke 'podman machine' (restarting the shared VM destroys concurrent bystander agents)"
}

#===============================================================================
# Post-container informational branch (mirrors launch-agent.sh)
#
# Since #414 the production branch is purely informational:
#   if [[ -n "$_EXEC_DEGRADED_MARKER" && -f "$_EXEC_DEGRADED_MARKER" ]]; then
#       log_warn "... exit code $EXIT_CODE preserved ..."
#   fi
# It NEVER modifies EXIT_CODE. This helper reproduces that logic faithfully
# so tests catch drift between the simulator and production. It echoes the
# (unchanged) EXIT_CODE and writes "logged"/"silent" to
# $TEST_TMP/last-informational so callers using $(...) can read whether the
# informational line fired across the subshell boundary.
#===============================================================================

_simulate_informational_branch() {
    local EXIT_CODE="$1"
    local degraded_marker="${2:-}"
    local outcome="silent"

    if [[ -n "$degraded_marker" && -f "$degraded_marker" ]]; then
        # Production logs here; EXIT_CODE is deliberately untouched.
        outcome="logged"
    fi
    [[ -n "${TEST_TMP:-}" ]] && printf '%s' "$outcome" > "$TEST_TMP/last-informational"
    echo "$EXIT_CODE"
}

_last_informational() {
    [[ -f "$TEST_TMP/last-informational" ]] && cat "$TEST_TMP/last-informational" || echo "(unset)"
}

test_informational_branch_preserves_nonzero_exit() {
    log_test "Informational branch: degraded marker present + EXIT_CODE=1 stays 1 (never upgraded)"
    TEST_AGENT_ID="exec-info-10"
    _setup_test_env
    local marker="$TEST_TMP/exec-degraded"
    : > "$marker"
    local result
    result=$(_simulate_informational_branch 1 "$marker")
    assert_equals "1" "$result" "EXIT_CODE 1 must be preserved — the #414 override that upgraded to 4 is gone"
    assert_equals "logged" "$(_last_informational)" "informational line must fire when the marker is present"
    _teardown_test_env
}

test_informational_branch_preserves_exit_0() {
    log_test "Informational branch: degraded marker present + EXIT_CODE=0 stays 0 (incident #414 scenario)"
    TEST_AGENT_ID="exec-info-11"
    _setup_test_env
    local marker="$TEST_TMP/exec-degraded"
    : > "$marker"
    local result
    result=$(_simulate_informational_branch 0 "$marker")
    assert_equals "0" "$result" "EXIT_CODE 0 must be preserved (56 committed changes + exit 0 must never be reclassified)"
    assert_equals "logged" "$(_last_informational)" "informational line must still fire for exit 0 (diagnostic value)"
    _teardown_test_env
}

test_informational_branch_silent_without_marker() {
    log_test "Informational branch: no marker → no log line, EXIT_CODE untouched"
    TEST_AGENT_ID="exec-info-12"
    _setup_test_env
    local result
    result=$(_simulate_informational_branch 1 "$TEST_TMP/nonexistent-marker")
    assert_equals "1" "$result" "EXIT_CODE must remain 1 when the channel was never degraded"
    assert_equals "silent" "$(_last_informational)" "no informational line without the marker"
    _teardown_test_env
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "exec-channel Watchdog (Issues #382 / #414)"

    log_info "=== Degraded-state reporter core behavior ==="
    run_test test_watchdog_degrades_after_threshold
    run_test test_degraded_marker_mtime_advances
    run_test test_watchdog_recovers_after_degradation
    run_test test_degraded_probe_backoff
    run_test test_watchdog_does_not_degrade_on_transient_failure
    run_test test_watchdog_killed_early_leaves_no_artifacts

    log_info "=== Orphan protection ==="
    run_test test_watchdog_exits_silently_when_parent_dies

    log_info "=== Skip paths (input validation) ==="
    run_test test_watchdog_skipped_when_disabled
    run_test test_watchdog_skipped_when_agent_id_invalid
    run_test test_watchdog_skipped_when_container_name_invalid
    run_test test_watchdog_invalid_timing_uses_defaults

    log_info "=== Static invariants (#414) ==="
    run_test test_lib_static_invariants_no_lethal_code

    log_info "=== Post-container informational branch ==="
    run_test test_informational_branch_preserves_nonzero_exit
    run_test test_informational_branch_preserves_exit_0
    run_test test_informational_branch_silent_without_marker

    print_summary
}

main "$@"
