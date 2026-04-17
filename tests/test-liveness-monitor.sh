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

        # Check status file contains heartbeat_at
        local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-test-1.json"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at"' "$status_file" || exit 1
            # Should not be null
            local hb
            hb=$(grep '"heartbeat_at"' "$status_file")
            [[ "$hb" != *"null"* ]] || exit 2
        else
            exit 3
        fi

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

        local status_file="$KAPSIS_STATUS_DIR/kapsis-test-project-test-2.json"
        if [[ -f "$status_file" ]]; then
            grep -q '"heartbeat_at": null' "$status_file" || exit 1
        else
            exit 2
        fi

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

test_liveness_skip_kill_when_api_connection() {
    log_test "Testing kill is skipped when active API connection exists"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Stub has_active_api_connections to always return true
        _liveness_has_active_api_connections() { return 0; }

        # Simulate the kill decision block conditions
        local timeout=1800 interval=30
        local stale_seconds=9999
        local io_stale_cycles=5
        _LIVENESS_API_SKIP_COUNT=0
        _LIVENESS_API_MAX_SKIP=240

        local action="none"
        if [[ "$stale_seconds" -ge "$timeout" ]] && [[ "$io_stale_cycles" -ge 2 ]]; then
            if _liveness_has_active_api_connections; then
                io_stale_cycles=0
                (( _LIVENESS_API_SKIP_COUNT++ )) || true
                if [[ "$_LIVENESS_API_SKIP_COUNT" -lt "$_LIVENESS_API_MAX_SKIP" ]]; then
                    action="skipped"
                fi
            fi
        fi

        [[ "$action" == "skipped" ]] || { echo "Expected action=skipped, got action=$action"; exit 1; }
        [[ "$io_stale_cycles" -eq 0 ]] || { echo "Expected io_stale_cycles=0 after skip, got $io_stale_cycles"; exit 2; }
        [[ "$_LIVENESS_API_SKIP_COUNT" -eq 1 ]] || { echo "Expected skip_count=1, got $_LIVENESS_API_SKIP_COUNT"; exit 3; }
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Kill should be skipped with active API connection: $err"
}

test_liveness_kill_when_no_api_connection() {
    log_test "Testing agent is killed when no API connection and both signals stale"

    local err exit_code=0
    err=$(
        source "$KAPSIS_ROOT/scripts/lib/liveness-monitor.sh"

        # Start a real background process to kill
        sleep 999 &
        local test_pid=$!

        # Stub has_active_api_connections to return false
        _liveness_has_active_api_connections() { return 1; }

        # Override _liveness_write_killed_status to no-op
        _liveness_write_killed_status() { true; }

        # Simulate the kill logic directly
        local timeout=1800
        local stale_seconds=9999
        local io_stale_cycles=5

        if [[ "$stale_seconds" -ge "$timeout" ]] && [[ "$io_stale_cycles" -ge 2 ]]; then
            if ! _liveness_has_active_api_connections; then
                _LIVENESS_API_SKIP_COUNT=0
                _liveness_write_killed_status "test"
                kill -SIGTERM "$test_pid" 2>/dev/null || true
                # Wait up to 10s for process to die (CI environments can be slow)
                local _wait
                for _wait in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$test_pid" 2>/dev/null || break
                    sleep 1
                done
                # Escalate to SIGKILL if SIGTERM wasn't enough (mirrors real monitor)
                if kill -0 "$test_pid" 2>/dev/null; then
                    kill -SIGKILL "$test_pid" 2>/dev/null || true
                    sleep 1
                fi
            fi
        fi

        # Process should be gone
        kill -0 "$test_pid" 2>/dev/null && { echo "Process $test_pid should have been killed"; kill "$test_pid" 2>/dev/null; exit 1; } || true
    ) 2>&1 || exit_code=$?

    assert_equals 0 "$exit_code" "Agent should be killed when no API connection: $err"
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

    # Kill decision logic integration tests
    run_test test_liveness_skip_kill_when_api_connection
    run_test test_liveness_kill_when_no_api_connection
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

    print_summary
}

main "$@"
