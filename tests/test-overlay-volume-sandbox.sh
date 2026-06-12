#!/usr/bin/env bash
# test-overlay-volume-sandbox.sh — Unit tests for Issue #376
#
# Verifies that on macOS, the overlay sandbox keeps upper/work in a Podman
# named volume (VM-native ext4) and mounts the project with the SAME
# podman-side `:O,upperdir=...,workdir=...` mechanism the Linux path uses —
# upperdir/workdir pointing at the volume's VM-side mountpoint. The agent
# container gets ZERO additional capabilities or devices (PR #397 rework:
# no --cap-add SYS_ADMIN, no --device /dev/fuse, no in-container
# fuse-overlayfs), so the mode is available under every security profile.
#
# Host-tier tests: source the production library scripts/lib/overlay-sandbox.sh
# directly (no body duplication — PR #397 review finding 3), with logging,
# is_macos, and podman stubbed.  No container is launched.  The one behavior
# that cannot be verified here is the VM-side interpretation of the volume
# mountpoint inside the :O option string — that needs a single real-macOS
# smoke run (see docs/ARCHITECTURE.md).
#
# Category: validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# NOTE: test-framework.sh re-assigns SCRIPT_DIR to tests/lib and sources
# scripts/lib/constants.sh itself; use KAPSIS_ROOT (set by the framework)
# for any further repo-relative paths.
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# Stubs — must be defined BEFORE sourcing the lib so its `declare -f` guards
# leave them untouched (same pattern as test-vfkit-watchdog.sh).
#===============================================================================

_TEST_SANDBOX_BASE="/tmp/kapsis-overlay-test-$$"
_TEST_PROJECT="/tmp/kapsis-overlay-project-$$"
_TEST_AGENT_ID="ovltest$$"
# Deterministic VM-side mountpoint base used by the podman stub below.
_TEST_VOL_BASE="/test-vm/volumes"

# Call log lives in a FILE (not a variable): the production lib invokes
# podman inside command substitutions, and variable mutations made in those
# subshells would be lost.
_PODMAN_CALLS_FILE="/tmp/kapsis-overlay-test-calls-$$.log"
_podman_calls() { cat "$_PODMAN_CALLS_FILE" 2>/dev/null || true; }

# shellcheck disable=SC2034  # globals consumed by the sourced production lib
_setup() {
    mkdir -p "$_TEST_PROJECT" "$_TEST_SANDBOX_BASE"
    PROJECT_PATH="$_TEST_PROJECT"
    AGENT_ID="$_TEST_AGENT_ID"
    SANDBOX_UPPER_BASE="$_TEST_SANDBOX_BASE"
    IMAGE_NAME="kapsis-test-image:latest"
    OVERLAY_VOLUME=""
    OVERLAY_VOLUME_MOUNTPOINT=""
    SANDBOX_DIR=""
    UPPER_DIR=""
    WORK_DIR=""
    VOLUME_MOUNTS=()
    : > "$_PODMAN_CALLS_FILE"
    _PODMAN_VOLUME_EXISTS_RC=1
}

_teardown() {
    rm -rf "$_TEST_PROJECT" "$_TEST_SANDBOX_BASE" 2>/dev/null || true
    OVERLAY_VOLUME=""
    OVERLAY_VOLUME_MOUNTPOINT=""
    SANDBOX_DIR=""
    UPPER_DIR=""
    WORK_DIR=""
    VOLUME_MOUNTS=()
    rm -f "$_PODMAN_CALLS_FILE" 2>/dev/null || true
    _PODMAN_VOLUME_EXISTS_RC=1
    unset KAPSIS_OVERLAY_USE_VOLUME 2>/dev/null || true
    unset KAPSIS_SECURITY_PROFILE 2>/dev/null || true
    unset DRY_RUN 2>/dev/null || true
}

# Logging stubs — silence output from sourced functions during unit tests
ensure_dir() { mkdir -p "$1" 2>/dev/null || true; }
log_info()    { :; }
log_debug()   { :; }
log_success() { :; }
log_warn()    { :; }
log_error()   { :; }

# is_macos stub — controlled per-test via _IS_MACOS_OVERRIDE
_IS_MACOS_OVERRIDE="false"
is_macos() { [[ "$_IS_MACOS_OVERRIDE" == "true" ]]; }

# podman stub — records invocations to the call file (subshell-safe);
# `volume exists` rc is test-controlled; `volume inspect` returns a
# deterministic VM-side mountpoint.
_PODMAN_VOLUME_EXISTS_RC=1
podman() {
    printf 'podman %s\n' "$*" >> "$_PODMAN_CALLS_FILE"
    case "${1:-} ${2:-}" in
        "volume exists")  return "$_PODMAN_VOLUME_EXISTS_RC" ;;
        "volume rm")      return 0 ;;
        "volume create")  return 0 ;;
        "volume inspect") echo "${_TEST_VOL_BASE}/${3}/_data"; return 0 ;;
        "volume export")  return 1 ;;  # overridden per-test where needed
    esac
    return 0
}

#===============================================================================
# Functions under test — sourced from the production library (no duplication)
#===============================================================================
# shellcheck source=../scripts/lib/overlay-sandbox.sh
source "$KAPSIS_ROOT/scripts/lib/overlay-sandbox.sh"

#===============================================================================
# Test cases — macOS named-volume path
#===============================================================================

test_macos_overlay_volume_name() {
    log_test "macOS: OVERLAY_VOLUME is set to kapsis-<AGENT_ID>-overlay"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox

    assert_equals "kapsis-${_TEST_AGENT_ID}-overlay" "$OVERLAY_VOLUME" \
        "OVERLAY_VOLUME should be kapsis-<AGENT_ID>-overlay"

    _teardown
}

test_macos_sandbox_dir_created_upper_work_absent() {
    log_test "macOS: SANDBOX_DIR created as export target; upper/ and work/ NOT pre-created on host"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox

    assert_dir_exists "$SANDBOX_DIR" \
        "SANDBOX_DIR must exist as export target for overlay volume"
    assert_dir_not_exists "$UPPER_DIR" \
        "UPPER_DIR must NOT be pre-created on host — it lives in the named volume"
    assert_dir_not_exists "$WORK_DIR" \
        "WORK_DIR must NOT be pre-created on host — it lives in the named volume"

    _teardown
}

test_macos_mountpoint_resolved_from_volume() {
    log_test "macOS: OVERLAY_VOLUME_MOUNTPOINT resolved via podman volume inspect"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox

    assert_equals "${_TEST_VOL_BASE}/kapsis-${_TEST_AGENT_ID}-overlay/_data" \
        "$OVERLAY_VOLUME_MOUNTPOINT" \
        "mountpoint must come from podman volume inspect --format '{{.Mountpoint}}'"
    assert_contains "$(_podman_calls)" \
        "podman volume inspect kapsis-${_TEST_AGENT_ID}-overlay --format {{.Mountpoint}}" \
        "volume inspect must be invoked to resolve the VM-side mountpoint"

    _teardown
}

test_macos_mounts_use_podman_overlay_on_volume() {
    log_test "macOS: project mounted :O with upperdir/workdir under the volume's VM mountpoint"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    local volmount="${_TEST_VOL_BASE}/kapsis-${_TEST_AGENT_ID}-overlay/_data"

    assert_contains "$mounts" "${_TEST_PROJECT}:/workspace:O,upperdir=${volmount}/upper,workdir=${volmount}/work" \
        "project must be mounted :O with upperdir/workdir on the named volume's VM mountpoint"
    assert_not_contains "$mounts" ":/lower" \
        "legacy /lower read-only mount must be gone — podman assembles the overlay itself"
    assert_not_contains "$mounts" ":/overlay" \
        "the named volume must NOT be mounted into the agent container"

    _teardown
}

test_macos_opt_out_uses_host_dirs() {
    log_test "macOS: KAPSIS_OVERLAY_USE_VOLUME=false falls back to host upper/work dirs"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # shellcheck disable=SC2034  # consumed by the sourced production lib
    KAPSIS_OVERLAY_USE_VOLUME="false"
    UPPER_DIR="${_TEST_SANDBOX_BASE}/upper"
    WORK_DIR="${_TEST_SANDBOX_BASE}/work"

    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O,upperdir=${_TEST_SANDBOX_BASE}/upper" \
        "opt-out must fall back to kernel OverlayFS with host-side upperdir"
    assert_not_contains "$mounts" "$_TEST_VOL_BASE" \
        "opt-out must not reference any named-volume mountpoint"

    _teardown
}

test_macos_dry_run_skips_podman() {
    log_test "macOS: dry-run issues no podman calls and uses a placeholder mountpoint"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # shellcheck disable=SC2034  # consumed by the sourced production lib
    DRY_RUN="true"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    assert_equals "" "$(_podman_calls)" \
        "dry-run must not create/inspect volumes or run helper containers"
    assert_contains "${VOLUME_MOUNTS[*]}" ":O,upperdir=/dry-run/volumes/${OVERLAY_VOLUME}/_data/upper" \
        "dry-run must render the :O mount with the placeholder mountpoint"

    _teardown
}

#===============================================================================
# Test cases — volume preparation (stale reset + upper/work pre-creation)
#===============================================================================

test_macos_stale_volume_removed_before_launch() {
    log_test "macOS: pre-existing overlay volume is force-removed before launch"
    _setup
    _IS_MACOS_OVERRIDE="true"
    _PODMAN_VOLUME_EXISTS_RC=0  # simulate leftover volume from a crashed run

    setup_overlay_sandbox

    local calls
    calls="$(_podman_calls)"
    assert_contains "$calls" "podman volume rm --force kapsis-${_TEST_AGENT_ID}-overlay" \
        "stale overlay volume must be removed so the new run starts with a clean upper layer"
    # The reset must happen BEFORE the upper/work pre-creation helper runs.
    assert_contains "${calls%%run --rm*}" "volume rm --force" \
        "stale volume reset must precede the upper/work pre-creation container"

    _teardown
}

test_macos_no_stale_volume_no_rm() {
    log_test "macOS: no pre-existing overlay volume — no volume rm; volume created fresh"
    _setup
    _IS_MACOS_OVERRIDE="true"
    _PODMAN_VOLUME_EXISTS_RC=1  # volume does not exist

    setup_overlay_sandbox

    assert_not_contains "$(_podman_calls)" "volume rm" \
        "volume rm must not run when no stale volume exists"
    assert_contains "$(_podman_calls)" "podman volume create kapsis-${_TEST_AGENT_ID}-overlay" \
        "volume must be created explicitly — it is no longer auto-created by a -v volume mount"

    _teardown
}

test_macos_upper_work_precreated_in_volume() {
    log_test "macOS: upper/ and work/ pre-created inside the volume by a throwaway container"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox

    assert_contains "$(_podman_calls)" "mkdir -p /v/upper /v/work" \
        "podman does not MkdirAll custom upperdir/workdir — they must be pre-created"
    assert_contains "$(_podman_calls)" "-v kapsis-${_TEST_AGENT_ID}-overlay:/v" \
        "pre-creation helper must mount the overlay volume"
    assert_contains "$(_podman_calls)" "--entrypoint sh" \
        "helper must bypass the image entrypoint (podman-health.sh probe pattern)"
    assert_contains "$(_podman_calls)" "--cap-drop=ALL" \
        "helper container must itself run fully cap-dropped"
    assert_contains "$(_podman_calls)" "kapsis-test-image:latest" \
        "helper must reuse the already-present sandbox image (IMAGE_NAME)"

    _teardown
}

test_macos_volume_prep_failure_returns_mount_failure() {
    log_test "macOS: helper-container failure bubbles up as KAPSIS_EXIT_MOUNT_FAILURE (4)"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # Override stub: the mkdir helper run fails.
    podman() {
        printf 'podman %s\n' "$*" >> "$_PODMAN_CALLS_FILE"
        case "${1:-} ${2:-}" in
            "volume exists")  return 1 ;;
            "volume create")  return 0 ;;
            "volume inspect") echo "${_TEST_VOL_BASE}/${3}/_data"; return 0 ;;
            "run --rm")       return 125 ;;
        esac
        return 0
    }

    local rc=0
    setup_overlay_sandbox || rc=$?
    assert_equals "${KAPSIS_EXIT_MOUNT_FAILURE:-4}" "$rc" \
        "volume preparation failure must surface through the mount_failure path (exit 4)"

    _restore_podman_stub
    _teardown
}

#===============================================================================
# Test cases — security profiles (PR #397 rework: no capability needed,
# so the named-volume overlay stays enabled under EVERY profile)
#===============================================================================

test_strict_profile_keeps_volume_mode() {
    log_test "macOS: strict profile keeps the named-volume overlay (no SYS_ADMIN involved)"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # shellcheck disable=SC2034  # consumed by the sourced production lib
    KAPSIS_SECURITY_PROFILE="strict"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    assert_equals "kapsis-${_TEST_AGENT_ID}-overlay" "$OVERLAY_VOLUME" \
        "strict profile must NOT downgrade — the podman-side overlay needs no capability"
    assert_true "overlay_volume_mode_enabled" \
        "overlay_volume_mode_enabled must stay true under strict profile"
    assert_true "[[ \"\${KAPSIS_OVERLAY_USE_VOLUME:-true}\" == \"true\" ]]" \
        "KAPSIS_OVERLAY_USE_VOLUME must not be mutated to false under strict profile"
    assert_contains "${VOLUME_MOUNTS[*]}" ":O,upperdir=${_TEST_VOL_BASE}/" \
        "strict profile must mount via the volume-backed :O overlay"

    _teardown
}

test_paranoid_profile_keeps_volume_mode() {
    log_test "macOS: paranoid profile keeps the named-volume overlay (no SYS_ADMIN involved)"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # shellcheck disable=SC2034  # consumed by the sourced production lib
    KAPSIS_SECURITY_PROFILE="paranoid"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    assert_true "overlay_volume_mode_enabled" \
        "overlay_volume_mode_enabled must stay true under paranoid profile"
    assert_contains "${VOLUME_MOUNTS[*]}" ":O,upperdir=${_TEST_VOL_BASE}/" \
        "paranoid profile must mount via the volume-backed :O overlay"
    assert_not_contains "${VOLUME_MOUNTS[*]}" ":/overlay" \
        "the named volume must not be mounted into the container under any profile"

    _teardown
}

test_standard_profile_keeps_volume_mode() {
    log_test "macOS: standard profile keeps the named-volume overlay enabled"
    _setup
    _IS_MACOS_OVERRIDE="true"
    # shellcheck disable=SC2034  # consumed by the sourced production lib
    KAPSIS_SECURITY_PROFILE="standard"

    setup_overlay_sandbox

    assert_equals "kapsis-${_TEST_AGENT_ID}-overlay" "$OVERLAY_VOLUME" \
        "standard profile must keep the named-volume overlay path"
    assert_true "overlay_volume_mode_enabled" \
        "overlay_volume_mode_enabled must report true under standard profile"

    _teardown
}

test_no_extra_capabilities_in_launch_sources() {
    log_test "no --cap-add SYS_ADMIN / --device /dev/fuse / fuse env left in the overlay launch path"

    assert_false "grep -q 'SYS_ADMIN' '$KAPSIS_ROOT/scripts/launch-agent.sh' '$KAPSIS_ROOT/scripts/lib/overlay-sandbox.sh'" \
        "SYS_ADMIN must not appear anywhere in launch-agent.sh or overlay-sandbox.sh"
    assert_false "grep -q '/dev/fuse' '$KAPSIS_ROOT/scripts/launch-agent.sh' '$KAPSIS_ROOT/scripts/lib/overlay-sandbox.sh'" \
        "/dev/fuse must not appear anywhere in launch-agent.sh or overlay-sandbox.sh"
    assert_false "grep -q 'KAPSIS_USE_FUSE_OVERLAY' '$KAPSIS_ROOT/scripts/launch-agent.sh' '$KAPSIS_ROOT/scripts/lib/overlay-sandbox.sh'" \
        "the KAPSIS_USE_FUSE_OVERLAY env signal must no longer be emitted by the launcher"
}

#===============================================================================
# Test cases — Linux path unchanged
#===============================================================================

test_linux_creates_host_upper_and_work() {
    log_test "Linux: setup_overlay_sandbox creates upper/ and work/ on host; OVERLAY_VOLUME unset"
    _setup
    _IS_MACOS_OVERRIDE="false"

    setup_overlay_sandbox

    assert_dir_exists "$UPPER_DIR" \
        "UPPER_DIR must exist on Linux (host-side overlay upper)"
    assert_dir_exists "$WORK_DIR" \
        "WORK_DIR must exist on Linux (host-side overlay work)"
    assert_equals "" "$OVERLAY_VOLUME" \
        "OVERLAY_VOLUME must be empty on Linux"
    assert_equals "" "$(_podman_calls)" \
        "no podman volume operations may run on Linux"

    _teardown
}

test_linux_volume_mounts_use_kernel_overlay() {
    log_test "Linux: volume mounts use :O kernel OverlayFS with host upperdir/workdir"
    _setup
    _IS_MACOS_OVERRIDE="false"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}" \
        "Linux must use kernel OverlayFS :O with host-side upperdir/workdir"
    assert_not_contains "$mounts" ":/lower:ro" \
        "Linux must NOT use /lower read-only mount"
    assert_not_contains "$mounts" "$_TEST_VOL_BASE" \
        "Linux must not reference any named-volume mountpoint"

    _teardown
}

#===============================================================================
# Test cases — hardened volume export (PR #397 review findings 2 + 4)
#===============================================================================

test_sanitize_strips_escaping_symlinks_keeps_safe_ones() {
    log_test "export sanitize: strips absolute/..-escaping symlinks and fifos, keeps intra-tree links"
    _setup
    local root="$_TEST_SANDBOX_BASE/staging"
    mkdir -p "$root/upper/node_modules/.bin" "$root/upper/sub"
    echo "data" > "$root/upper/sub/real-file.txt"
    ln -s "/etc/passwd"               "$root/upper/abs-link"
    ln -s "../../../../etc/passwd"    "$root/upper/sub/escape-link"
    ln -s "../sub/real-file.txt"      "$root/upper/node_modules/.bin/safe-link"
    mkfifo "$root/upper/evil-fifo" 2>/dev/null || true

    _sanitize_overlay_export "$root"

    assert_file_not_exists "$root/upper/abs-link" \
        "absolute symlink must be stripped"
    assert_file_not_exists "$root/upper/sub/escape-link" \
        "..-escaping symlink must be stripped"
    assert_true "[[ -L '$root/upper/node_modules/.bin/safe-link' ]]" \
        "safe intra-tree relative symlink must be preserved"
    assert_file_not_exists "$root/upper/evil-fifo" \
        "fifo must be stripped"
    assert_file_exists "$root/upper/sub/real-file.txt" \
        "regular files must be preserved"

    _teardown
}

test_export_overlay_volume_to_host_extracts_upper_and_work() {
    log_test "export: volume tar is staged, sanitized, and moved into SANDBOX_DIR"
    _setup
    _IS_MACOS_OVERRIDE="true"

    # Build a fake volume content tree and stream it like `podman volume export`
    local fixture="$_TEST_SANDBOX_BASE/fixture"
    mkdir -p "$fixture/upper/src" "$fixture/work"
    echo "changed" > "$fixture/upper/src/main.txt"
    ln -s "/etc/shadow" "$fixture/upper/evil-link"
    podman() {
        printf 'podman %s\n' "$*" >> "$_PODMAN_CALLS_FILE"
        case "${1:-} ${2:-}" in
            "volume exists")  return 1 ;;
            "volume inspect") echo "${_TEST_VOL_BASE}/${3}/_data"; return 0 ;;
            "volume export")  tar -cf - -C "$fixture" upper work; return 0 ;;
        esac
        return 0
    }

    setup_overlay_sandbox
    export_overlay_volume_to_host

    assert_file_exists "$UPPER_DIR/src/main.txt" \
        "exported regular file must land in UPPER_DIR"
    assert_dir_exists "$SANDBOX_DIR/work" \
        "exported work/ must land in SANDBOX_DIR"
    assert_file_not_exists "$UPPER_DIR/evil-link" \
        "hostile absolute symlink must be stripped during export"
    assert_false "compgen -G '$SANDBOX_DIR/.export-staging-*' >/dev/null" \
        "staging dir must be cleaned up after export"

    _restore_podman_stub
    _teardown
}

test_export_noop_when_volume_mode_disabled() {
    log_test "export: no-op on Linux / when KAPSIS_OVERLAY_USE_VOLUME=false"
    _setup
    _IS_MACOS_OVERRIDE="false"
    OVERLAY_VOLUME="kapsis-${_TEST_AGENT_ID}-overlay"

    export_overlay_volume_to_host

    assert_not_contains "$(_podman_calls)" "volume export" \
        "podman volume export must not run outside the macOS named-volume path"

    _teardown
}

# Restores the default recording podman stub after per-test overrides.
_restore_podman_stub() {
    podman() {
        printf 'podman %s\n' "$*" >> "$_PODMAN_CALLS_FILE"
        case "${1:-} ${2:-}" in
            "volume exists")  return "$_PODMAN_VOLUME_EXISTS_RC" ;;
            "volume rm")      return 0 ;;
            "volume create")  return 0 ;;
            "volume inspect") echo "${_TEST_VOL_BASE}/${3}/_data"; return 0 ;;
            "volume export")  return 1 ;;
        esac
        return 0
    }
}

#===============================================================================
# Test cases — constants
#===============================================================================

test_overlay_volume_suffix_constant_defined() {
    log_test "KAPSIS_OVERLAY_VOLUME_SUFFIX constant is defined in constants.sh"
    assert_not_empty "${KAPSIS_OVERLAY_VOLUME_SUFFIX:-}" \
        "KAPSIS_OVERLAY_VOLUME_SUFFIX must be defined and non-empty"
}

test_overlay_volume_suffix_value() {
    log_test "KAPSIS_OVERLAY_VOLUME_SUFFIX equals -overlay"
    assert_equals "-overlay" "${KAPSIS_OVERLAY_VOLUME_SUFFIX:-}" \
        "suffix must be -overlay to match cleanup_agent_volumes naming"
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_test_header "Overlay Volume Sandbox (Issue #376)"

    run_test test_macos_overlay_volume_name
    run_test test_macos_sandbox_dir_created_upper_work_absent
    run_test test_macos_mountpoint_resolved_from_volume
    run_test test_macos_mounts_use_podman_overlay_on_volume
    run_test test_macos_opt_out_uses_host_dirs
    run_test test_macos_dry_run_skips_podman
    run_test test_macos_stale_volume_removed_before_launch
    run_test test_macos_no_stale_volume_no_rm
    run_test test_macos_upper_work_precreated_in_volume
    run_test test_macos_volume_prep_failure_returns_mount_failure
    run_test test_strict_profile_keeps_volume_mode
    run_test test_paranoid_profile_keeps_volume_mode
    run_test test_standard_profile_keeps_volume_mode
    run_test test_no_extra_capabilities_in_launch_sources
    run_test test_linux_creates_host_upper_and_work
    run_test test_linux_volume_mounts_use_kernel_overlay
    run_test test_sanitize_strips_escaping_symlinks_keeps_safe_ones
    run_test test_export_overlay_volume_to_host_extracts_upper_and_work
    run_test test_export_noop_when_volume_mode_disabled
    run_test test_overlay_volume_suffix_constant_defined
    run_test test_overlay_volume_suffix_value

    print_summary
}

main "$@"
