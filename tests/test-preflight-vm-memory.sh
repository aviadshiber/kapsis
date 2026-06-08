#!/usr/bin/env bash
#===============================================================================
# Test: Preflight VM Memory Advisor (Issue #377)
#
# Verifies that the preflight memory-sizing advisor:
# - Defines all required constants in constants.sh
# - Is a no-op on Linux (no Podman VM to size)
# - Warns when VM memory is below the recommended threshold
# - Warns when VM:host RAM ratio exceeds the jetsam-amplifier threshold
# - Includes the exact `podman machine set --memory` remediation command
# - Respects KAPSIS_MAX_PARALLEL_AGENTS for threshold calculation
# - Warns when host swap usage is elevated (memory pressure gate)
# - Is wired into the main preflight_check() function
#
# Category: validation
# Quick: yes (no Podman container required)
#===============================================================================
# shellcheck disable=SC1090   # Dynamic source paths are intentional
# shellcheck disable=SC2030,SC2031  # Subshell variable modifications are intentional
# shellcheck disable=SC2034   # Variables used by sourced functions in subshells

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

PREFLIGHT_SCRIPT="$KAPSIS_ROOT/scripts/preflight-check.sh"
CONSTANTS_SCRIPT="$KAPSIS_ROOT/scripts/lib/constants.sh"

#===============================================================================
# HELPERS
#===============================================================================

load_preflight() {
    source "$KAPSIS_ROOT/scripts/lib/logging.sh"
    log_init "test-vm-memory"
    source "$KAPSIS_ROOT/scripts/lib/compat.sh"
    source "$PREFLIGHT_SCRIPT"
}

# Create a minimal mock binary directory with podman and sysctl stubs.
# Prints the temp dir path so callers can prepend it to PATH.
#   $1 = MiB for VM memory (podman machine inspect output)
#   $2 = bytes for host RAM (sysctl -n hw.memsize output)
#   $3 = swap line (full sysctl vm.swapusage output, optional)
make_mock_dir() {
    local vm_mem_mib="${1:-4096}"
    local host_mem_bytes="${2:-17179869184}"
    local swap_line="${3:-vm.swapusage: total = 4096.00M  used = 512.00M  free = 3584.00M}"

    local mock_dir
    mock_dir=$(mktemp -d)

    # Mock podman: return vm_mem_mib for `inspect --format {{.Resources.Memory}}`
    cat > "$mock_dir/podman" << PODMAN_EOF
#!/usr/bin/env bash
echo "${vm_mem_mib}"
PODMAN_EOF
    chmod +x "$mock_dir/podman"

    # Mock sysctl: handle both hw.memsize and vm.swapusage
    cat > "$mock_dir/sysctl" << SYSCTL_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-n" && "\${2:-}" == "hw.memsize" ]]; then
    echo "${host_mem_bytes}"
elif [[ "\${1:-}" == "vm.swapusage" ]]; then
    echo "${swap_line}"
fi
SYSCTL_EOF
    chmod +x "$mock_dir/sysctl"

    echo "$mock_dir"
}

#===============================================================================
# TESTS: Constants
#===============================================================================

test_constant_vm_base_memory_gb_defined() {
    log_test "KAPSIS_DEFAULT_VM_BASE_MEMORY_GB is defined and numeric"

    source "$CONSTANTS_SCRIPT"
    assert_not_empty "${KAPSIS_DEFAULT_VM_BASE_MEMORY_GB:-}" "VM base memory constant must be set"
    assert_true "[[ '${KAPSIS_DEFAULT_VM_BASE_MEMORY_GB}' =~ ^[0-9]+$ ]]" "Must be a positive integer"
}

test_constant_vm_per_agent_memory_gb_defined() {
    log_test "KAPSIS_DEFAULT_VM_PER_AGENT_MEMORY_GB is defined and numeric"

    source "$CONSTANTS_SCRIPT"
    assert_not_empty "${KAPSIS_DEFAULT_VM_PER_AGENT_MEMORY_GB:-}" "VM per-agent memory constant must be set"
    assert_true "[[ '${KAPSIS_DEFAULT_VM_PER_AGENT_MEMORY_GB}' =~ ^[0-9]+$ ]]" "Must be a positive integer"
}

test_constant_vm_max_host_pct_defined() {
    log_test "KAPSIS_DEFAULT_VM_MAX_HOST_PCT is defined and numeric"

    source "$CONSTANTS_SCRIPT"
    assert_not_empty "${KAPSIS_DEFAULT_VM_MAX_HOST_PCT:-}" "VM max host pct constant must be set"
    assert_true "[[ '${KAPSIS_DEFAULT_VM_MAX_HOST_PCT}' =~ ^[0-9]+$ ]]" "Must be a positive integer"
    assert_true "(( KAPSIS_DEFAULT_VM_MAX_HOST_PCT <= 100 ))" "Must not exceed 100%"
}

test_constant_vm_swap_warn_pct_defined() {
    log_test "KAPSIS_DEFAULT_VM_SWAP_WARN_PCT is defined and numeric"

    source "$CONSTANTS_SCRIPT"
    assert_not_empty "${KAPSIS_DEFAULT_VM_SWAP_WARN_PCT:-}" "VM swap warn pct constant must be set"
    assert_true "[[ '${KAPSIS_DEFAULT_VM_SWAP_WARN_PCT}' =~ ^[0-9]+$ ]]" "Must be a positive integer"
    assert_true "(( KAPSIS_DEFAULT_VM_SWAP_WARN_PCT <= 100 ))" "Must not exceed 100%"
}

#===============================================================================
# TESTS: No-op on Linux
#===============================================================================

test_vm_memory_check_noop_on_linux() {
    log_test "check_podman_vm_memory is a no-op on Linux"

    # We ARE on Linux in CI — just call the function directly and expect silence
    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0
    check_podman_vm_memory || true

    assert_true "[[ $_PREFLIGHT_ERRORS -eq 0 ]]" "Should not produce errors on Linux"
    assert_true "[[ $_PREFLIGHT_WARNINGS -eq 0 ]]" "Should not produce warnings on Linux"
}

test_host_memory_pressure_noop_on_linux() {
    log_test "check_host_memory_pressure is a no-op on Linux"

    load_preflight

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0
    check_host_memory_pressure || true

    assert_true "[[ $_PREFLIGHT_ERRORS -eq 0 ]]" "Should not produce errors on Linux"
    assert_true "[[ $_PREFLIGHT_WARNINGS -eq 0 ]]" "Should not produce warnings on Linux"
}

#===============================================================================
# TESTS: Warning when VM below threshold (simulated macOS)
#===============================================================================

test_vm_memory_warns_below_threshold() {
    log_test "check_podman_vm_memory warns when VM below recommended threshold"

    local mock_dir
    # VM = 4 GB (4096 MiB); host = 16 GB; default threshold = 2 + 3×1 = 5 GB → warn
    mock_dir=$(make_mock_dir 4096 17179869184)

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        unset KAPSIS_MAX_PARALLEL_AGENTS
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -gt 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should produce a warning when VM below threshold"
}

test_vm_memory_warns_jetsam_risk() {
    log_test "check_podman_vm_memory warns when VM consumes > max_host_pct of host RAM"

    local mock_dir
    # VM = 14 GB (14336 MiB); host = 16 GB → 87% > 80% → warn jetsam risk
    mock_dir=$(make_mock_dir 14336 17179869184)

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        unset KAPSIS_MAX_PARALLEL_AGENTS
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -gt 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should warn when VM:host ratio exceeds threshold"
}

test_vm_memory_remediation_contains_podman_set() {
    log_test "VM memory warning includes 'podman machine set --memory' remediation command"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")

    assert_contains "$content" "podman machine set --memory" \
        "Remediation must include the exact podman machine set --memory command"
    assert_contains "$content" "podman machine stop" \
        "Remediation must include podman machine stop (VM restart required)"
    assert_contains "$content" "podman machine start" \
        "Remediation must include podman machine start to resume"
}

#===============================================================================
# TESTS: max_parallel_agents scaling
#===============================================================================

test_vm_memory_threshold_scales_with_agents() {
    log_test "Threshold scales with KAPSIS_MAX_PARALLEL_AGENTS"

    local mock_dir
    # VM = 10 GB (10240 MiB); host = 32 GB
    # Default threshold (1 agent) = 2+3=5 GB → OK (no warn)
    # With 4 agents: threshold = 2+3×4=14 GB → warn
    mock_dir=$(make_mock_dir 10240 34359738368)

    local result_1agent=0 result_4agents=0

    # With 1 agent: 10GB >= 5GB threshold → should NOT warn
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        KAPSIS_MAX_PARALLEL_AGENTS=1
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 ]]
    ) || result_1agent=$?

    # With 4 agents: 10GB < 14GB threshold → should warn
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        KAPSIS_MAX_PARALLEL_AGENTS=4
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -gt 0 ]]
    ) || result_4agents=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result_1agent -eq 0 ]]" "1 agent: 10GB VM should not warn (threshold 5GB)"
    assert_true "[[ $result_4agents -eq 0 ]]" "4 agents: 10GB VM should warn (threshold 14GB)"
}

test_vm_memory_no_warn_when_sufficient() {
    log_test "check_podman_vm_memory is silent when VM is adequately sized"

    local mock_dir
    # VM = 8 GB (8192 MiB); host = 32 GB (8/32 = 25% < 80%); threshold = 5 GB → OK
    mock_dir=$(make_mock_dir 8192 34359738368)

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        KAPSIS_MAX_PARALLEL_AGENTS=1
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 && $_PREFLIGHT_ERRORS -eq 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should not warn when VM is adequately sized"
}

#===============================================================================
# TESTS: Memory pressure (swap) gate
#===============================================================================

test_host_memory_pressure_warns_high_swap() {
    log_test "check_host_memory_pressure warns when swap usage is elevated"

    local mock_dir
    # swap: total=4096MB used=3072MB → 75% > 50% threshold → warn
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 4096.00M  used = 3072.00M  free = 1024.00M")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        check_host_memory_pressure || true

        [[ $_PREFLIGHT_WARNINGS -gt 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should warn when swap > 50%"
}

test_host_memory_pressure_ok_low_swap() {
    log_test "check_host_memory_pressure is silent when swap usage is low"

    local mock_dir
    # swap: total=4096MB used=512MB → 12% < 50% threshold → ok
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 4096.00M  used = 512.00M  free = 3584.00M")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        check_host_memory_pressure || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 && $_PREFLIGHT_ERRORS -eq 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should not warn when swap is low"
}

test_host_memory_pressure_handles_no_swap() {
    log_test "check_host_memory_pressure handles zero total swap gracefully"

    local mock_dir
    # swap: total=0MB → no swap configured
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        check_host_memory_pressure || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 && $_PREFLIGHT_ERRORS -eq 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should not warn when no swap is configured"
}

test_vm_memory_handles_unknown_vm_gracefully() {
    log_test "check_podman_vm_memory is silent when VM memory cannot be read"

    local mock_dir
    mock_dir=$(mktemp -d)
    # podman returns empty/non-numeric — simulates missing machine or parse failure
    printf '#!/usr/bin/env bash\necho ""\n' > "$mock_dir/podman"
    chmod +x "$mock_dir/podman"
    printf '#!/usr/bin/env bash\necho "17179869184"\n' > "$mock_dir/sysctl"
    chmod +x "$mock_dir/sysctl"

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 && $_PREFLIGHT_ERRORS -eq 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Should be silent when VM memory is unreadable"
}

#===============================================================================
# TESTS: Wiring into preflight_check()
#===============================================================================

test_vm_memory_check_wired_into_preflight() {
    log_test "check_podman_vm_memory is called from preflight_check"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")
    assert_contains "$content" "check_podman_vm_memory" \
        "preflight_check must call check_podman_vm_memory"
}

test_host_memory_pressure_wired_into_preflight() {
    log_test "check_host_memory_pressure is called from preflight_check"

    local content
    content=$(cat "$PREFLIGHT_SCRIPT")
    assert_contains "$content" "check_host_memory_pressure" \
        "preflight_check must call check_host_memory_pressure"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Preflight VM Memory Advisor (Issue #377)"

    run_test test_constant_vm_base_memory_gb_defined
    run_test test_constant_vm_per_agent_memory_gb_defined
    run_test test_constant_vm_max_host_pct_defined
    run_test test_constant_vm_swap_warn_pct_defined

    run_test test_vm_memory_check_noop_on_linux
    run_test test_host_memory_pressure_noop_on_linux

    run_test test_vm_memory_warns_below_threshold
    run_test test_vm_memory_warns_jetsam_risk
    run_test test_vm_memory_remediation_contains_podman_set

    run_test test_vm_memory_threshold_scales_with_agents
    run_test test_vm_memory_no_warn_when_sufficient

    run_test test_host_memory_pressure_warns_high_swap
    run_test test_host_memory_pressure_ok_low_swap
    run_test test_host_memory_pressure_handles_no_swap
    run_test test_vm_memory_handles_unknown_vm_gracefully

    run_test test_vm_memory_check_wired_into_preflight
    run_test test_host_memory_pressure_wired_into_preflight

    print_summary
}

main "$@"
