#!/usr/bin/env bash
#===============================================================================
# Test: Disk Space Guard (Fix #191)
#
# Verifies preflight disk space and orphan volume checks:
# - Disk space check passes on normal system
# - Configurable warn/abort thresholds via environment variables
# - Warning message suggests cleanup command
# - Orphan volume check function exists and works
#===============================================================================
# shellcheck disable=SC1090  # Dynamic source paths are intentional in tests
# shellcheck disable=SC2034  # Variables used by sourced functions (check_disk_space)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

PREFLIGHT_SCRIPT="$KAPSIS_ROOT/scripts/preflight-check.sh"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Source preflight script to get access to check functions
load_preflight() {
    # Source logging first (required by preflight)
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"
    log_init "test-disk-space"
    # Source compat (required by disk space check)
    source "$KAPSIS_ROOT/scripts/lib/compat.sh"
    # Source preflight (defines check_disk_space, check_orphan_volumes)
    source "$PREFLIGHT_SCRIPT"
}

#===============================================================================
# TEST CASES
#===============================================================================

test_preflight_has_disk_space_check() {
    log_test "Testing preflight-check.sh has check_disk_space function"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "check_disk_space()" "Should define check_disk_space function"
    assert_contains "$content" "KAPSIS_DISK_WARN_MB" "Should use configurable warn threshold"
    assert_contains "$content" "KAPSIS_DISK_ABORT_MB" "Should use configurable abort threshold"
}

test_disk_space_check_passes_normally() {
    log_test "Testing disk space check passes on normal system"

    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Normal system should have > 512MB free
    check_disk_space

    assert_true "[[ $_PREFLIGHT_ERRORS -eq 0 ]]" "Should not report errors on normal system"
}

test_disk_space_configurable_warn_threshold() {
    log_test "Testing configurable warn threshold triggers warning"

    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Set impossibly high warn threshold to trigger warning
    KAPSIS_DISK_WARN_MB=999999999
    KAPSIS_DISK_ABORT_MB=1  # Keep abort low so we don't error
    check_disk_space || true

    assert_true "[[ $_PREFLIGHT_WARNINGS -gt 0 ]]" "Should produce warning with high threshold"

    # Reset
    unset KAPSIS_DISK_WARN_MB
    unset KAPSIS_DISK_ABORT_MB
}

test_disk_space_configurable_abort_threshold() {
    log_test "Testing configurable abort threshold triggers error"

    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Set impossibly high abort threshold to trigger error
    KAPSIS_DISK_ABORT_MB=999999999
    check_disk_space || true

    assert_true "[[ $_PREFLIGHT_ERRORS -gt 0 ]]" "Should produce error with high abort threshold"

    # Reset
    unset KAPSIS_DISK_ABORT_MB
}

test_disk_space_suggests_cleanup() {
    log_test "Testing disk space messages suggest cleanup command"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "kapsis cleanup --all --volumes --images" \
        "Should suggest cleanup command in error/warning messages"
}

test_preflight_has_orphan_volume_check() {
    log_test "Testing preflight-check.sh has check_orphan_volumes function"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "check_orphan_volumes()" "Should define check_orphan_volumes function"
    assert_contains "$content" "podman volume ls" "Should list podman volumes"
}

test_orphan_volume_check_runs() {
    log_test "Testing orphan volume check executes without error"

    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    # Should not error even if podman is not available
    check_orphan_volumes || true

    assert_true "[[ $_PREFLIGHT_ERRORS -eq 0 ]]" "Orphan check should not produce errors"
}

test_orphan_volume_warns_above_threshold() {
    log_test "Testing orphan volume check warns above threshold of 10"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "orphan_count > 10" "Should use threshold of 10 for warning"
    assert_contains "$content" "kapsis cleanup --volumes" "Should suggest cleanup command"
}

test_disk_space_invoked_in_preflight() {
    log_test "Testing check_disk_space is called in preflight_check"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "check_disk_space || true" \
        "preflight_check should invoke check_disk_space"
}

test_orphan_volumes_invoked_in_preflight() {
    log_test "Testing check_orphan_volumes is called in preflight_check"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "check_orphan_volumes || true" \
        "preflight_check should invoke check_orphan_volumes"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Disk Space Guard (Fix #191)"

    run_test test_preflight_has_disk_space_check
    run_test test_disk_space_check_passes_normally
    run_test test_disk_space_configurable_warn_threshold
    run_test test_disk_space_configurable_abort_threshold
    run_test test_disk_space_suggests_cleanup
    run_test test_preflight_has_orphan_volume_check
    run_test test_orphan_volume_check_runs
    run_test test_orphan_volume_warns_above_threshold
    run_test test_disk_space_invoked_in_preflight
    run_test test_orphan_volumes_invoked_in_preflight

    print_summary
}

main "$@"
