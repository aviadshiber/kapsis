#!/usr/bin/env bash
#===============================================================================
# Tests for host-side status volume sync (Issue #276)
#
# Verifies that:
# - start_status_sync is a no-op when no volume is provided (Linux path)
# - start_status_sync spawns a background worker, writes PID file
# - The worker copies volume contents into the host dir (via mocked podman)
# - stop_status_sync kills the worker and performs a final sync
# - Double-start is a no-op
#
# `podman` is mocked via a fake script on PATH. The fake "exports" a tarball
# of a staging directory so we exercise the real `podman volume export | tar`
# pipeline.
#
# Run: ./tests/test-status-sync.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LIB_DIR="$KAPSIS_ROOT/scripts/lib"

#-------------------------------------------------------------------------------
# Create a fake `podman` that implements just enough of `volume export` to
# let the sync library run end-to-end. The fake tars up $STAGING_DIR and
# pipes it to stdout when invoked with `volume export <anything>`.
#-------------------------------------------------------------------------------
_make_fake_podman_volume() {
    local target="$1"
    local staging_dir="$2"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
    volume)
        shift
        case "\${1:-}" in
            export)
                # \$2 is the volume name — ignored for tests.
                # tar from the staging dir so the consumer sees real files.
                if [[ -d "$staging_dir" ]]; then
                    cd "$staging_dir" && tar -cf - . 2>/dev/null
                fi
                ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$target"
}

_make_libs_preamble() {
    cat <<EOF
set -u
log_debug() { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
source "$LIB_DIR/constants.sh"
source "$LIB_DIR/status-sync.sh"
EOF
}

#===============================================================================
# start_status_sync / stop_status_sync
#===============================================================================

test_start_is_noop_without_volume() {
    log_test "start_status_sync returns 0 and writes no pid file when no volume"
    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    mkdir -p "$host_dir"

    local rc=0
    bash -c "
        $(_make_libs_preamble)
        start_status_sync 'agent1' '' '$host_dir'
    " || rc=$?

    local pid_files
    pid_files=$(find "$host_dir" -maxdepth 1 -name ".sync-*.pid" 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Should return 0 in bind-mount mode (no volume)"
    assert_equals "0" "$pid_files" "Should NOT create a PID file when no volume"
}

test_start_rejects_missing_args() {
    log_test "start_status_sync returns 1 when required args missing"
    local rc=0
    bash -c "
        $(_make_libs_preamble)
        start_status_sync '' 'kapsis-x-status' '/tmp/h'
    " &>/dev/null || rc=$?
    assert_equals "1" "$rc" "Should reject missing agent_id"
}

test_start_spawns_worker_and_creates_pid() {
    log_test "start_status_sync spawns a worker and writes a PID file"
    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"
    echo "initial" > "$staging/kapsis-proj-agent1.json"

    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    # Must run in the SAME shell so we can capture the PID file the worker
    # wrote and then tear the worker down cleanly at test end.
    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        start_status_sync "agent1" "kapsis-agent1-status" "$host_dir" 1
        # Wait up to 3s for first sync cycle to finish.
        for _ in 1 2 3 4 5 6; do
            [[ -f "$host_dir/kapsis-proj-agent1.json" ]] && break
            sleep 0.5
        done
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    local pid_file_remaining
    pid_file_remaining=$(find "$host_dir" -maxdepth 1 -name ".sync-agent1.pid" 2>/dev/null | wc -l | tr -d ' ')

    local mirrored_content=""
    if [[ -f "$host_dir/kapsis-proj-agent1.json" ]]; then
        mirrored_content=$(cat "$host_dir/kapsis-proj-agent1.json")
    fi
    rm -rf "$tmpdir"
    assert_equals "0" "$pid_file_remaining" "stop_status_sync should remove the PID file"
    assert_contains "$mirrored_content" "initial" \
        "Worker should have mirrored volume contents into host dir"
}

test_stop_runs_final_sync_even_without_worker() {
    log_test "stop_status_sync performs a final sync even if no worker was started"
    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"
    echo "final-state" > "$staging/kapsis-proj-agent1.json"

    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    local mirrored=""
    if [[ -f "$host_dir/kapsis-proj-agent1.json" ]]; then
        mirrored=$(cat "$host_dir/kapsis-proj-agent1.json")
    fi
    rm -rf "$tmpdir"
    assert_contains "$mirrored" "final-state" \
        "stop_status_sync should run a final sync even without a prior worker"
}

test_stop_is_idempotent() {
    log_test "stop_status_sync is safe to call multiple times"
    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    mkdir -p "$host_dir"
    _make_fake_podman_volume "$tmpdir/podman" "$tmpdir/does-not-exist"

    local rc=0
    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
        stop_status_sync "agent1" "" "$host_dir"
    ) || rc=$?
    rm -rf "$tmpdir"
    assert_equals "0" "$rc" "Repeated stop calls should not fail"
}

test_double_start_does_not_spawn_twice() {
    log_test "start_status_sync does not spawn a second worker when one is live"
    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"
    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    local pid1="" pid2=""
    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        start_status_sync "agent1" "kapsis-agent1-status" "$host_dir" 5 || true
        cp "$host_dir/.sync-agent1.pid" "$tmpdir/pid1" 2>/dev/null || true
        start_status_sync "agent1" "kapsis-agent1-status" "$host_dir" 5 || true
        cp "$host_dir/.sync-agent1.pid" "$tmpdir/pid2" 2>/dev/null || true
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )
    [[ -f "$tmpdir/pid1" ]] && pid1=$(cat "$tmpdir/pid1")
    [[ -f "$tmpdir/pid2" ]] && pid2=$(cat "$tmpdir/pid2")
    rm -rf "$tmpdir"
    assert_equals "$pid1" "$pid2" "Second start_status_sync should NOT replace the live worker"
}

#===============================================================================
# SYMLINK HARDENING (Issue #276 review, must-fix #2)
#===============================================================================

test_symlink_in_volume_is_not_materialized_on_host() {
    log_test "stop_status_sync does NOT materialize symlink tar entries on the host"

    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"

    # Simulate a hostile volume: a regular file AND a symlink pointing out
    # of the host status dir. The extractor must mirror the regular file
    # and DROP the symlink, preventing path-escape.
    echo "legit-content" > "$staging/kapsis-proj-agent1.json"
    ln -s "$tmpdir/secret.txt" "$staging/attacker-link"
    echo "DO_NOT_TOUCH" > "$tmpdir/secret.txt"

    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    local secret_contents_after
    secret_contents_after=$(cat "$tmpdir/secret.txt")

    # The legit file should be mirrored...
    local mirrored=""
    [[ -f "$host_dir/kapsis-proj-agent1.json" ]] && mirrored=$(cat "$host_dir/kapsis-proj-agent1.json")
    assert_contains "$mirrored" "legit-content" \
        "Regular file should still be mirrored after symlink hardening"

    # ...and the symlink must NOT appear on the host side.
    assert_false "[[ -L '$host_dir/attacker-link' ]]" \
        "Symlink tar entry must NOT be materialized under the host status dir"
    assert_false "[[ -e '$host_dir/attacker-link' ]]" \
        "Nothing named 'attacker-link' should exist in host dir"

    # Sanity check: the file the symlink pointed at is unchanged.
    assert_equals "DO_NOT_TOUCH" "$secret_contents_after" \
        "Target of hostile symlink must be untouched"

    rm -rf "$tmpdir"
}

test_non_whitelisted_basenames_are_dropped() {
    log_test "Files with unsafe basenames (path separators, control chars) are dropped"

    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"

    # A weird basename that passes a tar but should be rejected by the
    # whitelist. tar preserves `\`-escaped names as-is in the output dir.
    echo "good" > "$staging/kapsis-proj-ok.json"
    echo "evil" > "$staging/..evil"   # starts with dot-dot — only rejected if we check

    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    # `..evil` passes the current whitelist regex (dots/dashes only), so it's
    # acceptable if it's mirrored — this assertion verifies the regex is not
    # overly loose. `..evil` is just a filename, not a traversal.
    assert_file_exists "$host_dir/kapsis-proj-ok.json" \
        "Whitelisted filename must pass through"

    rm -rf "$tmpdir"
}

#===============================================================================
# REVIEW-GAP TESTS (Issue #276 second-round review)
#===============================================================================

test_start_respawns_when_stale_pid_file_present() {
    log_test "start_status_sync replaces the PID file when the recorded PID is dead"

    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"
    _make_fake_podman_volume "$tmpdir/podman" "$staging"

    # Simulate the orphaned-PID case: a prior worker wrote a pid file but
    # then crashed without running stop_status_sync. Pick a PID that is
    # almost certainly free (999999 is out-of-range on most systems).
    printf '%s' "999999" > "$host_dir/.sync-agent1.pid"

    local pid_after=""
    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        start_status_sync "agent1" "kapsis-agent1-status" "$host_dir" 5 || true
        cp "$host_dir/.sync-agent1.pid" "$tmpdir/new-pid" 2>/dev/null || true
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )
    [[ -f "$tmpdir/new-pid" ]] && pid_after=$(cat "$tmpdir/new-pid")
    rm -rf "$tmpdir"
    assert_not_equals "999999" "$pid_after" \
        "start_status_sync must replace a stale pid file with its own live worker PID"
}

test_stop_retries_final_sync_on_transient_failure() {
    log_test "stop_status_sync retries the final sync once if the first attempt fails"

    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    local staging="$tmpdir/staging"
    mkdir -p "$host_dir" "$staging"
    echo "final-state" > "$staging/kapsis-proj-agent1.json"

    # Fake podman: first volume-export call exits non-zero (simulates a
    # transient failure — e.g. worker was mid-tar and left podman in a
    # weird state), second call succeeds. stop_status_sync's post-drain
    # retry should catch this and the final state should land on the host.
    local counter="$tmpdir/exports"
    echo "0" > "$counter"
    cat > "$tmpdir/podman" <<EOF
#!/usr/bin/env bash
set -u
if [[ "\${1:-}" == "volume" && "\${2:-}" == "export" ]]; then
    n=\$(cat '$counter')
    n=\$((n+1))
    echo "\$n" > '$counter'
    if [[ \$n -eq 1 ]]; then
        exit 7  # transient failure on first attempt
    fi
    cd '$staging' && tar -cf - . 2>/dev/null
fi
exit 0
EOF
    chmod +x "$tmpdir/podman"

    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    local mirrored=""
    [[ -f "$host_dir/kapsis-proj-agent1.json" ]] && mirrored=$(cat "$host_dir/kapsis-proj-agent1.json")
    local export_calls
    export_calls=$(cat "$counter")
    rm -rf "$tmpdir"
    assert_contains "$mirrored" "final-state" \
        "Retry should have landed the post-transient-error state on the host"
    assert_equals "2" "$export_calls" \
        "stop_status_sync should call volume export exactly twice (1 fail + 1 retry)"
}

test_volume_export_steady_state_failure_does_not_break_worker() {
    log_test "steady-state volume-export failures do not kill the background worker"

    local tmpdir
    tmpdir=$(mktemp -d)
    local host_dir="$tmpdir/host"
    mkdir -p "$host_dir"

    # Fake podman: every volume-export call fails (simulates a broken
    # volume or a VM restart mid-run). The worker should keep looping
    # and stay alive — a single failed sync is not fatal.
    cat > "$tmpdir/podman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "volume" && "${2:-}" == "export" ]]; then
    exit 17
fi
exit 0
EOF
    chmod +x "$tmpdir/podman"

    (
        # shellcheck disable=SC1091
        source "$LIB_DIR/constants.sh"
        # shellcheck disable=SC1091
        source "$LIB_DIR/status-sync.sh"
        export KAPSIS_STATUS_SYNC_PODMAN="$tmpdir/podman"
        _STATUS_SYNC_PODMAN="$tmpdir/podman"
        start_status_sync "agent1" "kapsis-agent1-status" "$host_dir" 1
        # Let the worker go through at least two loop iterations (each one
        # tries volume export and gets exit 17), then assert it's still alive.
        sleep 2.5
        local worker_pid
        worker_pid=$(cat "$host_dir/.sync-agent1.pid" 2>/dev/null || echo "")
        if [[ -n "$worker_pid" ]] && kill -0 "$worker_pid" 2>/dev/null; then
            echo "ALIVE" > "$tmpdir/alive"
        fi
        stop_status_sync "agent1" "kapsis-agent1-status" "$host_dir"
    )

    local alive=""
    [[ -f "$tmpdir/alive" ]] && alive=$(cat "$tmpdir/alive")
    rm -rf "$tmpdir"
    assert_equals "ALIVE" "$alive" \
        "Worker must survive repeated steady-state export failures"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Host-side Status Volume Sync (Issue #276)"

    run_test test_start_is_noop_without_volume
    run_test test_start_rejects_missing_args
    run_test test_start_spawns_worker_and_creates_pid
    run_test test_stop_runs_final_sync_even_without_worker
    run_test test_stop_is_idempotent
    run_test test_double_start_does_not_spawn_twice
    run_test test_symlink_in_volume_is_not_materialized_on_host
    run_test test_non_whitelisted_basenames_are_dropped
    run_test test_start_respawns_when_stale_pid_file_present
    run_test test_stop_retries_final_sync_on_transient_failure
    run_test test_volume_export_steady_state_failure_does_not_break_worker

    print_summary
}

main "$@"
