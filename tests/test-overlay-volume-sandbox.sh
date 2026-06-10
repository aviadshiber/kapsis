#!/usr/bin/env bash
# test-overlay-volume-sandbox.sh — Unit tests for Issue #376
#
# Verifies that on macOS, the overlay sandbox uses a Podman named volume
# (VM-native ext4) for upper/work dirs instead of the virtio-fs share,
# and that Linux keeps the existing kernel OverlayFS path unchanged.
#
# Host-tier tests: source the setup/volume-mount functions directly from the
# source tree.  No container is launched.  Container-tier coverage (actual
# fuse-overlayfs mount inside a kapsis-sandbox image) requires Podman + the
# built image and is deferred to a separate PR.
#
# Category: validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"
# Load constants early — KAPSIS_OVERLAY_VOLUME_SUFFIX is readonly after this point
# shellcheck source=../scripts/lib/constants.sh
source "${SCRIPT_DIR}/../scripts/lib/constants.sh" 2>/dev/null || true

#===============================================================================
# Minimal stubs required before sourcing the functions under test
#===============================================================================

_TEST_SANDBOX_BASE="/tmp/kapsis-overlay-test-$$"
_TEST_PROJECT="/tmp/kapsis-overlay-project-$$"
_TEST_AGENT_ID="ovltest$$"

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
}

_teardown() {
    rm -rf "$_TEST_PROJECT" "$_TEST_SANDBOX_BASE" 2>/dev/null || true
    OVERLAY_VOLUME=""
    SANDBOX_DIR=""
    UPPER_DIR=""
    WORK_DIR=""
    VOLUME_MOUNTS=()
    unset KAPSIS_OVERLAY_USE_VOLUME 2>/dev/null || true
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

#===============================================================================
# Functions under test (inlined to avoid sourcing all of launch-agent.sh)
# These are verbatim copies of the changed functions so tests are faithful.
#===============================================================================

setup_overlay_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    local sid="${project_name}-${AGENT_ID}"
    SANDBOX_DIR="${SANDBOX_UPPER_BASE}/${sid}"
    UPPER_DIR="${SANDBOX_DIR}/upper"
    WORK_DIR="${SANDBOX_DIR}/work"

    if is_macos && [[ "${KAPSIS_OVERLAY_USE_VOLUME:-true}" == "true" ]]; then
        OVERLAY_VOLUME="kapsis-${AGENT_ID}${KAPSIS_OVERLAY_VOLUME_SUFFIX}"
        ensure_dir "$SANDBOX_DIR"
    else
        ensure_dir "$UPPER_DIR"
        ensure_dir "$WORK_DIR"
    fi
}

generate_volume_mounts_overlay() {
    VOLUME_MOUNTS=()
    if is_macos && [[ "${KAPSIS_OVERLAY_USE_VOLUME:-true}" == "true" ]]; then
        VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/lower:ro")
        VOLUME_MOUNTS+=("-v" "${OVERLAY_VOLUME}:/overlay")
    else
        VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")
    fi
}

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
    generate_volume_mounts_overlay

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
    generate_volume_mounts_overlay

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

    generate_volume_mounts_overlay

    local mounts="${VOLUME_MOUNTS[*]}"
    assert_contains "$mounts" ":O," \
        "opt-out must fall back to kernel OverlayFS :O mount"
    assert_contains "$mounts" "upperdir=" \
        "opt-out must pass host-side upperdir="

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
    generate_volume_mounts_overlay

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
    run_test test_linux_creates_host_upper_and_work
    run_test test_linux_volume_mounts_use_kernel_overlay
    run_test test_overlay_volume_suffix_constant_defined
    run_test test_overlay_volume_suffix_value

    print_summary
}

main "$@"
