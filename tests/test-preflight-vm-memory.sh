#!/usr/bin/env bash
#===============================================================================
# Test: Preflight VM Memory Advisor (Issue #377)
#
# Verifies that the preflight memory-sizing advisor:
# - Defines all required constants in constants.sh
# - Is a no-op on Linux (no Podman VM to size)
# - Warns when VM memory is below the recommended threshold
# - Warns when VM:host RAM ratio exceeds the jetsam-amplifier threshold
# - Emits BOTH warnings when both conditions hold (no early return)
# - Compares in MiB end-to-end (no GiB truncation at the boundary)
# - Includes the exact `podman machine set --memory` remediation command
# - Respects KAPSIS_MAX_PARALLEL_AGENTS for threshold calculation
# - Logs the resolved max_parallel_agents value and its source (env/config/default)
# - Rejects non-numeric KAPSIS_VM_* overrides before arithmetic (injection guard)
# - Warns when host swap usage is elevated (memory pressure gate)
# - Parses vm.swapusage unit-aware (M suffix only, sub-MB rounds up) and
#   applies an absolute floor before trusting the percentage signal
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

test_constant_vm_swap_floor_mb_defined() {
    log_test "KAPSIS_DEFAULT_VM_SWAP_FLOOR_MB is defined and numeric"

    source "$CONSTANTS_SCRIPT"
    assert_not_empty "${KAPSIS_DEFAULT_VM_SWAP_FLOOR_MB:-}" "VM swap floor constant must be set"
    assert_true "[[ '${KAPSIS_DEFAULT_VM_SWAP_FLOOR_MB}' =~ ^[0-9]+$ ]]" "Must be a positive integer"
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

test_vm_memory_both_checks_warn_together() {
    log_test "Undersized VM that is also oversized for the host emits BOTH warnings"

    local mock_dir
    # VM = 7 GB (7168 MiB); host = 8 GiB; 4 agents → threshold 14GB → Check 1 fires
    # AND 7168/8192 = 87% > 80% → Check 2 fires. Neither may swallow the other.
    mock_dir=$(make_mock_dir 7168 8589934592)

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"
        KAPSIS_MAX_PARALLEL_AGENTS=4

        output=$(check_podman_vm_memory 2>&1 || true)
        [[ "$output" == *"recommended 14336MB"* && "$output" == *"of host RAM"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Both sizing and jetsam warnings must be emitted together"
}

test_vm_memory_mib_boundary_no_truncation() {
    log_test "MiB-precision threshold: 5119 MiB warns, 5120 MiB does not (1-agent / 5GB)"

    local mock_dir_low mock_dir_exact
    mock_dir_low=$(make_mock_dir 5119 34359738368)
    mock_dir_exact=$(make_mock_dir 5120 34359738368)

    local result_low=0 result_exact=0

    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir_low:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        KAPSIS_MAX_PARALLEL_AGENTS=1
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -gt 0 ]]
    ) || result_low=$?

    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir_exact:$PATH"

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        KAPSIS_MAX_PARALLEL_AGENTS=1
        check_podman_vm_memory || true

        [[ $_PREFLIGHT_WARNINGS -eq 0 ]]
    ) || result_exact=$?

    rm -rf "$mock_dir_low" "$mock_dir_exact"
    assert_true "[[ $result_low -eq 0 ]]" "5119 MiB must warn against a 5120 MiB threshold"
    assert_true "[[ $result_exact -eq 0 ]]" "5120 MiB must not warn against a 5120 MiB threshold"
}

test_vm_env_override_injection_guarded() {
    log_test "Non-numeric KAPSIS_VM_* override is rejected before arithmetic (no injection)"

    local mock_dir marker
    # VM = 8 GB; host = 32 GB → with the DEFAULT base (2GB) nothing warns
    mock_dir=$(make_mock_dir 8192 34359738368)
    marker="$mock_dir/pwned"

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        # Hostile value: array subscript with command substitution — executes
        # during bash arithmetic expansion unless regex-guarded first
        export KAPSIS_VM_BASE_MEMORY_GB='x[$(touch '"$marker"')]'
        unset KAPSIS_MAX_PARALLEL_AGENTS

        _PREFLIGHT_ERRORS=0
        _PREFLIGHT_WARNINGS=0
        check_podman_vm_memory || true

        [[ ! -f "$marker" && $_PREFLIGHT_WARNINGS -eq 0 && $_PREFLIGHT_ERRORS -eq 0 ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Hostile override must not execute; default must be used"
}

test_vm_agents_source_logged_env() {
    log_test "Resolved max_parallel_agents and its source are logged (env)"

    local mock_dir
    mock_dir=$(make_mock_dir 8192 34359738368)

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"
        KAPSIS_MAX_PARALLEL_AGENTS=2

        output=$(check_podman_vm_memory 2>&1 || true)
        [[ "$output" == *"source: env KAPSIS_MAX_PARALLEL_AGENTS"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Resolution source 'env' must be logged"
}

test_vm_agents_source_logged_yaml() {
    log_test "vm.max_parallel_agents from YAML is applied and its source logged"

    if ! command -v yq &>/dev/null; then
        echo "  (skipped: yq not installed)"
        return 0
    fi

    local mock_dir cfg
    # VM = 10 GB; YAML asks for 4 agents → threshold 14GB → the warning proves
    # the YAML value (not the default of 1) drove the computation
    mock_dir=$(make_mock_dir 10240 34359738368)
    cfg="$mock_dir/agent-sandbox.yaml"
    printf 'vm:\n  max_parallel_agents: 4\n' > "$cfg"

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"
        unset KAPSIS_MAX_PARALLEL_AGENTS

        output=$(check_podman_vm_memory "$cfg" 2>&1 || true)
        [[ "$output" == *"source: config vm.max_parallel_agents"* \
            && "$output" == *"4 parallel agent(s)"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "YAML value must be applied and its source logged"
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

test_host_memory_pressure_fractional_mb_not_no_swap() {
    log_test "Sub-MB swap (0.50M) is present-but-tiny, not 'No swap configured'"

    local mock_dir
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 0.50M  used = 0.25M  free = 0.25M  (encrypted)")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        output=$(check_host_memory_pressure 2>&1 || true)
        # Rounds up to 1MB → swap IS configured; usage is below the floor
        [[ "$output" != *"No swap configured"* \
            && "$output" != *"Host swap usage"* \
            && "$output" == *"below"*"floor"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "0.50M swap must hit the floor path, not the no-swap path"
}

test_host_memory_pressure_unknown_unit_skipped() {
    log_test "Non-MB unit in vm.swapusage skips the check instead of mis-scaling"

    local mock_dir
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 4.00G  used = 2.00G  free = 2.00G")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        output=$(check_host_memory_pressure 2>&1 || true)
        # The numbers cannot be trusted — no warning AND no verdict
        [[ "$output" != *"Host swap usage"* \
            && "$output" != *"Host memory pressure OK"* \
            && "$output" != *"No swap configured"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "G-suffixed values must skip the check entirely"
}

test_host_memory_pressure_floor_suppresses_tiny_swap() {
    log_test "High percentage of a tiny swap is suppressed by the absolute floor"

    local mock_dir
    # 400MB/600MB = 66% > 50% threshold, but 400MB < 512MB floor → no warning
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 600.00M  used = 400.00M  free = 200.00M")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        output=$(check_host_memory_pressure 2>&1 || true)
        [[ "$output" != *"Host swap usage"* && "$output" == *"below"*"floor"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Sub-floor usage must not trigger the percentage warning"
}

test_host_memory_pressure_threshold_boundary_strict() {
    log_test "Swap exactly at the warn threshold does not warn (strict > comparison)"

    local mock_dir
    # Exactly 50%: 2048/4096 — 'above which' semantics means the boundary is OK
    mock_dir=$(make_mock_dir 8192 34359738368 \
        "vm.swapusage: total = 4096.00M  used = 2048.00M  free = 2048.00M")

    local result=0
    (
        load_preflight
        is_macos() { return 0; }
        PATH="$mock_dir:$PATH"

        output=$(check_host_memory_pressure 2>&1 || true)
        [[ "$output" != *"Host swap usage"* && "$output" == *"swap 50% used"* ]]
    ) || result=$?

    rm -rf "$mock_dir"
    assert_true "[[ $result -eq 0 ]]" "Exactly-at-threshold swap must not warn"
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
    run_test test_constant_vm_swap_floor_mb_defined

    run_test test_vm_memory_check_noop_on_linux
    run_test test_host_memory_pressure_noop_on_linux

    run_test test_vm_memory_warns_below_threshold
    run_test test_vm_memory_warns_jetsam_risk
    run_test test_vm_memory_remediation_contains_podman_set

    run_test test_vm_memory_threshold_scales_with_agents
    run_test test_vm_memory_no_warn_when_sufficient
    run_test test_vm_memory_both_checks_warn_together
    run_test test_vm_memory_mib_boundary_no_truncation
    run_test test_vm_env_override_injection_guarded
    run_test test_vm_agents_source_logged_env
    run_test test_vm_agents_source_logged_yaml

    run_test test_host_memory_pressure_warns_high_swap
    run_test test_host_memory_pressure_ok_low_swap
    run_test test_host_memory_pressure_handles_no_swap
    run_test test_host_memory_pressure_fractional_mb_not_no_swap
    run_test test_host_memory_pressure_unknown_unit_skipped
    run_test test_host_memory_pressure_floor_suppresses_tiny_swap
    run_test test_host_memory_pressure_threshold_boundary_strict
    run_test test_vm_memory_handles_unknown_vm_gracefully

    run_test test_vm_memory_check_wired_into_preflight
    run_test test_host_memory_pressure_wired_into_preflight

    print_summary
}

main "$@"
