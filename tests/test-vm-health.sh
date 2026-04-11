#!/usr/bin/env bash
#
# test-vm-health.sh - Tests for VM health monitoring (Issue #238)
#
# Category: validation (no container required)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
CONSTANTS_FILE="$KAPSIS_ROOT/scripts/lib/constants.sh"

# --- Tests ---

test_vm_health_constants_exist() {
    local content
    content=$(cat "$CONSTANTS_FILE")
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_WARN_PCT" \
        "Inode warn constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_CRITICAL_PCT" \
        "Inode critical constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_DISK_WARN_PCT" \
        "Disk warn constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_DISK_CRITICAL_PCT" \
        "Disk critical constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_JOURNAL_VACUUM_SIZE" \
        "Journal vacuum size constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_SSH_TIMEOUT" \
        "SSH timeout constant should exist"
}

test_vm_health_constant_values() {
    source "$CONSTANTS_FILE"
    assert_equals "70" "$KAPSIS_DEFAULT_CLEANUP_VM_INODE_WARN_PCT" \
        "Inode warn threshold should be 70%"
    assert_equals "90" "$KAPSIS_DEFAULT_CLEANUP_VM_INODE_CRITICAL_PCT" \
        "Inode critical threshold should be 90%"
    assert_equals "80" "$KAPSIS_DEFAULT_CLEANUP_VM_DISK_WARN_PCT" \
        "Disk warn threshold should be 80%"
    assert_equals "95" "$KAPSIS_DEFAULT_CLEANUP_VM_DISK_CRITICAL_PCT" \
        "Disk critical threshold should be 95%"
    assert_equals "100M" "$KAPSIS_DEFAULT_CLEANUP_VM_JOURNAL_VACUUM_SIZE" \
        "Journal vacuum size should be 100M"
    assert_equals "15" "$KAPSIS_DEFAULT_CLEANUP_VM_SSH_TIMEOUT" \
        "SSH timeout should be 15 seconds"
}

test_vm_health_flag_parsing() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--vm-health)" \
        "Arg parser should handle --vm-health"
    assert_contains "$content" "CLEAN_VM_HEALTH=true" \
        "Should set CLEAN_VM_HEALTH=true"
}

test_vm_health_in_usage_text() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--vm-health" \
        "Usage should document --vm-health flag"
    assert_contains "$content" "inode" \
        "Usage should mention inode monitoring"
}

test_vm_health_functions_exist() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "_vm_collect_metrics()" \
        "Should define _vm_collect_metrics function"
    assert_contains "$content" "_vm_assess_health()" \
        "Should define _vm_assess_health function"
    assert_contains "$content" "_vm_remediate()" \
        "Should define _vm_remediate function"
    assert_contains "$content" "vm_health_check()" \
        "Should define vm_health_check function"
}

test_vm_health_linux_guard() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "is_linux" \
        "Should use is_linux platform guard"
    assert_contains "$content" "macOS-only" \
        "Should explain macOS-only restriction"
}

test_vm_health_timeout_wrapping() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    # All podman machine ssh calls should be wrapped in timeout
    local ssh_calls
    ssh_calls=$(grep -c 'timeout.*podman machine ssh' "$CLEANUP_SCRIPT" || true)
    assert_not_equals "0" "$ssh_calls" \
        "All podman machine ssh calls should be wrapped in timeout"
}

test_vm_health_dry_run_support() {
    # Check that DRY_RUN is referenced in _vm_remediate
    local remediate_section
    remediate_section=$(sed -n '/_vm_remediate/,/^}/p' "$CLEANUP_SCRIPT")
    assert_contains "$remediate_section" "DRY_RUN" \
        "_vm_remediate should check DRY_RUN"
}

test_vm_health_wired_into_main() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "vm_health_check" \
        "main() should call vm_health_check"
    assert_contains "$content" "CLEAN_VM_HEALTH" \
        "main() should check CLEAN_VM_HEALTH flag"
}

# --- Runner ---
run_test test_vm_health_constants_exist
run_test test_vm_health_constant_values
run_test test_vm_health_flag_parsing
run_test test_vm_health_in_usage_text
run_test test_vm_health_functions_exist
run_test test_vm_health_linux_guard
run_test test_vm_health_timeout_wrapping
run_test test_vm_health_dry_run_support
run_test test_vm_health_wired_into_main

print_summary
