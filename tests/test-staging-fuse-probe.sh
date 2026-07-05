#!/usr/bin/env bash
#===============================================================================
# Tests for FUSE availability probe in staged config installation (Issue #419)
#
# After PR #397 the launcher no longer passes /dev/fuse (or SYS_ADMIN) into
# containers, so fuse-overlayfs fails for EVERY staged config with a scary
# "fuse: device not found" warning before falling back to atomic copy.
#
# Verifies that:
# - _fuse_available fails when the fuse-overlayfs binary is not on PATH
# - setup_staged_config_overlays probes FUSE availability exactly ONCE
#   (not per staged config)
# - When FUSE is unavailable: configs are staged via atomic copy directly,
#   with a single INFO line and NO "Overlay failed" warnings, and
#   fuse-overlayfs is never invoked
# - When FUSE is available: the fuse-overlayfs path is used unchanged
# - When FUSE is available but the mount fails: the pre-existing per-entry
#   warn-and-fall-back-to-copy behavior is preserved (Linux CI path)
#
# No container required — extracts the production functions from
# scripts/entrypoint.sh and exercises them against a temp directory tree.
#
# Run: ./tests/test-staging-fuse-probe.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

ENTRYPOINT="$KAPSIS_ROOT/scripts/entrypoint.sh"

# Real atomic-copy implementation (same one the entrypoint sources)
source "$KAPSIS_ROOT/scripts/lib/atomic-copy.sh"

#===============================================================================
# TEST FIXTURE
#===============================================================================

TEST_ROOT=""
PROBE_LOG=""
FUSE_LOG=""
COPY_LOG=""

setup_fixture() {
    TEST_ROOT=$(mktemp -d)
    PROBE_LOG="$TEST_ROOT/probe.log"
    FUSE_LOG="$TEST_ROOT/fuse.log"
    COPY_LOG="$TEST_ROOT/copy.log"

    # Staged configs: two directories and one file, mirroring production
    mkdir -p "$TEST_ROOT/kapsis-staging/.claude" "$TEST_ROOT/kapsis-staging/.ssh-alt"
    echo '{"model":"test"}' > "$TEST_ROOT/kapsis-staging/.claude/settings.json"
    echo 'key-material' > "$TEST_ROOT/kapsis-staging/.ssh-alt/id_test"
    echo 'gitconfig-content' > "$TEST_ROOT/kapsis-staging/.gitconfig"

    mkdir -p "$TEST_ROOT/home"
}

cleanup_fixture() {
    [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
    TEST_ROOT=""
}

# Extract the production functions, rewriting the hardcoded container paths
# (/kapsis-staging, /kapsis-upper, /kapsis-work, /kapsis-status) to live under
# the test root so the loop can run unprivileged on any host.
load_production_functions() {
    local fn_text
    fn_text=$(sed -n '/^_fuse_available()/,/^}/p' "$ENTRYPOINT")
    fn_text+=$'\n'
    fn_text+=$(sed -n '/^setup_staged_config_overlays()/,/^}/p' "$ENTRYPOINT")
    fn_text=${fn_text//\/kapsis-/"$TEST_ROOT"\/kapsis-}
    eval "$fn_text"
}

# Runs setup_staged_config_overlays in a subshell with instrumented stubs.
# Args: $1 = probe result to force ("0" success / "1" failure / "real" to
#            keep the production _fuse_available)
#       $2 = fuse-overlayfs stub exit code (mount success/failure)
# Prints the captured log output.
run_staging() {
    local probe_result="$1"
    local fuse_rc="$2"

    # shellcheck disable=SC2329  # stubs are invoked indirectly by the extracted production function
    (
        export HOME="$TEST_ROOT/home"
        export KAPSIS_STAGED_CONFIGS=".claude,.ssh-alt,.gitconfig"

        # Logging stubs (subshell-local: the framework's helpers are untouched)
        log_debug() { echo "[DEBUG] $*"; }
        log_info() { echo "[INFO] $*"; }
        log_warn() { echo "[WARN] $*"; }
        log_success() { echo "[OK] $*"; }

        # SSH post-processing stubs (not under test)
        fix_ssh_permissions() { :; }
        patch_ssh_config_portability() { :; }

        # Instrumented atomic_copy_dir: record the call, then delegate
        _real_atomic_copy_dir=$(declare -f atomic_copy_dir)
        eval "_orig_${_real_atomic_copy_dir}"
        atomic_copy_dir() {
            echo "$1" >> "$COPY_LOG"
            _orig_atomic_copy_dir "$@"
        }

        # fuse-overlayfs stub: records invocations, simulates mount result.
        # A shell function shadows any real binary on PATH.
        fuse-overlayfs() {
            echo "$*" >> "$FUSE_LOG"
            if [[ "$fuse_rc" -ne 0 ]]; then
                echo "fuse: device not found, try 'modprobe fuse' first" >&2
                return "$fuse_rc"
            fi
            return 0
        }

        if [[ "$probe_result" != "real" ]]; then
            # Instrumented probe: records each call so the test can assert
            # the availability check runs ONCE, not once per staged config.
            eval "_fuse_available() {
                echo probed >> \"$PROBE_LOG\"
                return $probe_result
            }"
        fi

        setup_staged_config_overlays 2>&1
    )
}

#===============================================================================
# TESTS
#===============================================================================

test_probe_fails_without_fuse_overlayfs_binary() {
    log_test "Testing _fuse_available fails when fuse-overlayfs is not on PATH"

    setup_fixture
    load_production_functions

    local rc=0
    (PATH="$TEST_ROOT/empty-bin" _fuse_available) || rc=$?
    assert_not_equals "0" "$rc" \
        "_fuse_available must fail when neither /dev/fuse nor fuse-overlayfs can be resolved"

    cleanup_fixture
}

test_fuse_unavailable_copies_directly_without_warnings() {
    log_test "Testing FUSE-unavailable path: atomic copy, single INFO line, no warnings"

    setup_fixture
    load_production_functions

    local output
    output=$(run_staging 1 1)

    # No fuse-overlayfs invocation at all
    assert_file_not_exists "$FUSE_LOG" \
        "fuse-overlayfs must NOT be invoked when the probe reports FUSE unavailable"

    # No scary per-config warnings (the issue #419 symptom)
    assert_not_contains "$output" "Overlay failed" \
        "No 'Overlay failed' warnings when FUSE is known-unavailable"
    assert_not_contains "$output" "Falling back to atomic copy" \
        "No per-config fallback warnings when FUSE is known-unavailable"

    # Exactly one INFO line announcing the copy strategy
    local info_count
    info_count=$(grep -c "FUSE unavailable" <<< "$output" || true)
    assert_equals "1" "$info_count" \
        "Exactly ONE 'FUSE unavailable' INFO line for the whole staging loop"

    # Probe computed once, not per staged config (3 configs staged)
    local probe_count
    probe_count=$(wc -l < "$PROBE_LOG" | tr -d ' ')
    assert_equals "1" "$probe_count" \
        "_fuse_available must be evaluated exactly once per staging run"

    # Both staged dirs went through atomic_copy_dir
    assert_file_contains "$COPY_LOG" ".claude" \
        ".claude dir must be staged via atomic_copy_dir"
    assert_file_contains "$COPY_LOG" ".ssh-alt" \
        ".ssh-alt dir must be staged via atomic_copy_dir"

    # Configs actually landed in HOME (dirs and the plain file)
    assert_file_exists "$TEST_ROOT/home/.claude/settings.json" \
        "Staged dir contents must land in HOME via the copy path"
    assert_file_exists "$TEST_ROOT/home/.gitconfig" \
        "Staged plain file must land in HOME"
    assert_file_contains "$TEST_ROOT/home/.claude/settings.json" '"model":"test"' \
        "Copied settings.json must preserve content"

    cleanup_fixture
}

test_fuse_available_keeps_overlay_path() {
    log_test "Testing FUSE-available path: fuse-overlayfs used, no atomic copy for dirs"

    setup_fixture
    load_production_functions

    local output
    output=$(run_staging 0 0)

    assert_not_contains "$output" "FUSE unavailable" \
        "No 'FUSE unavailable' INFO line when the probe succeeds"
    assert_not_contains "$output" "Overlay failed" \
        "No overlay failure warnings when the mount succeeds"

    # fuse-overlayfs invoked for each staged DIRECTORY (2 dirs, not the file)
    local fuse_count
    fuse_count=$(wc -l < "$FUSE_LOG" | tr -d ' ')
    assert_equals "2" "$fuse_count" \
        "fuse-overlayfs must be invoked once per staged directory"

    # No dir went through the copy fallback
    assert_file_not_exists "$COPY_LOG" \
        "atomic_copy_dir must NOT be called when overlay mounts succeed"

    cleanup_fixture
}

test_fuse_available_mount_failure_falls_back_with_warning() {
    log_test "Testing FUSE-available + mount failure: pre-existing warn-and-copy fallback preserved"

    setup_fixture
    load_production_functions

    local output
    output=$(run_staging 0 1)

    # Existing behavior (issues #151/#328) must be unchanged: per-entry
    # warning with captured stderr, then atomic copy fallback.
    assert_contains "$output" "Overlay failed for .claude (rc=1): fuse: device not found" \
        "Mount failure must surface the captured fuse-overlayfs stderr"
    assert_contains "$output" "Falling back to atomic copy for .claude" \
        "Mount failure must announce the per-entry copy fallback"
    assert_file_contains "$COPY_LOG" ".claude" \
        "Mount failure must route the dir through atomic_copy_dir"
    assert_file_exists "$TEST_ROOT/home/.claude/settings.json" \
        "Fallback copy must still land the staged config in HOME"

    cleanup_fixture
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Staged config FUSE probe (Issue #419)"

    run_test test_probe_fails_without_fuse_overlayfs_binary
    run_test test_fuse_unavailable_copies_directly_without_warnings
    run_test test_fuse_available_keeps_overlay_path
    run_test test_fuse_available_mount_failure_falls_back_with_warning

    print_summary
}

main "$@"
