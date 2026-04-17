#!/usr/bin/env bash
#===============================================================================
# Test: Liveness Monitor
#
# Tests liveness monitoring configuration, I/O parsing, staleness detection,
# heartbeat writing, config validation, and health command output.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Create a mock /proc/1/io file for testing
create_mock_proc_io() {
    local dir="$1"
    local read_bytes="${2:-12345}"
    local write_bytes="${3:-67890}"
    mkdir -p "$dir"
    cat > "$dir/io" << EOF
rchar: 100000
wchar: 200000
syscr: 500
syscw: 300
read_bytes: $read_bytes
write_bytes: $write_bytes
cancelled_write_bytes: 0
EOF
}

#===============================================================================
# UNIT TESTS: liveness-monitor.sh functions
#===============================================================================

test_liveness_monitor_sources_cleanly() {
    log_test "Testing liveness monitor sources without errors"

    # Source in a subshell to avoid polluting test environment
    local exit_code=0
    (
        export KAPSIS_LIVENESS_ENABLED=false
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Should source cleanly"
}

test_liveness_source_guard() {
    log_test "Testing source guard prevents double-sourcing"

    local exit_code=0
    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        # Second source should be a no-op
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
    ) 2>/dev/null || exit_code=$?

    assert_equals 0 "$exit_code" "Double-sourcing should not error"
}

test_liveness_io_parsing() {
    log_test "Testing /proc/1/io parsing"

    local tmpdir
    tmpdir=$(mktemp -d)
    create_mock_proc_io "$tmpdir/1" 12345 67890

    # Parse using the same awk command the monitor uses
    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "$tmpdir/1/io" 2>/dev/null || echo "0")

    assert_equals "80235" "$io_total" "Should sum read_bytes + write_bytes"

    rm -rf "$tmpdir"
}

test_liveness_io_parsing_missing_file() {
    log_test "Testing I/O parsing when /proc/1/io is missing"

    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "/nonexistent/io" 2>/dev/null || echo "0")

    assert_equals "0" "$io_total" "Should return 0 when file is missing"
}

test_liveness_io_parsing_zero_bytes() {
    log_test "Testing I/O parsing with zero bytes"

    local tmpdir
    tmpdir=$(mktemp -d)
    create_mock_proc_io "$tmpdir/1" 0 0

    local io_total
    io_total=$(awk '/^(read|write)_bytes:/ {s+=$2} END {print s+0}' "$tmpdir/1/io" 2>/dev/null || echo "0")

    assert_equals "0" "$io_total" "Should return 0 for zero bytes"

    rm -rf "$tmpdir"
}

test_liveness_config_defaults() {
    log_test "Testing liveness config defaults"

    (
        # Clear any existing env vars
        unset KAPSIS_LIVENESS_TIMEOUT KAPSIS_LIVENESS_GRACE_PERIOD KAPSIS_LIVENESS_CHECK_INTERVAL
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Check defaults are set correctly
        [[ "$_LIVENESS_TIMEOUT" == "1800" ]] || exit 1
        [[ "$_LIVENESS_GRACE" == "300" ]] || exit 2
        [[ "$_LIVENESS_INTERVAL" == "30" ]] || exit 3
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should have correct defaults (1800/300/30)"
}

test_liveness_config_custom_values() {
    log_test "Testing liveness config with custom values"

    (
        export KAPSIS_LIVENESS_TIMEOUT=900
        export KAPSIS_LIVENESS_GRACE_PERIOD=60
        export KAPSIS_LIVENESS_CHECK_INTERVAL=15
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_LIVENESS_TIMEOUT" == "900" ]] || exit 1
        [[ "$_LIVENESS_GRACE" == "60" ]] || exit 2
        [[ "$_LIVENESS_INTERVAL" == "15" ]] || exit 3
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should accept custom values (900/60/15)"
}

test_liveness_heartbeat_in_status() {
    log_test "Testing heartbeat_at field appears in status.json"

    (
        export KAPSIS_STATUS_DIR
        KAPSIS_STATUS_DIR=$(mktemp -d)
        export KAPSIS_STATUS_ENABLED=true
        source "$KAPSIS_ROOT/scripts/lib/status.sh"
        status_init "test-project" "test-1" "main" "overlay"

        # Set heartbeat
        status_set_heartbeat
        status_phase "running" 50 "Testing"

        # Use _KAPSIS_STATUS_FILE (set by status_init) so the test works in containers
        # where _status_get_dir() overrides KAPSIS_STATUS_DIR with /kapsis-status.
        local status_file="$_KAPSIS_STATUS_FILE"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at"' "$status_file" || exit 1
            # Should not be null
            local hb
            hb=$(grep '"heartbeat_at"' "$status_file")
            [[ "$hb" != *"null"* ]] || exit 2
        else
            exit 3
        fi

        rm -f "$status_file"
        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "heartbeat_at should appear in status.json and not be null"
}

test_liveness_heartbeat_null_when_unset() {
    log_test "Testing heartbeat_at is null when not set"

    (
        export KAPSIS_STATUS_DIR
        KAPSIS_STATUS_DIR=$(mktemp -d)
        export KAPSIS_STATUS_ENABLED=true
        source "$KAPSIS_ROOT/scripts/lib/status.sh"
        status_init "test-project" "test-2" "main" "overlay"
        status_phase "running" 25 "Starting"

        # Use _KAPSIS_STATUS_FILE (set by status_init) so the test works in containers
        # where _status_get_dir() overrides KAPSIS_STATUS_DIR with /kapsis-status.
        local status_file="$_KAPSIS_STATUS_FILE"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at": null' "$status_file" || exit 1
        else
            exit 2
        fi

        rm -f "$status_file"
        rm -rf "$KAPSIS_STATUS_DIR"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "heartbeat_at should be null when not set"
}

#===============================================================================
# UNIT TESTS: API connection signal — hex conversion
#===============================================================================

test_liveness_ip4_to_proc_hex() {
    log_test "Testing IPv4 to /proc/net/tcp little-endian hex conversion"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        hex=$(_liveness_ip4_to_proc_hex "1.2.3.4")
        [[ "$hex" == "04030201" ]] || { echo "1.2.3.4 expected 04030201, got $hex"; exit 1; }

        hex=$(_liveness_ip4_to_proc_hex "127.0.0.1")
        [[ "$hex" == "0100007F" ]] || { echo "127.0.0.1 expected 0100007F, got $hex"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "IPv4 hex conversion should work: $err"
}

test_liveness_ip6_to_proc_hex() {
    log_test "Testing IPv6 to /proc/net/tcp6 little-endian hex conversion"

    # Only run if python3 is available
    if ! command -v python3 &>/dev/null; then
        log_test "SKIP: python3 not available"
        return 0
    fi

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # ::1 → 00000000000000000000000001000000
        hex=$(_liveness_ip6_to_proc_hex "::1")
        [[ "$hex" == "00000000000000000000000001000000" ]] || { echo "::1 expected 00000000000000000000000001000000, got $hex"; exit 1; }

        # Injection attempt: invalid chars should be blocked (return 1)
        _liveness_ip6_to_proc_hex "::1'; rm -rf /" 2>/dev/null && exit 2 || true
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "IPv6 hex conversion should work and block injection: $err"
}

#===============================================================================
# UNIT TESTS: API connection signal — IP resolution
#===============================================================================

test_liveness_resolve_api_ips_deduplication() {
    log_test "Testing resolve_api_ips deduplicates IPs across domains"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to always return the same IP
        resolve_domain_ips() { echo "1.2.3.4"; }
        export -f resolve_domain_ips

        _LIVENESS_IPS_LAST_RESOLVED=0
        _liveness_resolve_api_ips

        # Even though 7 domains all return 1.2.3.4, the IP should appear only once
        count="${#_LIVENESS_API_IPS[@]}"
        [[ "$count" -eq 1 ]] || { echo "Expected 1 unique IP, got $count: ${_LIVENESS_API_IPS[*]}"; exit 1; }
        [[ "${_LIVENESS_API_IPS[0]}" == "1.2.3.4" ]] || { echo "Expected 1.2.3.4, got ${_LIVENESS_API_IPS[0]}"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should deduplicate repeated IPs: $err"
}

test_liveness_resolve_api_ips_graceful_failure() {
    log_test "Testing resolve_api_ips handles DNS failure gracefully"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to fail for all domains
        resolve_domain_ips() { return 1; }
        export -f resolve_domain_ips

        _LIVENESS_IPS_LAST_RESOLVED=0
        _liveness_resolve_api_ips

        # Should complete without error and result in 0 IPs (no pinned baseline here)
        count="${#_LIVENESS_API_IPS[@]}"
        [[ "$count" -eq 0 ]] || { echo "Expected 0 IPs on DNS failure, got $count"; exit 1; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "DNS failure should be handled gracefully: $err"
}

#===============================================================================
# UNIT TESTS: API connection signal — ss detection
#===============================================================================

test_liveness_ss_detection_established() {
    log_test "Testing has_active_api_connections detects established API connection via ss"

    local tmpdir
    tmpdir=$(mktemp -d)

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create a fake ss binary that reports an ESTABLISHED connection to an API IP
        cat > "$tmpdir/ss" << 'EOF'
#!/bin/bash
echo "Netid  State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port"
echo "tcp    ESTAB   0       0       10.0.0.1:54321      1.2.3.4:443"
EOF
        chmod +x "$tmpdir/ss"

        _LIVENESS_SS_BIN="$tmpdir/ss"
        _LIVENESS_API_IPS=("1.2.3.4")

        _liveness_has_active_api_connections || { echo "Expected detection of 1.2.3.4:443"; exit 1; }
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should detect active API connection via fake ss: $err"
}

test_liveness_ss_detection_ignores_non_api_ip() {
    log_test "Testing has_active_api_connections ignores non-API IP"

    local tmpdir
    tmpdir=$(mktemp -d)

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create a fake ss binary that reports a connection to a non-API IP
        cat > "$tmpdir/ss" << 'EOF'
#!/bin/bash
echo "Netid  State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port"
echo "tcp    ESTAB   0       0       10.0.0.1:54321      9.9.9.9:443"
EOF
        chmod +x "$tmpdir/ss"

        _LIVENESS_SS_BIN="$tmpdir/ss"
        _LIVENESS_API_IPS=("1.2.3.4")

        _liveness_has_active_api_connections && { echo "Should NOT have detected 9.9.9.9:443 as API connection"; exit 1; } || true
    ) 2>&1 || exit_code=$?

    rm -rf "$tmpdir"
    assert_equals 0 "$exit_code" "Should not detect non-API IP as API connection: $err"
}

#===============================================================================
# INTEGRATION TESTS: kill decision logic
#===============================================================================

test_liveness_should_kill_not_stale() {
    log_test "Testing _liveness_should_kill returns 1 when stale_seconds < timeout"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_has_active_api_connections() { return 1; }
        _liveness_log() { true; }

        local cycles=5
        if _liveness_should_kill 100 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but stale_seconds < timeout"
            exit 1
        fi
        # cycles should be unchanged (early return before any mutation)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should not kill when stale_seconds < timeout: $err"
}

test_liveness_should_kill_io_active() {
    log_test "Testing _liveness_should_kill returns 1 when I/O stale cycles < 2"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_has_active_api_connections() { return 1; }
        _liveness_log() { true; }

        local cycles=1
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but io_stale_cycles < 2"
            exit 1
        fi
        # cycles should be unchanged (early return before any mutation)
        [[ "$cycles" -eq 1 ]] || { echo "Expected cycles=1 unchanged, got $cycles"; exit 2; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Should not kill when io_stale_cycles < 2: $err"
}

test_liveness_skip_kill_when_api_connection() {
    log_test "Testing _liveness_should_kill spares agent when API connection active"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_has_active_api_connections() { return 0; }
        _liveness_log() { true; }

        _LIVENESS_API_SKIP_COUNT=0
        _LIVENESS_API_MAX_SKIP=240

        local cycles=5
        if _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 0 (kill) but API is active"
            exit 1
        fi

        # io_stale_cycles should be reset to 0
        [[ "$cycles" -eq 0 ]] || { echo "Expected cycles=0, got $cycles"; exit 2; }
        # skip count should be incremented
        [[ "$_LIVENESS_API_SKIP_COUNT" -eq 1 ]] || { echo "Expected skip_count=1, got $_LIVENESS_API_SKIP_COUNT"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Kill should be skipped with active API connection: $err"
}

test_liveness_kill_when_no_api_connection() {
    log_test "Testing _liveness_should_kill triggers kill when no API and all stale"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_has_active_api_connections() { return 1; }
        _liveness_log() { true; }

        _LIVENESS_API_SKIP_COUNT=0

        local cycles=5
        if ! _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 1 (spare) but no API and all stale"
            exit 1
        fi

        # skip count should be reset to 0
        [[ "$_LIVENESS_API_SKIP_COUNT" -eq 0 ]] || { echo "Expected skip_count=0, got $_LIVENESS_API_SKIP_COUNT"; exit 2; }
        # cycles should be unchanged (no-API path does not mutate io_stale_cycles)
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 unchanged, got $cycles"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Agent should be killed when no API connection: $err"
}

test_liveness_kill_when_api_skip_cap_exceeded() {
    log_test "Testing _liveness_should_kill triggers kill when API skip cap exceeded"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"
        _liveness_has_active_api_connections() { return 0; }
        _liveness_log() { true; }

        _LIVENESS_API_MAX_SKIP=3
        _LIVENESS_API_SKIP_COUNT=2  # one more will hit the cap

        local cycles=5
        if ! _liveness_should_kill 9999 1800 cycles; then
            echo "ERROR: should_kill returned 1 (spare) but skip cap should be exceeded"
            exit 1
        fi

        # io_stale_cycles should be restored to original value
        [[ "$cycles" -eq 5 ]] || { echo "Expected cycles=5 (restored), got $cycles"; exit 2; }
        # skip count should be reset after cap exceeded
        [[ "$_LIVENESS_API_SKIP_COUNT" -eq 0 ]] || { echo "Expected skip_count=0, got $_LIVENESS_API_SKIP_COUNT"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Agent should be killed when API skip cap exceeded: $err"
}

test_liveness_monitor_starts_without_dns() {
    log_test "Testing _liveness_init_api_signal completes even when DNS fails"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub resolve_domain_ips to fail (simulates DNS unavailable)
        resolve_domain_ips() { return 1; }
        export -f resolve_domain_ips

        # Remove pinned file path to ensure no file dependency
        export KAPSIS_DNS_PINNED_FILE="/nonexistent/pinned.conf"

        # Init should complete without error under set -euo pipefail
        _liveness_init_api_signal

        # Should have 0 IPs but not crashed
        echo "completed with ${#_LIVENESS_API_IPS[@]} IPs"
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "_liveness_init_api_signal should not crash when DNS fails: $err"
    assert_contains "$err" "completed with" "Should complete and report IP count"
}

#===============================================================================
# INTEGRATION TESTS: CLI flags
#===============================================================================

test_claude_exit_delay_agent_type_match() {
    log_test "Testing Claude agent type matches for CLAUDE_CODE_EXIT_AFTER_STOP_DELAY"

    # Verify agent-types.sh normalizes 'claude' to 'claude-cli'
    (
        source "$KAPSIS_ROOT/scripts/lib/agent-types.sh"
        local normalized
        normalized=$(normalize_agent_type "claude")
        [[ "$normalized" == "claude-cli" ]] || exit 1

        normalized=$(normalize_agent_type "claude-code")
        [[ "$normalized" == "claude-cli" ]] || exit 2
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should normalize claude/claude-code to claude-cli"
}

test_liveness_config_yaml_parsing() {
    log_test "Testing liveness YAML config is parsed correctly by yq"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 900
  grace_period: 120
  check_interval: 15
EOF

    # Parse the same way launch-agent.sh does
    local enabled timeout grace interval
    enabled=$(yq -r '.liveness.enabled // "false"' "$config_file" 2>/dev/null || echo "false")
    timeout=$(yq -r '.liveness.timeout // "1800"' "$config_file" 2>/dev/null || echo "1800")
    grace=$(yq -r '.liveness.grace_period // "300"' "$config_file" 2>/dev/null || echo "300")
    interval=$(yq -r '.liveness.check_interval // "30"' "$config_file" 2>/dev/null || echo "30")

    assert_equals "true" "$enabled" "Should parse enabled as true"
    assert_equals "900" "$timeout" "Should parse timeout as 900"
    assert_equals "120" "$grace" "Should parse grace_period as 120"
    assert_equals "15" "$interval" "Should parse check_interval as 15"

    rm -f "$config_file"
}

#===============================================================================
# CONFIG VALIDATION TESTS
#===============================================================================

test_liveness_config_validation_valid() {
    log_test "Testing config verifier accepts valid liveness config"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 1800
  grace_period: 300
  check_interval: 30
EOF

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should pass validation"
    assert_contains "$output" "Valid liveness.timeout" "Should validate timeout"

    rm -f "$config_file"
}

test_liveness_config_validation_timeout_too_low() {
    log_test "Testing config verifier rejects timeout < 60"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 30
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "must be >= 60" "Should reject timeout < 60"

    rm -f "$config_file"
}

test_liveness_config_validation_interval_too_low() {
    log_test "Testing config verifier rejects check_interval < 10"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  check_interval: 5
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "must be >= 10" "Should reject check_interval < 10"

    rm -f "$config_file"
}

test_liveness_config_validation_warns_timeout_lt_grace() {
    log_test "Testing config verifier warns when timeout < grace_period"

    local config_file
    config_file=$(mktemp /tmp/kapsis-test-XXXXXX.yaml)
    cat > "$config_file" << 'EOF'
agent:
  command: "echo test"
liveness:
  enabled: true
  timeout: 120
  grace_period: 300
EOF

    local output
    output=$("$KAPSIS_ROOT/scripts/lib/config-verifier.sh" "$config_file" 2>&1) || true

    assert_contains "$output" "less than grace_period" "Should warn about timeout < grace_period"

    rm -f "$config_file"
}

#===============================================================================
# HEALTH COMMAND TESTS
#===============================================================================

test_health_flag_requires_args() {
    log_test "Testing --health requires project and agent-id"

    local output
    local exit_code=0
    output=$("$KAPSIS_ROOT/scripts/kapsis-status.sh" --health 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail without project/agent"
    assert_contains "$output" "requires project" "Should explain required args"
}

test_health_json_output_valid() {
    log_test "Testing --health --json produces valid JSON structure"

    # Create a mock status file
    local status_dir
    status_dir=$(mktemp -d)
    local status_file="$status_dir/kapsis-testproj-1.json"
    cat > "$status_file" << 'EOF'
{
  "version": "1.0",
  "agent_id": "1",
  "project": "testproj",
  "phase": "running",
  "progress": 50,
  "message": "Testing",
  "updated_at": "2026-03-22T10:00:00Z",
  "started_at": "2026-03-22T09:00:00Z",
  "heartbeat_at": "2026-03-22T10:00:00Z",
  "gist": null,
  "gist_updated_at": null,
  "branch": null,
  "sandbox_mode": "overlay",
  "exit_code": null,
  "error": null,
  "worktree_path": null,
  "pr_url": null,
  "push_status": null,
  "local_commit": null,
  "remote_commit": null,
  "push_fallback_command": null,
  "commit_status": null,
  "commit_sha": null,
  "uncommitted_files": 0
}
EOF

    local output
    output=$(KAPSIS_STATUS_DIR="$status_dir" "$KAPSIS_ROOT/scripts/kapsis-status.sh" --health --json testproj 1 2>&1)

    # Check it contains expected JSON fields
    assert_contains "$output" '"agent_id"' "Should have agent_id field"
    assert_contains "$output" '"health"' "Should have health field"
    assert_contains "$output" '"io"' "Should have io field"
    assert_contains "$output" '"hook_staleness_seconds"' "Should have hook staleness"

    rm -rf "$status_dir"
}

test_health_not_found() {
    log_test "Testing --health with non-existent agent"

    local status_dir
    status_dir=$(mktemp -d)

    local exit_code=0
    local output
    output=$(KAPSIS_STATUS_DIR="$status_dir" "$KAPSIS_ROOT/scripts/kapsis-status.sh" --health noproject noagent 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail for non-existent agent"
    assert_contains "$output" "No status found" "Should report not found"

    rm -rf "$status_dir"
}

#===============================================================================
# MOUNT CHECK UNIT TESTS (Issue #248)
#===============================================================================

test_mount_check_probe_healthy() {
    log_test "Testing mount check probe returns 0 for populated workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create a fake workspace with content
        local workspace
        workspace=$(mktemp -d)
        mkdir -p "$workspace"
        echo "test" > "$workspace/file.txt"

        # Override workspace path for testing (CONTAINER_WORKSPACE_PATH is readonly)
        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe || exit 1

        rm -rf "$workspace"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should succeed for populated workspace"
}

test_mount_check_probe_empty_workspace() {
    log_test "Testing mount check probe returns 1 for empty workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Create an empty workspace (simulates mount drop)
        local workspace
        workspace=$(mktemp -d)

        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should fail for empty workspace"
}

test_mount_check_probe_missing_workspace() {
    log_test "Testing mount check probe returns 1 for missing workspace"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_WORKSPACE="/nonexistent/workspace/path"
        _MOUNT_CHECK_PROBE_TIMEOUT=2

        _mount_check_probe && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should fail for missing workspace"
}

test_mount_check_probe_worktree_git_sentinel() {
    log_test "Testing mount check probe checks .git-safe/HEAD in worktree mode"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local workspace
        workspace=$(mktemp -d)
        echo "test" > "$workspace/file.txt"

        # Create .git-safe/HEAD to simulate worktree mode
        mkdir -p "$workspace/.git-safe"
        echo "ref: refs/heads/main" > "$workspace/.git-safe/HEAD"

        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_GIT_PATH="$workspace/.git-safe"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        KAPSIS_SANDBOX_MODE=worktree

        _mount_check_probe || exit 1

        # Now remove .git-safe/HEAD - probe should fail
        rm "$workspace/.git-safe/HEAD"
        _mount_check_probe && exit 2

        rm -rf "$workspace"
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe should check .git-safe/HEAD in worktree mode"
}

test_mount_check_with_retries_recovers() {
    log_test "Testing mount check recovers on retry"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        local workspace
        workspace=$(mktemp -d)
        _MOUNT_CHECK_WORKSPACE="$workspace"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        _MOUNT_CHECK_RETRIES=2
        _MOUNT_CHECK_RETRY_DELAY=1

        # First call: workspace is empty (fail), then populate it for retry
        local call_count=0
        _mount_check_probe() {
            ((call_count++)) || true
            if [[ "$call_count" -le 1 ]]; then
                return 1  # First call fails
            fi
            return 0  # Second call succeeds
        }

        _mount_check_with_retries || exit 1

        rm -rf "$workspace"
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should recover on retry"
}

test_mount_check_with_retries_all_fail() {
    log_test "Testing mount check fails after exhausted retries"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_WORKSPACE="/nonexistent"
        _MOUNT_CHECK_PROBE_TIMEOUT=2
        _MOUNT_CHECK_RETRIES=2
        _MOUNT_CHECK_RETRY_DELAY=1

        _mount_check_with_retries && exit 1  # Should fail
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should fail after exhausted retries"
}

test_mount_check_probe_returns_124_on_timeout() {
    log_test "Testing mount check probe propagates exit code 124 on timeout"

    (
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        _MOUNT_CHECK_RETRIES=3
        _MOUNT_CHECK_RETRY_DELAY=0

        # Verify _mount_check_with_retries exits immediately on first 124
        local call_count=0
        _mount_check_probe() {
            ((call_count++)) || true
            return 124
        }

        _mount_check_with_retries
        local retries_exit=$?

        # Should have been called exactly once (no retries for hangs)
        [[ "$call_count" -eq 1 ]] || exit 1
        # Should return failure
        [[ "$retries_exit" -ne 0 ]] || exit 2
        exit 0
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Probe timeout (124) should skip retries"
}

test_mount_check_config_defaults() {
    log_test "Testing mount check config defaults"

    (
        unset KAPSIS_MOUNT_CHECK_ENABLED KAPSIS_MOUNT_CHECK_RETRIES
        unset KAPSIS_MOUNT_CHECK_RETRY_DELAY KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT
        unset KAPSIS_MOUNT_CHECK_DELAY
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_MOUNT_CHECK_ENABLED" == "false" ]] || exit 1
        [[ "$_MOUNT_CHECK_RETRIES" == "2" ]] || exit 2
        [[ "$_MOUNT_CHECK_RETRY_DELAY" == "5" ]] || exit 3
        [[ "$_MOUNT_CHECK_PROBE_TIMEOUT" == "5" ]] || exit 4
        [[ "$_MOUNT_CHECK_DELAY" == "30" ]] || exit 5
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should have correct defaults (false/2/5/5/30)"
}

test_mount_check_config_custom_values() {
    log_test "Testing mount check config with custom env vars"

    (
        export KAPSIS_MOUNT_CHECK_ENABLED=true
        export KAPSIS_MOUNT_CHECK_RETRIES=5
        export KAPSIS_MOUNT_CHECK_RETRY_DELAY=10
        export KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT=3
        export KAPSIS_MOUNT_CHECK_DELAY=60
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        [[ "$_MOUNT_CHECK_ENABLED" == "true" ]] || exit 1
        [[ "$_MOUNT_CHECK_RETRIES" == "5" ]] || exit 2
        [[ "$_MOUNT_CHECK_RETRY_DELAY" == "10" ]] || exit 3
        [[ "$_MOUNT_CHECK_PROBE_TIMEOUT" == "3" ]] || exit 4
        [[ "$_MOUNT_CHECK_DELAY" == "60" ]] || exit 5
    ) 2>/dev/null
    local exit_code=$?

    assert_equals 0 "$exit_code" "Should accept custom values (true/5/10/3/60)"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "Liveness Monitor"

    # Unit tests
    run_test test_liveness_monitor_sources_cleanly
    run_test test_liveness_source_guard
    run_test test_liveness_io_parsing
    run_test test_liveness_io_parsing_missing_file
    run_test test_liveness_io_parsing_zero_bytes
    run_test test_liveness_config_defaults
    run_test test_liveness_config_custom_values
    run_test test_liveness_heartbeat_in_status
    run_test test_liveness_heartbeat_null_when_unset

    # API connection signal unit tests
    run_test test_liveness_ip4_to_proc_hex
    run_test test_liveness_ip6_to_proc_hex
    run_test test_liveness_resolve_api_ips_deduplication
    run_test test_liveness_resolve_api_ips_graceful_failure
    run_test test_liveness_ss_detection_established
    run_test test_liveness_ss_detection_ignores_non_api_ip

    # Kill decision logic unit tests
    run_test test_liveness_should_kill_not_stale
    run_test test_liveness_should_kill_io_active
    run_test test_liveness_skip_kill_when_api_connection
    run_test test_liveness_kill_when_no_api_connection
    run_test test_liveness_kill_when_api_skip_cap_exceeded
    run_test test_liveness_monitor_starts_without_dns

    # Integration tests
    run_test test_claude_exit_delay_agent_type_match
    run_test test_liveness_config_yaml_parsing

    # Config validation tests
    run_test test_liveness_config_validation_valid
    run_test test_liveness_config_validation_timeout_too_low
    run_test test_liveness_config_validation_interval_too_low
    run_test test_liveness_config_validation_warns_timeout_lt_grace

    # Health command tests
    run_test test_health_flag_requires_args
    run_test test_health_json_output_valid
    run_test test_health_not_found

    # Mount check tests (Issue #248)
    run_test test_mount_check_probe_healthy
    run_test test_mount_check_probe_empty_workspace
    run_test test_mount_check_probe_missing_workspace
    run_test test_mount_check_probe_worktree_git_sentinel
    run_test test_mount_check_with_retries_recovers
    run_test test_mount_check_with_retries_all_fail
    run_test test_mount_check_probe_returns_124_on_timeout
    run_test test_mount_check_config_defaults
    run_test test_mount_check_config_custom_values

    print_summary
}

main "$@"
