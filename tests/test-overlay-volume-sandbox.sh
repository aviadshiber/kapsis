#!/usr/bin/env bash
# test-overlay-volume-sandbox.sh — Unit tests for Issue #376
#
# Verifies that on macOS, the overlay sandbox uses a Podman named volume
# (VM-native ext4) for upper/work dirs instead of the virtio-fs share,
# and that Linux keeps the existing kernel OverlayFS path unchanged.
#
# Host-tier tests: source the production library scripts/lib/overlay-sandbox.sh
# directly (no body duplication — PR #397 review finding 3), with logging,
# is_macos, and podman stubbed.  No container is launched.  Container-tier
# coverage (actual fuse-overlayfs mount inside a kapsis-sandbox image) requires
# Podman + the built image and is deferred to a separate PR.
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

# shellcheck disable=SC2034  # globals consumed by the sourced production lib
_setup() {
    mkdir -p "$_TEST_PROJECT" "$_TEST_SANDBOX_BASE"
    PROJECT_PATH="$_TEST_PROJECT"
    AGENT_ID="$_TEST_AGENT_ID"
    SANDBOX_UPPER_BASE="$_TEST_SANDBOX_BASE"
    OVERLAY_VOLUME=""
    SANDBOX_DIR=""
    UPPER_DIR=""
    WORK_DIR=""
    VOLUME_MOUNTS=()
    _PODMAN_CALLS=""
    _PODMAN_VOLUME_EXISTS_RC=1
}

_teardown() {
    rm -rf "$_TEST_PROJECT" "$_TEST_SANDBOX_BASE" 2>/dev/null || true
    OVERLAY_VOLUME=""
    SANDBOX_DIR=""
    UPPER_DIR=""
    WORK_DIR=""
    VOLUME_MOUNTS=()
    _PODMAN_CALLS=""
    _PODMAN_VOLUME_EXISTS_RC=1
    unset KAPSIS_OVERLAY_USE_VOLUME 2>/dev/null || true
    unset KAPSIS_SECURITY_PROFILE 2>/dev/null || true
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

# podman stub — records invocations; `volume exists` rc is test-controlled.
_PODMAN_CALLS=""
_PODMAN_VOLUME_EXISTS_RC=1
podman() {
    _PODMAN_CALLS+="podman $*"$'\n'
    case "${1:-} ${2:-}" in
        "volume exists") return "$_PODMAN_VOLUME_EXISTS_RC" ;;
        "volume rm")     return 0 ;;
        "volume export") return 1 ;;  # overridden per-test where needed
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
    log_test "macOS: SANDBOX_DIR created as export target; upper/ and work/ NOT pre-created"
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

test_macos_volume_mounts_use_lower_and_overlay() {
    log_test "macOS: volume mounts use /lower:ro and named /overlay, not :O overlay"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"

    assert_contains "$mounts" "/lower:ro" \
        "project must be bind-mounted read-only as /lower"
    assert_contains "$mounts" "/overlay" \
        "named overlay volume must appear in mounts"
    assert_not_contains "$mounts" ":O," \
        "kernel OverlayFS :O option must NOT be used on macOS named-volume path"
    assert_not_contains "$mounts" "upperdir=" \
        "host-side upperdir= option must NOT appear in mounts"
    assert_not_contains "$mounts" "workdir=" \
        "host-side workdir= option must NOT appear in mounts"

    _teardown
}

test_macos_workspace_not_directly_mounted() {
    log_test "macOS: /workspace is NOT directly bind-mounted (entrypoint handles it via fuse-overlayfs)"
    _setup
    _IS_MACOS_OVERRIDE="true"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_not_contains "$mounts" ":/workspace" \
        "/workspace must not appear in volume mounts — set up by entrypoint fuse-overlayfs"

    _teardown
}

test_macos_opt_out_uses_host_dirs() {
    log_test "macOS: KAPSIS_OVERLAY_USE_VOLUME=false falls back to host upper/work dirs"
    _setup
    _IS_MACOS_OVERRIDE="true"
    KAPSIS_OVERLAY_USE_VOLUME="false"
    UPPER_DIR="${_TEST_SANDBOX_BASE}/upper"
    WORK_DIR="${_TEST_SANDBOX_BASE}/work"

    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O," \
        "opt-out must fall back to kernel OverlayFS :O mount"
    assert_contains "$mounts" "upperdir=" \
        "opt-out must pass host-side upperdir="

    _teardown
}

#===============================================================================
# Test cases — stale volume reset (PR #397 review finding 1)
#===============================================================================

test_macos_stale_volume_removed_before_launch() {
    log_test "macOS: pre-existing overlay volume is force-removed before launch"
    _setup
    _IS_MACOS_OVERRIDE="true"
    _PODMAN_VOLUME_EXISTS_RC=0  # simulate leftover volume from a crashed run

    setup_overlay_sandbox

    assert_contains "$_PODMAN_CALLS" "podman volume rm --force kapsis-${_TEST_AGENT_ID}-overlay" \
        "stale overlay volume must be removed so the new run starts with a clean upper layer"

    _teardown
}

test_macos_no_stale_volume_no_rm() {
    log_test "macOS: no pre-existing overlay volume — no volume rm issued"
    _setup
    _IS_MACOS_OVERRIDE="true"
    _PODMAN_VOLUME_EXISTS_RC=1  # volume does not exist

    setup_overlay_sandbox

    assert_not_contains "$_PODMAN_CALLS" "volume rm" \
        "volume rm must not run when no stale volume exists"

    _teardown
}

#===============================================================================
# Test cases — security profile gate (PR #397 review finding 5)
#===============================================================================

test_strict_profile_downgrades_to_kernel_overlay() {
    log_test "macOS: strict profile refuses SYS_ADMIN — downgrades to kernel OverlayFS"
    _setup
    _IS_MACOS_OVERRIDE="true"
    KAPSIS_SECURITY_PROFILE="strict"

    setup_overlay_sandbox

    assert_equals "false" "$KAPSIS_OVERLAY_USE_VOLUME" \
        "strict profile must force KAPSIS_OVERLAY_USE_VOLUME=false"
    assert_equals "" "$OVERLAY_VOLUME" \
        "OVERLAY_VOLUME must stay empty under strict profile"
    assert_dir_exists "$UPPER_DIR" \
        "downgrade must create host UPPER_DIR (kernel OverlayFS fallback)"
    assert_false "overlay_volume_mode_enabled" \
        "overlay_volume_mode_enabled must report false after downgrade"

    _teardown
}

test_paranoid_profile_downgrades_to_kernel_overlay() {
    log_test "macOS: paranoid profile refuses SYS_ADMIN — downgrades to kernel OverlayFS"
    _setup
    _IS_MACOS_OVERRIDE="true"
    KAPSIS_SECURITY_PROFILE="paranoid"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O," \
        "paranoid profile must use the kernel OverlayFS mount, never the named volume"
    assert_not_contains "$mounts" "/overlay" \
        "named overlay volume must NOT be mounted under paranoid profile"

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

    _teardown
}

test_linux_volume_mounts_use_kernel_overlay() {
    log_test "Linux: volume mounts use :O kernel OverlayFS with host upperdir/workdir"
    _setup
    _IS_MACOS_OVERRIDE="false"

    setup_overlay_sandbox
    generate_overlay_project_mounts

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O," \
        "Linux must use kernel OverlayFS :O option"
    assert_contains "$mounts" "upperdir=" \
        "Linux must pass upperdir= host path"
    assert_not_contains "$mounts" ":/lower:ro" \
        "Linux must NOT use /lower read-only mount"

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
        _PODMAN_CALLS+="podman $*"$'\n'
        if [[ "${1:-} ${2:-}" == "volume export" ]]; then
            tar -cf - -C "$fixture" upper work
            return 0
        fi
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

    # Restore the recording stub for subsequent tests
    podman() {
        _PODMAN_CALLS+="podman $*"$'\n'
        case "${1:-} ${2:-}" in
            "volume exists") return "$_PODMAN_VOLUME_EXISTS_RC" ;;
            "volume rm")     return 0 ;;
            "volume export") return 1 ;;
        esac
        return 0
    }
    _teardown
}

test_export_noop_when_volume_mode_disabled() {
    log_test "export: no-op on Linux / when KAPSIS_OVERLAY_USE_VOLUME=false"
    _setup
    _IS_MACOS_OVERRIDE="false"
    OVERLAY_VOLUME="kapsis-${_TEST_AGENT_ID}-overlay"

    export_overlay_volume_to_host

    assert_not_contains "$_PODMAN_CALLS" "volume export" \
        "podman volume export must not run outside the macOS named-volume path"

    _teardown
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
    run_test test_macos_volume_mounts_use_lower_and_overlay
    run_test test_macos_workspace_not_directly_mounted
    run_test test_macos_opt_out_uses_host_dirs
    run_test test_macos_stale_volume_removed_before_launch
    run_test test_macos_no_stale_volume_no_rm
    run_test test_strict_profile_downgrades_to_kernel_overlay
    run_test test_paranoid_profile_downgrades_to_kernel_overlay
    run_test test_standard_profile_keeps_volume_mode
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
