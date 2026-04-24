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

    print_summary
}

main "$@"
