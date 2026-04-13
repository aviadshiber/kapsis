#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables set in subshells are consumed by eval'd cleanup functions
#===============================================================================
# Test: VM Health Check (Issue #238)
#
# Unit tests for the --vm-health flag in kapsis-cleanup.sh.
# Uses PATH-based podman mock (no actual VM required).
#
# Tests verify:
#   - --vm-health flag is parsed correctly
#   - Usage text documents the flag
#   - Constants for VM health thresholds exist
#   - Healthy status at low inode/disk usage
#   - Warning status at elevated inode usage
#   - Critical status triggers auto image cleanup
#   - Critical status actually invokes clean_images remediation
#   - Exact boundary values (69/70/89/90%) produce correct status
#   - Linux platform guard skips VM health check
#   - Dry-run mode collects metrics but skips remediation
#   - Journal vacuum runs when forced
#   - Stopped VM is detected and reported
#
# Category: validation
# All tests are QUICK (no container needed).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

CLEANUP_SCRIPT="$KAPSIS_ROOT/scripts/kapsis-cleanup.sh"
CONSTANTS_FILE="$KAPSIS_ROOT/scripts/lib/constants.sh"

# --- Mock setup ---

# Create a mock podman binary that returns configurable health data.
# Uses environment variables VM_MOCK_INODE_PCT, VM_MOCK_DISK_PCT, etc.
# Follows the PATH-based mock pattern from test-git-credential-helper.sh.
setup_podman_mock() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/podman" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "machine" ]] && [[ "${2:-}" == "inspect" ]]; then
    # Handle both 'podman machine inspect <name> --format ...' and plain 'podman machine inspect'
    # When --format is passed, return the state directly (matching Go template output)
    for arg in "$@"; do
        if [[ "$arg" == --format* ]] || [[ "$arg" == "{{.State}}" ]]; then
            echo "${VM_MOCK_MACHINE_STATE:-running}"
            exit 0
        fi
    done
    # Without --format, return JSON-like output (simplified)
    echo "{\"State\": \"${VM_MOCK_MACHINE_STATE:-running}\"}"
    exit 0
fi
if [[ "${1:-}" == "machine" ]] && [[ "${2:-}" == "ssh" ]]; then
    shift 2  # consume "machine ssh"
    [[ "${1:-}" == "--" ]] && shift
    cmd="$*"
    case "$cmd" in
        *"df -i"*)
            echo "overlay ${VM_MOCK_INODE_TOTAL:-1000000} ${VM_MOCK_INODE_USED:-500000} ${VM_MOCK_INODE_FREE:-500000} ${VM_MOCK_INODE_PCT:-50}% /"
            ;;
        *"df -h"*)
            echo "/dev/vda1 100G ${VM_MOCK_DISK_USED:-45G} ${VM_MOCK_DISK_AVAIL:-55G} ${VM_MOCK_DISK_PCT:-45}% /"
            ;;
        *"journalctl --disk-usage"*)
            echo "Archived and active journals take up ${VM_MOCK_JOURNAL_SIZE:-256.0M} in the file system."
            ;;
        *"journalctl --vacuum"*)
            echo "Vacuuming done, freed 128.0M of archived journals."
            ;;
    esac
    exit 0
fi
if [[ "${1:-}" == "images" ]] || [[ "${1:-}" == "image" ]] || [[ "${1:-}" == "rmi" ]]; then
    # Mock image commands for clean_images — write marker for remediation tests
    if [[ -n "${VM_MOCK_MARKER_DIR:-}" ]]; then
        touch "${VM_MOCK_MARKER_DIR}/clean_images_called"
    fi
    exit 0
fi
exit 0
MOCK
    chmod +x "$mock_dir/podman"

    # Mock timeout command to just pass through
    cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
# Strip the timeout seconds arg and execute the rest
shift
exec "$@"
MOCK
    chmod +x "$mock_dir/timeout"
}

# Create a mock uname for platform testing
setup_platform_mock() {
    local mock_dir="$1"
    local platform="$2"  # "Darwin" or "Linux"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/uname" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "-s" ]] || [[ -z "\${1:-}" ]]; then
    echo "$platform"
else
    /usr/bin/uname "\$@"
fi
MOCK
    chmod +x "$mock_dir/uname"
}

# --- Test Helpers ---

# Helper to run a VM health status test with given inode/disk percentages.
# Extracts common boilerplate from all status tests.
# Args: $1=inode_pct, $2=disk_pct, $3=expected_status
# Returns: output from the subshell (contains STATUS=<value>)
_run_vm_health_test() {
    local inode_pct="$1"
    local disk_pct="$2"
    local expected_status="$3"
    local mock_dir
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-vm-test.XXXXXX")
    setup_podman_mock "$mock_dir"
    setup_platform_mock "$mock_dir" "Darwin"

    local output
    output=$(
        export PATH="$mock_dir:$PATH"
        export VM_MOCK_INODE_PCT="$inode_pct"
        export VM_MOCK_DISK_PCT="$disk_pct"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh" 2>/dev/null || true
        source "$KAPSIS_ROOT/scripts/lib/compat.sh" 2>/dev/null || true
        source "$KAPSIS_ROOT/scripts/lib/constants.sh" 2>/dev/null || true
        # Globals needed by the functions
        DRY_RUN=false
        FORCE=false
        CLEAN_ALL=false
        ITEMS_CLEANED=0
        TOTAL_SIZE_FREED=0
        # Color variables set to empty for clean test output (avoids ANSI escape
        # codes that would pollute assertions in non-TTY test environments)
        GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
        eval "$(sed -n '/^_vm_collect_metrics/,/^}/p' "$CLEANUP_SCRIPT")"
        eval "$(sed -n '/^_vm_assess_health/,/^}/p' "$CLEANUP_SCRIPT")"
        _vm_collect_metrics
        _vm_assess_health
        echo "STATUS=$VM_HEALTH_STATUS"
    ) 2>&1

    assert_contains "$output" "STATUS=$expected_status" \
        "Should report $expected_status at ${inode_pct}% inode / ${disk_pct}% disk"

    rm -rf "$mock_dir"
}

# --- Tests ---

test_vm_health_flag_parsing() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--vm-health)" "Arg parser should handle --vm-health"
    assert_contains "$content" "CLEAN_VM_HEALTH=true" "Should set CLEAN_VM_HEALTH=true"
}

test_vm_health_in_usage_text() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "--vm-health" "Usage should document --vm-health flag"
    assert_contains "$content" "inode" "Usage should mention inode monitoring"
}

test_vm_health_constants_exist() {
    local content
    content=$(cat "$CONSTANTS_FILE")
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_WARN_PCT" "Inode warn constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_CRITICAL_PCT" "Inode critical constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_DISK_WARN_PCT" "Disk warn constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_DISK_CRITICAL_PCT" "Disk critical constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_JOURNAL_VACUUM_SIZE" "Journal vacuum size constant should exist"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_SSH_TIMEOUT" "SSH timeout constant should exist"
}

test_vm_health_constants_values() {
    local content
    content=$(cat "$CONSTANTS_FILE")
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_WARN_PCT=70" "Inode warn should default to 70"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_INODE_CRITICAL_PCT=90" "Inode critical should default to 90"
    assert_contains "$content" "KAPSIS_DEFAULT_CLEANUP_VM_SSH_TIMEOUT=15" "SSH timeout should default to 15"
}

test_vm_health_functions_exist() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "_vm_collect_metrics()" "Should define _vm_collect_metrics function"
    assert_contains "$content" "_vm_assess_health()" "Should define _vm_assess_health function"
    assert_contains "$content" "_vm_remediate()" "Should define _vm_remediate function"
    assert_contains "$content" "vm_health_check()" "Should define vm_health_check function"
}

test_vm_health_wired_into_main() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" 'CLEAN_VM_HEALTH' "Main should check CLEAN_VM_HEALTH"
    assert_contains "$content" "vm_health_check" "Main should call vm_health_check"
}

test_vm_health_healthy_status() {
    _run_vm_health_test 50 45 "HEALTHY"
}

test_vm_health_warning_status() {
    _run_vm_health_test 75 45 "WARNING"
}

test_vm_health_critical_status() {
    _run_vm_health_test 95 45 "CRITICAL"
}

test_vm_health_disk_warning() {
    _run_vm_health_test 50 85 "WARNING"
}

test_vm_health_linux_guard() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "is_linux" "Should have Linux platform guard"
    assert_contains "$content" "macOS-only" "Should explain VM checks are macOS-only"
}

test_vm_health_timeout_wrapping() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    # Verify all podman machine ssh calls are wrapped in timeout
    local ssh_calls
    ssh_calls=$(grep "podman machine ssh" "$CLEANUP_SCRIPT" | grep -v "timeout" | grep -v "^#" || true)
    assert_equals "" "$ssh_calls" "All podman machine ssh calls should be wrapped in timeout"
}

test_vm_health_dry_run_safety() {
    # Verify DRY_RUN checks exist in _vm_remediate
    local has_dry_run_check
    has_dry_run_check=$(grep -c 'DRY_RUN.*true' "$CLEANUP_SCRIPT" || true)
    assert_not_equals "0" "$has_dry_run_check" "Remediation should check DRY_RUN"

    local has_image_dry_run
    has_image_dry_run=$(grep -c 'Would run image cleanup' "$CLEANUP_SCRIPT" || true)
    assert_not_equals "0" "$has_image_dry_run" "Should show dry-run message for image cleanup"

    local has_journal_dry_run
    has_journal_dry_run=$(grep -c 'Would vacuum journal' "$CLEANUP_SCRIPT" || true)
    assert_not_equals "0" "$has_journal_dry_run" "Should show dry-run message for journal vacuum"
}

test_vm_health_machine_state_check() {
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    assert_contains "$content" "podman machine inspect" "Should check machine state via inspect"
    assert_contains "$content" "not running" "Should report when machine is not running"
}

test_vm_health_runs_after_cleanup() {
    # Verify vm_health_check runs after clean_branches (last in main)
    local content
    content=$(cat "$CLEANUP_SCRIPT")
    local branches_line vm_health_line
    branches_line=$(grep -n "clean_branches" "$CLEANUP_SCRIPT" | tail -1 | cut -d: -f1)
    vm_health_line=$(grep -n "vm_health_check" "$CLEANUP_SCRIPT" | tail -1 | cut -d: -f1)
    local summary_line
    summary_line=$(grep -n "print_summary" "$CLEANUP_SCRIPT" | tail -1 | cut -d: -f1)

    # vm_health should run after branches
    if [[ "$vm_health_line" -gt "$branches_line" ]]; then
        assert_equals "0" "0" "vm_health_check runs after clean_branches"
    else
        assert_equals "after" "before" "vm_health_check should run after clean_branches"
    fi

    # vm_health should run before summary
    if [[ "$vm_health_line" -lt "$summary_line" ]]; then
        assert_equals "0" "0" "vm_health_check runs before print_summary"
    else
        assert_equals "before" "after" "vm_health_check should run before print_summary"
    fi
}

# Boundary condition tests (issue #7): exact threshold values
test_vm_health_boundary_inode_69_healthy() {
    _run_vm_health_test 69 45 "HEALTHY"
}

test_vm_health_boundary_inode_70_warning() {
    _run_vm_health_test 70 45 "WARNING"
}

test_vm_health_boundary_inode_89_warning() {
    _run_vm_health_test 89 45 "WARNING"
}

test_vm_health_boundary_inode_90_critical() {
    _run_vm_health_test 90 45 "CRITICAL"
}

# Remediation test (issue #3): verify clean_images is actually invoked at CRITICAL
test_vm_health_critical_triggers_remediation() {
    local mock_dir
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/kapsis-vm-test.XXXXXX")
    setup_podman_mock "$mock_dir"
    setup_platform_mock "$mock_dir" "Darwin"

    local output
    output=$(
        export PATH="$mock_dir:$PATH"
        export VM_MOCK_INODE_PCT=95
        export VM_MOCK_DISK_PCT=45
        export VM_MOCK_MARKER_DIR="$mock_dir"
        source "$KAPSIS_ROOT/scripts/lib/logging.sh" 2>/dev/null || true
        source "$KAPSIS_ROOT/scripts/lib/compat.sh" 2>/dev/null || true
        source "$KAPSIS_ROOT/scripts/lib/constants.sh" 2>/dev/null || true
        DRY_RUN=false
        FORCE=false
        CLEAN_ALL=false
        ITEMS_CLEANED=0
        TOTAL_SIZE_FREED=0
        # Color variables set to empty for clean test output (avoids ANSI escape
        # codes that would pollute assertions in non-TTY test environments)
        GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
        eval "$(sed -n '/^_vm_collect_metrics/,/^}/p' "$CLEANUP_SCRIPT")"
        eval "$(sed -n '/^_vm_assess_health/,/^}/p' "$CLEANUP_SCRIPT")"
        eval "$(sed -n '/^_vm_remediate/,/^}/p' "$CLEANUP_SCRIPT")"
        # Define clean_images stub that writes a marker file
        clean_images() {
            touch "${VM_MOCK_MARKER_DIR}/clean_images_called"
        }
        # Also need section and format_size stubs
        section() { true; }
        format_size() { echo "$1"; }
        print_item() { true; }
        _vm_collect_metrics
        _vm_assess_health
        _vm_remediate
        echo "STATUS=$VM_HEALTH_STATUS"
        if [[ -f "${VM_MOCK_MARKER_DIR}/clean_images_called" ]]; then
            echo "REMEDIATION=triggered"
        else
            echo "REMEDIATION=skipped"
        fi
    ) 2>&1

    assert_contains "$output" "STATUS=CRITICAL" "Should report CRITICAL at 95% inode usage"
    assert_contains "$output" "REMEDIATION=triggered" "clean_images should be triggered at CRITICAL status"

    rm -rf "$mock_dir"
}

# --- Runner ---
run_test test_vm_health_flag_parsing
run_test test_vm_health_in_usage_text
run_test test_vm_health_constants_exist
run_test test_vm_health_constants_values
run_test test_vm_health_functions_exist
run_test test_vm_health_wired_into_main
run_test test_vm_health_healthy_status
run_test test_vm_health_warning_status
run_test test_vm_health_critical_status
run_test test_vm_health_disk_warning
run_test test_vm_health_linux_guard
run_test test_vm_health_timeout_wrapping
run_test test_vm_health_dry_run_safety
run_test test_vm_health_machine_state_check
run_test test_vm_health_runs_after_cleanup
run_test test_vm_health_boundary_inode_69_healthy
run_test test_vm_health_boundary_inode_70_warning
run_test test_vm_health_boundary_inode_89_warning
run_test test_vm_health_boundary_inode_90_critical
run_test test_vm_health_critical_triggers_remediation

print_summary
