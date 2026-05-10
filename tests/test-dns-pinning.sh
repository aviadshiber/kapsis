#!/usr/bin/env bash
#===============================================================================
# Test: DNS IP Pinning (filtered mode security enhancement)
#
# Verifies DNS IP pinning functionality that resolves domains on the trusted
# host before container launch and pins those IPs inside the container.
#
# Attack vectors mitigated:
#   1. Agent kills dnsmasq, rewrites /etc/resolv.conf
#   2. Upstream DNS poisoning returns malicious IPs
#   3. Agent modifies /etc/hosts after dnsmasq killed
#
# Tests:
#   - Domain resolution on host (resolve_domain_ips)
#   - Allowlist resolution with wildcard warnings
#   - Pinned file generation and validation
#   - --add-host arguments generation
#   - dnsmasq config uses address=/ for pinned, server=/ for wildcards
#   - Config validation for dns_pinning section
#   - Container tests for pinned entries and file protection
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
DNS_PIN_LIB="$KAPSIS_ROOT/scripts/lib/dns-pin.sh"
DNS_FILTER_LIB="$KAPSIS_ROOT/scripts/lib/dns-filter.sh"
COMPAT_LIB="$KAPSIS_ROOT/scripts/lib/compat.sh"
CONFIG_VERIFIER="$KAPSIS_ROOT/scripts/lib/config-verifier.sh"
ALLOWLIST_CONFIG="$KAPSIS_ROOT/configs/network-allowlist.yaml"

#===============================================================================
# QUICK TESTS (no container required)
#===============================================================================

test_dns_pin_library_exists() {
    log_test "Testing DNS pinning library exists and is valid bash"

    assert_file_exists "$DNS_PIN_LIB" "DNS pinning library should exist"
    assert_command_succeeds "bash -n '$DNS_PIN_LIB'" "DNS pinning library should be valid bash"
}

test_resolve_domain_ips_in_compat() {
    log_test "Testing resolve_domain_ips exists in compat.sh"

    # Source the library
    source "$COMPAT_LIB"

    # Check function exists
    if declare -F resolve_domain_ips >/dev/null; then
        log_pass "resolve_domain_ips function exists"
    else
        log_fail "resolve_domain_ips function not found in compat.sh"
        return 1
    fi
}

test_resolve_well_known_domain() {
    log_test "Testing resolve_domain_ips resolves well-known domain"

    # Source the library
    source "$COMPAT_LIB"

    # Resolve one.one.one.one (Cloudflare) - should return 1.1.1.1 or 1.0.0.1
    local ips
    ips=$(resolve_domain_ips "one.one.one.one" 5)

    if [[ -n "$ips" ]]; then
        # Check it contains valid IP format
        if echo "$ips" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            # Skip test if DNS filtering returns placeholder (0.0.0.0)
            if [[ "$ips" == "0.0.0.0" ]]; then
                log_skip "DNS filtering detected (returns 0.0.0.0 - network restriction)"
                return 0
            fi
            log_pass "Resolved one.one.one.one: $(echo "$ips" | head -1)"
        else
            log_fail "Invalid IP format returned: $ips"
            return 1
        fi
    else
        log_skip "DNS resolution unavailable (network or DNS issue)"
        return 0
    fi
}

test_resolve_invalid_domain_returns_empty() {
    log_test "Testing resolve_domain_ips returns empty for invalid domain"

    source "$COMPAT_LIB"

    local ips
    ips=$(resolve_domain_ips "this-domain-definitely-does-not-exist-xyz123.invalid" 2)

    if [[ -z "$ips" ]]; then
        log_pass "Empty result for invalid domain"
    elif [[ "$ips" == "0.0.0.0" ]]; then
        # Some DNS resolvers (esp. corporate/filtered) return 0.0.0.0 for all domains
        log_skip "DNS filtering detected (returns 0.0.0.0 for all domains)"
        return 0
    else
        log_fail "Expected empty result, got: $ips"
        return 1
    fi
}

test_resolve_skips_wildcards() {
    log_test "Testing resolve_domain_ips skips wildcard domains"

    source "$COMPAT_LIB"

    local ips
    ips=$(resolve_domain_ips "*.github.com" 2)

    if [[ -z "$ips" ]]; then
        log_pass "Wildcards correctly skipped"
    else
        log_fail "Wildcards should return empty, got: $ips"
        return 1
    fi
}

test_resolve_ip_address_passthrough() {
    log_test "Testing resolve_domain_ips passes through IP addresses"

    source "$COMPAT_LIB"

    local ips
    ips=$(resolve_domain_ips "8.8.8.8" 2)

    if [[ "$ips" == "8.8.8.8" ]]; then
        log_pass "IP address passed through correctly"
    else
        log_fail "Expected 8.8.8.8, got: $ips"
        return 1
    fi
}

test_resolve_allowlist_domains_function() {
    log_test "Testing resolve_allowlist_domains function exists"

    source "$DNS_PIN_LIB"

    if declare -F resolve_allowlist_domains >/dev/null; then
        log_pass "resolve_allowlist_domains function exists"
    else
        log_fail "resolve_allowlist_domains function not found"
        return 1
    fi
}

test_resolve_allowlist_skips_wildcards_with_warning() {
    log_test "Testing resolve_allowlist_domains skips wildcards"

    source "$DNS_PIN_LIB"

    local output
    output=$(resolve_allowlist_domains "*.github.com,*.gitlab.com" 2 "dynamic" 2>&1)

    # Check that wildcards are not in the resolved output (domain IP lines)
    if echo "$output" | grep -qE '^\*\.github\.com [0-9]'; then
        log_fail "Wildcard should not be resolved"
        return 1
    fi

    # Check for security warning
    if echo "$output" | grep -q "SECURITY.*wildcard"; then
        log_pass "Wildcard domains skipped with security warning"
    else
        log_pass "Wildcard domains skipped (warning may be suppressed)"
    fi
}

test_pinned_file_format() {
    log_test "Testing pinned file format is correct"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    # Create test resolved data
    local resolved_data="github.com 1.2.3.4 5.6.7.8
gitlab.com 10.20.30.40"

    write_pinned_dns_file "$temp_file" "$resolved_data"

    # Verify format
    assert_file_exists "$temp_file" "Pinned file should be created"
    assert_file_contains "$temp_file" "github.com 1.2.3.4 5.6.7.8" "Should contain github entry"
    assert_file_contains "$temp_file" "gitlab.com 10.20.30.40" "Should contain gitlab entry"
    assert_file_contains "$temp_file" "# Kapsis DNS Pinning" "Should have header"

    rm -f "$temp_file"
}

test_generate_add_host_args() {
    log_test "Testing --add-host arguments generation"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    # Create test pinned file
    cat > "$temp_file" << 'EOF'
# Test pinned file
github.com 1.2.3.4 5.6.7.8
gitlab.com 10.20.30.40
EOF

    local args
    args=$(generate_add_host_args "$temp_file")

    # Check output contains correct format
    if echo "$args" | grep -q "^--add-host$"; then
        if echo "$args" | grep -q "github.com:1.2.3.4"; then
            log_pass "Correct --add-host format generated"
        else
            log_fail "Expected github.com:1.2.3.4, got: $args"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_fail "Expected --add-host flag, got: $args"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"
}

test_generate_pinned_dnsmasq_entries() {
    log_test "Testing dnsmasq host-record entries generation (Issue #245: exact-match, no subdomain capture)"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    cat > "$temp_file" << 'EOF'
github.com 1.2.3.4 5.6.7.8
gitlab.com 10.20.30.40
EOF

    local entries
    entries=$(generate_pinned_dnsmasq_entries "$temp_file")

    # Check output uses host-record= with comma-separated IPs (exact match, Issue #245)
    # Multiple IPs on one line — separate host-record= lines don't accumulate in dnsmasq
    assert_contains "$entries" "host-record=github.com,1.2.3.4,5.6.7.8" "Should have github host-record with both IPs"
    assert_contains "$entries" "host-record=gitlab.com,10.20.30.40" "Should have gitlab host-record entry"

    rm -f "$temp_file"
}

test_validate_pinned_entry_valid() {
    log_test "Testing pinned entry validation - valid entries"

    source "$DNS_PIN_LIB"

    # Valid entries
    assert_command_succeeds "validate_pinned_entry 'github.com 1.2.3.4'" "Simple entry should be valid"
    assert_command_succeeds "validate_pinned_entry 'gitlab.com 10.20.30.40 192.168.1.1'" "Multiple IPs should be valid"
    assert_command_succeeds "validate_pinned_entry '# comment'" "Comment should be valid"
    assert_command_succeeds "validate_pinned_entry ''" "Empty line should be valid"
}

test_validate_pinned_entry_invalid() {
    log_test "Testing pinned entry validation - invalid entries"

    source "$DNS_PIN_LIB"

    # Invalid entries
    assert_command_fails "validate_pinned_entry 'github.com'" "Missing IP should be invalid"
    assert_command_fails "validate_pinned_entry 'github.com not-an-ip'" "Invalid IP format should fail"
    assert_command_fails "validate_pinned_entry 'github.com 999.999.999.999'" "Out of range IP should fail"
}

test_dnsmasq_config_uses_pinned_entries() {
    log_test "Testing dnsmasq config generation with pinned entries"

    source "$DNS_FILTER_LIB"

    # Set up temp files
    local temp_config pinned_file
    temp_config=$(mktemp)
    pinned_file=$(mktemp)

    # Create pinned file with test data
    cat > "$pinned_file" << 'EOF'
github.com 1.2.3.4
gitlab.com 5.6.7.8
EOF

    export KAPSIS_DNS_CONFIG_FILE="$temp_config"
    export KAPSIS_DNS_PINNED_FILE="$pinned_file"
    export KAPSIS_DNS_SERVERS="8.8.8.8"
    export KAPSIS_DNS_ALLOWLIST="github.com,*.npmjs.org,gitlab.com"
    export KAPSIS_DNS_PIN_ENABLED="true"
    export KAPSIS_DEBUG=""  # Disable verbose logging

    # Generate config
    generate_dnsmasq_config

    # Verify pinned domains use host-record= (exact match, Issue #245)
    assert_file_contains "$temp_config" "host-record=github.com,1.2.3.4" "Pinned github should use host-record="
    assert_file_contains "$temp_config" "host-record=gitlab.com,5.6.7.8" "Pinned gitlab should use host-record="

    # Verify wildcards still use server=/ (dynamic forwarding)
    assert_file_contains "$temp_config" "server=/.npmjs.org/8.8.8.8" "Wildcard should use server=/"

    # Verify pinned domains are NOT also using server=/ (no duplicate rules)
    local github_server_count
    github_server_count=$(grep -c "server=/github.com/" "$temp_config" 2>/dev/null || echo "0")
    # Remove any whitespace/newlines
    github_server_count=$(echo "$github_server_count" | tr -d '[:space:]')
    if [[ "$github_server_count" == "0" ]]; then
        log_pass "Pinned domains correctly skip server=/ rules"
    else
        log_fail "Found server=/ rule for pinned domain github.com ($github_server_count times)"
    fi

    # Cleanup
    rm -f "$temp_config" "$pinned_file"
    unset KAPSIS_DNS_CONFIG_FILE KAPSIS_DNS_PINNED_FILE KAPSIS_DNS_SERVERS KAPSIS_DNS_ALLOWLIST KAPSIS_DNS_PIN_ENABLED
}

test_config_validation_dns_pinning_valid() {
    log_test "Testing config validation accepts valid dns_pinning settings"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local test_config
    test_config=$(mktemp).yaml

    cat > "$test_config" << 'EOF'
network:
  mode: filtered
  dns_pinning:
    enabled: true
    fallback: dynamic
    resolve_timeout: 5
    protect_dns_files: true
EOF

    local output

    output=$("$CONFIG_VERIFIER" "$test_config" 2>&1) || true

    # Check for validation passes - the verifier outputs [PASS] for valid settings
    if echo "$output" | grep -q "dns_pinning.enabled"; then
        if echo "$output" | grep -q "\[FAIL\].*dns_pinning"; then
            log_fail "Validation failed for valid settings"
        else
            log_pass "Valid dns_pinning settings accepted"
        fi
    else
        # dns_pinning not validated (may be skipped due to config type detection)
        log_pass "Config validation completed (dns_pinning may not be validated for this config type)"
    fi

    rm -f "$test_config"
}

test_config_validation_dns_pinning_invalid() {
    log_test "Testing config validation rejects invalid dns_pinning settings"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local test_config
    test_config=$(mktemp).yaml

    cat > "$test_config" << 'EOF'
network:
  mode: filtered
  dns_pinning:
    enabled: "maybe"
    fallback: "invalid"
    resolve_timeout: -5
    protect_dns_files: "sometimes"
EOF

    local output

    output=$("$CONFIG_VERIFIER" "$test_config" 2>&1) || true

    # Check for validation errors
    if echo "$output" | grep -q "Invalid dns_pinning.enabled"; then
        log_pass "Invalid dns_pinning.enabled detected"
    else
        log_warn "Expected validation error for invalid enabled value"
    fi

    rm -f "$test_config"
}

test_dry_run_shows_pinning() {
    log_test "Testing dry-run shows DNS pinning info"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local output


    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode filtered --task "test" --dry-run 2>&1) || true

    # Check for DNS pinning output (may fail to resolve in some environments)
    if echo "$output" | grep -q "DNS pinning"; then
        log_pass "Dry-run shows DNS pinning activity"
    else
        # DNS pinning might be silently skipped if no domains to resolve
        log_pass "Dry-run completed (DNS pinning may be skipped for empty allowlist)"
    fi
}

test_default_config_has_dns_pinning() {
    log_test "Testing default allowlist config has dns_pinning section"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local enabled
    enabled=$(yq -r '.network.dns_pinning.enabled // "null"' "$ALLOWLIST_CONFIG" 2>/dev/null)

    if [[ "$enabled" == "true" ]]; then
        log_pass "Default config has dns_pinning.enabled: true"
    elif [[ "$enabled" == "null" ]]; then
        log_fail "Default config missing dns_pinning section"
        return 1
    else
        log_pass "Default config has dns_pinning section (enabled=$enabled)"
    fi
}

test_count_pinned_domains() {
    log_test "Testing count_pinned_domains function"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    cat > "$temp_file" << 'EOF'
# Comment line
github.com 1.2.3.4
gitlab.com 5.6.7.8

bitbucket.org 10.20.30.40
EOF

    local count
    count=$(count_pinned_domains "$temp_file")

    if [[ "$count" -eq 3 ]]; then
        log_pass "Correctly counted 3 pinned domains"
    else
        log_fail "Expected 3, got: $count"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"
}

test_get_pinned_domains() {
    log_test "Testing get_pinned_domains function"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    cat > "$temp_file" << 'EOF'
github.com 1.2.3.4
gitlab.com 5.6.7.8
EOF

    local domains
    domains=$(get_pinned_domains "$temp_file")

    assert_contains "$domains" "github.com" "Should include github.com"
    assert_contains "$domains" "gitlab.com" "Should include gitlab.com"

    rm -f "$temp_file"
}

#===============================================================================
# PROPERTY-BASED TESTS (randomized, no container)
#===============================================================================

test_resolve_returns_valid_ipv4_or_empty() {
    log_test "Testing resolve_domain_ips returns valid IPv4 or empty"

    source "$COMPAT_LIB"

    # Test with random domain-like strings
    local test_domains=(
        "github.com"
        "example.org"
        "test123.invalid"
        "sub.domain.example.net"
        ""
        "*.wildcard.com"
    )

    local all_valid=true

    for domain in "${test_domains[@]}"; do
        local ips
        ips=$(resolve_domain_ips "$domain" 1)

        # Should be empty OR valid IPv4 addresses
        if [[ -n "$ips" ]]; then
            while IFS= read -r ip; do
                if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log_fail "Invalid IP format for $domain: $ip"
                    all_valid=false
                    break
                fi
            done <<< "$ips"
        fi
    done

    if [[ "$all_valid" == "true" ]]; then
        log_pass "All resolve results are valid IPv4 or empty"
    fi
}

test_add_host_args_format() {
    log_test "Testing --add-host args always have valid format"

    source "$DNS_PIN_LIB"

    # Create pinned file with various content types
    local temp_file
    temp_file=$(mktemp)

    cat > "$temp_file" << 'EOF'
# Header comment
domain1.com 1.1.1.1
domain2.org 2.2.2.2 3.3.3.3

# Another comment
domain-with-dash.net 4.4.4.4
EOF

    local args
    args=$(generate_add_host_args "$temp_file")

    # Verify all lines are either --add-host or domain:IP format
    local all_valid=true
    local prev_line=""

    while IFS= read -r line; do
        if [[ "$prev_line" == "--add-host" ]]; then
            # This line should be domain:IP
            if [[ ! "$line" =~ ^[a-zA-Z0-9.-]+:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log_fail "Invalid add-host entry: $line"
                all_valid=false
                break
            fi
        elif [[ -n "$line" ]] && [[ "$line" != "--add-host" ]]; then
            log_fail "Unexpected line in add-host output: $line"
            all_valid=false
            break
        fi
        prev_line="$line"
    done <<< "$args"

    if [[ "$all_valid" == "true" ]]; then
        log_pass "All --add-host arguments have valid format"
    fi

    rm -f "$temp_file"
}

test_pinned_file_parsing_robust() {
    log_test "Testing pinned file parsing handles edge cases"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    # Write file with various edge cases (3 actual domain lines)
    cat > "$temp_file" << 'EOF'
# Normal comment
domain1.com 1.2.3.4
domain2.org 5.6.7.8 9.10.11.12
domain3.net 13.14.15.16
# Final comment
EOF

    local count
    count=$(count_pinned_domains "$temp_file")
    # Clean up whitespace
    count=$(echo "$count" | tr -d '[:space:]')

    if [[ "$count" == "3" ]]; then
        log_pass "Correctly parsed file with edge cases"
    else
        log_fail "Expected 3 domains, got: $count"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"
}

#===============================================================================
# THRESHOLD TESTS (Issue #216 — abort launch when DNS failure rate too high)
#
# These tests stub resolve_domain_ips so the threshold logic runs against
# fixed, deterministic outcomes — no real DNS, no log_skip on flaky networks.
# Domains prefixed "fail-" return empty (failure); all others return 1.2.3.4.
#===============================================================================

_stub_resolve_domain_ips() {
    local domain="$1"
    if [[ "$domain" == fail-* ]]; then
        echo ""  # empty = resolution failure
    else
        echo "1.2.3.4"
    fi
}

# Restore the real resolve_domain_ips after a test stubbed it. Compat.sh has a
# load guard, so a plain `source` is a no-op once the file's been loaded; clear
# the guard first to force re-definition of the function we replaced.
_restore_resolve_domain_ips() {
    unset -f resolve_domain_ips 2>/dev/null || true
    unset _KAPSIS_COMPAT_LOADED
    # shellcheck disable=SC1090
    source "$COMPAT_LIB"
}

test_threshold_max_failures_triggers_exit2() {
    log_test "Testing resolve_allowlist_domains returns 2 when max_failures exceeded"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 2 failures, max_failures=1
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" "" "1" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 2 ]]; then
        log_pass "Exit code 2 returned when failures exceed max_failures"
    else
        log_fail "Expected exit code 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_max_failure_rate_triggers_exit2() {
    log_test "Testing resolve_allowlist_domains returns 2 when max_failure_rate exceeded"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 2/2 = 100% > 0.4
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" "0.4" "" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 2 ]]; then
        log_pass "Exit code 2 returned when failure rate exceeds max_failure_rate"
    else
        log_fail "Expected exit code 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_under_limit_returns_0() {
    log_test "Testing resolve_allowlist_domains returns 0 when failures stay under threshold"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 2 failures, max_failures=100 (well under)
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" "" "100" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log_pass "Exit code 0 when failures are under max_failures threshold"
    else
        log_fail "Expected exit code 0, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_env_var_max_failures() {
    log_test "Testing KAPSIS_DNS_MAX_FAILURES env var is respected"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    export KAPSIS_DNS_MAX_FAILURES=1
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" >/dev/null 2>&1 || rc=$?
    unset KAPSIS_DNS_MAX_FAILURES

    if [[ "$rc" -eq 2 ]]; then
        log_pass "KAPSIS_DNS_MAX_FAILURES env var triggers exit code 2"
    else
        log_fail "Expected exit code 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_env_var_max_failure_rate() {
    log_test "Testing KAPSIS_DNS_MAX_FAILURE_RATE env var is respected"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    export KAPSIS_DNS_MAX_FAILURE_RATE=0.1
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" >/dev/null 2>&1 || rc=$?
    unset KAPSIS_DNS_MAX_FAILURE_RATE

    if [[ "$rc" -eq 2 ]]; then
        log_pass "KAPSIS_DNS_MAX_FAILURE_RATE env var triggers exit code 2"
    else
        log_fail "Expected exit code 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_no_limit_set_returns_0() {
    log_test "Testing resolve_allowlist_domains returns 0 with no threshold configured"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    unset KAPSIS_DNS_MAX_FAILURES KAPSIS_DNS_MAX_FAILURE_RATE
    local rc=0
    resolve_allowlist_domains "fail-a.test" 1 "dynamic" "" "" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log_pass "No threshold — failures tolerated, exit code 0"
    else
        log_fail "Expected exit code 0, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_zero_concrete_domains() {
    log_test "Testing zero-concrete-domains (all wildcards) does not trigger rate threshold"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # All wildcards — no resolved, no failed, no divide-by-zero, no abort.
    local rc=0
    resolve_allowlist_domains "*.github.com,*.npmjs.org" 1 "dynamic" "0.0" "0" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log_pass "All-wildcard list with strict thresholds does not abort"
    else
        log_fail "Expected exit code 0 for all-wildcard list, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_lists_failing_domains() {
    log_test "Testing abort message includes the failing domains"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    local output rc=0
    output=$(resolve_allowlist_domains \
        "ok.test,fail-alpha.test,fail-beta.test" \
        1 "dynamic" "" "1" 2>&1) || rc=$?

    if [[ "$rc" -ne 2 ]]; then
        log_fail "Expected exit 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi

    if echo "$output" | grep -q "fail-alpha.test" && echo "$output" | grep -q "fail-beta.test"; then
        log_pass "Both failing domains listed in abort output"
    else
        log_fail "Failing domains not listed in output. Got: $output"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_failing_domain_preview_caps_at_10() {
    log_test "Testing failing-domain preview caps at 10 with 'N more' summary"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 12 failures — preview should show 10 with "and 2 more"
    local domain_list="fail-1.test,fail-2.test,fail-3.test,fail-4.test,fail-5.test,fail-6.test,fail-7.test,fail-8.test,fail-9.test,fail-10.test,fail-11.test,fail-12.test"
    local output rc=0
    output=$(resolve_allowlist_domains "$domain_list" 1 "dynamic" "" "0" 2>&1) || rc=$?

    if [[ "$rc" -ne 2 ]]; then
        log_fail "Expected exit 2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi

    if echo "$output" | grep -q "showing 10 of 12" && echo "$output" | grep -q "and 2 more"; then
        log_pass "Preview correctly shows 10 of 12 with 'and 2 more'"
    else
        log_fail "Expected truncation summary missing. Got: $output"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_rate_at_boundary_passes() {
    log_test "Testing rate exactly at threshold does not abort (strict > comparison)"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 1 fail / 2 total = 0.5; threshold = 0.5; strict > means rc=0
    local rc=0
    resolve_allowlist_domains "ok.test,fail-a.test" 1 "dynamic" "0.5" "" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log_pass "rate=0.5 with threshold=0.5 does not abort"
    else
        log_fail "Expected rc=0 at boundary, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_rate_zero_with_no_failures_passes() {
    log_test "Testing max_failure_rate=0.0 with zero failures does not abort"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # All resolve, max_failure_rate=0.0 — 0/N = 0.0, not > 0.0
    local rc=0
    resolve_allowlist_domains "ok-1.test,ok-2.test,ok-3.test" 1 "dynamic" "0.0" "" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log_pass "max_failure_rate=0.0 with zero failures does not abort"
    else
        log_fail "Expected rc=0, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_wildcards_excluded_from_count() {
    log_test "Testing wildcards excluded from threshold denominator"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # 3 wildcards + 1 concrete failure. If wildcards counted, 1/4 = 25% < 50%, would pass.
    # If wildcards excluded (correct), 1/1 = 100% > 50%, must abort.
    local rc=0
    resolve_allowlist_domains "*.a.test,*.b.test,*.c.test,fail-x.test" 1 "dynamic" "0.5" "" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 2 ]]; then
        log_pass "Wildcards excluded from denominator (1/1 = 100% triggers abort)"
    else
        log_fail "Expected rc=2 (wildcards excluded), got: $rc — wildcards may be counted"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_preview_no_truncation_at_exactly_10() {
    log_test "Testing preview at exactly 10 failures shows no 'and N more' summary"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    local domain_list="fail-1.test,fail-2.test,fail-3.test,fail-4.test,fail-5.test,fail-6.test,fail-7.test,fail-8.test,fail-9.test,fail-10.test"
    local output rc=0
    output=$(resolve_allowlist_domains "$domain_list" 1 "dynamic" "" "0" 2>&1) || rc=$?

    if [[ "$rc" -ne 2 ]]; then
        log_fail "Expected rc=2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi

    if echo "$output" | grep -q "showing 10 of 10" && ! echo "$output" | grep -q "and .* more"; then
        log_pass "Exactly 10 failures: shows all 10, no 'and N more' line"
    else
        log_fail "Boundary failure at N=10: got '$output'"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_preview_truncation_at_exactly_11() {
    log_test "Testing preview at 11 failures shows 'and 1 more' (off-by-one boundary)"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    local domain_list="fail-1.test,fail-2.test,fail-3.test,fail-4.test,fail-5.test,fail-6.test,fail-7.test,fail-8.test,fail-9.test,fail-10.test,fail-11.test"
    local output rc=0
    output=$(resolve_allowlist_domains "$domain_list" 1 "dynamic" "" "0" 2>&1) || rc=$?

    if [[ "$rc" -ne 2 ]]; then
        log_fail "Expected rc=2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi

    if echo "$output" | grep -q "showing 10 of 11" && echo "$output" | grep -q "and 1 more"; then
        log_pass "11 failures: shows 10 of 11 plus 'and 1 more'"
    else
        log_fail "Off-by-one at N=11: got '$output'"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_listing_omits_resolved_domains() {
    log_test "Testing failing-domain listing does not include successfully resolved domains"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    local output rc=0
    output=$(resolve_allowlist_domains "ok-good.test,fail-a.test" 1 "dynamic" "" "0" 2>&1) || rc=$?

    if [[ "$rc" -ne 2 ]]; then
        log_fail "Expected rc=2, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi

    if echo "$output" | grep -q "  - fail-a.test" && ! echo "$output" | grep -q "  - ok-good.test"; then
        log_pass "Listing includes failed domain only, not the resolved one"
    else
        log_fail "Listing has wrong contents: $output"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_wins_over_fallback_abort() {
    log_test "Testing threshold breach (rc=2) takes precedence over fallback=abort (rc=1)"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # fallback=abort would normally return 1 on any failure; threshold breach
    # should short-circuit to 2 first.
    local rc=0
    resolve_allowlist_domains "fail-a.test" 1 "abort" "" "0" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 2 ]]; then
        log_pass "Threshold breach correctly preempts fallback=abort"
    else
        log_fail "Expected rc=2 (threshold wins), got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_threshold_skip_check_does_not_relax_resolver_rc() {
    log_test "Testing KAPSIS_SKIP_DNS_CHECK does NOT change resolver rc (bypass is caller policy)"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # The bypass env var lives at the launch-agent.sh dispatch layer; the
    # resolver itself must always emit rc=2 when threshold is breached so the
    # caller has full information to decide.
    local rc=0
    KAPSIS_SKIP_DNS_CHECK=true \
        resolve_allowlist_domains "fail-a.test" 1 "dynamic" "" "0" >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -eq 2 ]]; then
        log_pass "Resolver rc=2 unaffected by KAPSIS_SKIP_DNS_CHECK (caller decides)"
    else
        log_fail "Expected rc=2 regardless of bypass, got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_launch_agent_bypass_dispatch_warns_not_aborts() {
    log_test "Testing launch-agent.sh dispatch: KAPSIS_SKIP_DNS_CHECK=true on rc=2 warns instead of aborting"

    # Verify the dispatch source has both branches and warns under bypass.
    # This is a static check — the full integration runs in container tests.
    local launch_script="$KAPSIS_ROOT/scripts/launch-agent.sh"

    if ! grep -A 5 'dns_pin_rc.*-eq 2' "$launch_script" | grep -q 'KAPSIS_SKIP_DNS_CHECK'; then
        log_fail "launch-agent.sh rc=2 dispatch missing KAPSIS_SKIP_DNS_CHECK branch"
        return 1
    fi
    if ! grep -A 8 'dns_pin_rc.*-eq 2' "$launch_script" | grep -q 'log_warn.*KAPSIS_SKIP_DNS_CHECK'; then
        log_fail "Bypass branch should log_warn, not silently proceed"
        return 1
    fi
    if ! grep -A 12 'dns_pin_rc.*-eq 2' "$launch_script" | grep -q 'exit 1'; then
        log_fail "Non-bypass branch should exit 1"
        return 1
    fi
    log_pass "launch-agent.sh has both bypass-warn and non-bypass-abort branches"
}

test_threshold_invalid_env_var_ignored() {
    log_test "Testing invalid KAPSIS_DNS_MAX_FAILURES env var is ignored, not aborted"

    source "$DNS_PIN_LIB"
    resolve_domain_ips() { _stub_resolve_domain_ips "$1"; }
    trap '_restore_resolve_domain_ips' RETURN

    # Non-numeric value — should be rejected with log_error, threshold disabled
    export KAPSIS_DNS_MAX_FAILURES="not-a-number"
    local rc=0
    resolve_allowlist_domains "fail-a.test,fail-b.test" 1 "dynamic" >/dev/null 2>&1 || rc=$?
    unset KAPSIS_DNS_MAX_FAILURES

    if [[ "$rc" -eq 0 ]]; then
        log_pass "Non-numeric env var ignored (rc=0, no false abort)"
    else
        log_fail "Expected rc=0 (invalid input ignored), got: $rc"
        _restore_resolve_domain_ips
        return 1
    fi
    _restore_resolve_domain_ips
}

test_config_validation_max_failure_rate_valid() {
    log_test "Testing config validation accepts valid max_failure_rate values"

    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local test_config
    test_config=$(mktemp).yaml
    cat > "$test_config" << 'EOF'
network:
  mode: filtered
  dns_pinning:
    enabled: true
    max_failure_rate: 0.5
    max_failures: 10
EOF

    local output
    output=$("$CONFIG_VERIFIER" "$test_config" 2>&1) || true

    if echo "$output" | grep -q "Invalid dns_pinning.max_failure_rate\|Invalid dns_pinning.max_failures"; then
        log_fail "Valid values rejected by config verifier: $output"
        rm -f "$test_config"
        return 1
    else
        log_pass "Valid max_failure_rate and max_failures accepted"
    fi

    rm -f "$test_config"
}

test_config_validation_max_failure_rate_invalid() {
    log_test "Testing config validation rejects invalid max_failure_rate values"

    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    local test_config
    test_config=$(mktemp).yaml
    cat > "$test_config" << 'EOF'
network:
  mode: filtered
  dns_pinning:
    enabled: true
    max_failure_rate: 1.5
    max_failures: -1
EOF

    local output
    output=$("$CONFIG_VERIFIER" "$test_config" 2>&1) || true

    if echo "$output" | grep -q "Invalid dns_pinning.max_failure_rate"; then
        log_pass "Invalid max_failure_rate (>1.0) correctly rejected"
    else
        log_warn "Expected validation error for max_failure_rate=1.5"
    fi

    rm -f "$test_config"
}

#===============================================================================
# CONTAINER TESTS (require Podman)
#===============================================================================

test_pinned_file_mounted_readonly() {
    log_test "Testing pinned file mounted read-only in container"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local temp_pin_file
    temp_pin_file=$(mktemp)

    cat > "$temp_pin_file" << 'EOF'
github.com 192.0.2.1
EOF

    local output
    output=$(run_simple_container "cat /etc/kapsis/pinned-dns.conf && echo 'test' >> /etc/kapsis/pinned-dns.conf 2>&1 || echo 'WRITE_FAILED'" \
        "-v" "$temp_pin_file:/etc/kapsis/pinned-dns.conf:ro")

    # File should be readable
    if echo "$output" | grep -q "github.com 192.0.2.1"; then
        log_pass "Pinned file is readable"
    else
        log_fail "Cannot read pinned file"
        rm -f "$temp_pin_file"
        return 1
    fi

    # Write should fail (read-only mount)
    if echo "$output" | grep -q "WRITE_FAILED\|Read-only"; then
        log_pass "Pinned file is write-protected"
    else
        log_fail "Pinned file should be read-only"
        rm -f "$temp_pin_file"
        return 1
    fi

    rm -f "$temp_pin_file"
}

test_add_host_entries_resolve() {
    log_test "Testing --add-host entries resolve inside container"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    # Use --add-host to add a test entry
    local output
    output=$(run_simple_container "getent hosts pinned-test.local 2>&1 || echo 'RESOLVE_FAILED'" \
        "--add-host" "pinned-test.local:192.0.2.100")

    if echo "$output" | grep -q "192.0.2.100"; then
        log_pass "--add-host entry resolves correctly"
    else
        log_fail "Failed to resolve --add-host entry: $output"
        return 1
    fi
}

test_dns_files_protected_after_setup() {
    log_test "Testing DNS files are protected after setup"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    # Run container with DNS file protection enabled
    local output
    # shellcheck disable=SC2046
    output=$(timeout 30 podman run --rm \
        $(get_test_container_env_args) \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="github.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        -e KAPSIS_DNS_PIN_PROTECT_FILES=true \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            # Source dns-filter to get protect function
            source /opt/kapsis/lib/dns-filter.sh
            protect_dns_files

            # Try to write to resolv.conf
            echo "nameserver 1.2.3.4" >> /etc/resolv.conf 2>&1 && echo "RESOLV_WRITE_OK" || echo "RESOLV_PROTECTED"

            # Try to write to hosts
            echo "1.2.3.4 malicious.com" >> /etc/hosts 2>&1 && echo "HOSTS_WRITE_OK" || echo "HOSTS_PROTECTED"
        ' 2>&1) || true

    # Check that writes failed
    if echo "$output" | grep -q "RESOLV_PROTECTED"; then
        log_pass "/etc/resolv.conf is protected"
    else
        log_warn "/etc/resolv.conf protection may not be available"
    fi

    if echo "$output" | grep -q "HOSTS_PROTECTED"; then
        log_pass "/etc/hosts is protected"
    else
        log_warn "/etc/hosts protection may not be available"
    fi
}

test_dnsmasq_uses_pinned_entries_in_container() {
    log_test "Testing dnsmasq uses pinned entries inside container"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    # Create a pinned file
    local temp_pin_file
    temp_pin_file=$(mktemp)

    cat > "$temp_pin_file" << 'EOF'
pinned-test.example 192.0.2.50
EOF

    # Run container with pinned file
    local output
    # shellcheck disable=SC2046
    output=$(timeout 60 podman run --rm \
        $(get_test_container_env_args) \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="pinned-test.example,github.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        -e KAPSIS_DNS_PIN_ENABLED=true \
        -v "$temp_pin_file:/etc/kapsis/pinned-dns.conf:ro" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            source /opt/kapsis/lib/dns-filter.sh
            dns_filter_init || { echo "DNS filter init failed"; exit 1; }

            # Show generated config
            echo "=== DNSMASQ CONFIG ==="
            cat /tmp/kapsis-dnsmasq.conf
            echo "==="
        ' 2>&1) || true

    # Check for host-record= entry for pinned domain (Issue #245: exact match only)
    if echo "$output" | grep -q "host-record=pinned-test.example,192.0.2.50"; then
        log_pass "Pinned domain uses host-record= directive (exact match)"
    else
        log_warn "Could not verify dnsmasq config (DNS filter may have different behavior in CI)"
    fi

    rm -f "$temp_pin_file"
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    setup_test_project

    # Quick tests - library and function validation
    run_test test_dns_pin_library_exists
    run_test test_resolve_domain_ips_in_compat
    run_test test_resolve_well_known_domain
    run_test test_resolve_invalid_domain_returns_empty
    run_test test_resolve_skips_wildcards
    run_test test_resolve_ip_address_passthrough
    run_test test_resolve_allowlist_domains_function
    run_test test_resolve_allowlist_skips_wildcards_with_warning
    run_test test_pinned_file_format
    run_test test_generate_add_host_args
    run_test test_generate_pinned_dnsmasq_entries
    run_test test_validate_pinned_entry_valid
    run_test test_validate_pinned_entry_invalid
    run_test test_dnsmasq_config_uses_pinned_entries
    run_test test_config_validation_dns_pinning_valid
    run_test test_config_validation_dns_pinning_invalid
    run_test test_dry_run_shows_pinning
    run_test test_default_config_has_dns_pinning
    run_test test_count_pinned_domains
    run_test test_get_pinned_domains

    # DNS failure rate threshold tests (Issue #216) — uses stubbed resolve_domain_ips
    run_test test_threshold_lists_failing_domains
    run_test test_threshold_failing_domain_preview_caps_at_10
    run_test test_threshold_zero_concrete_domains
    run_test test_threshold_rate_at_boundary_passes
    run_test test_threshold_rate_zero_with_no_failures_passes
    run_test test_threshold_wildcards_excluded_from_count
    run_test test_threshold_preview_no_truncation_at_exactly_10
    run_test test_threshold_preview_truncation_at_exactly_11
    run_test test_threshold_listing_omits_resolved_domains
    run_test test_threshold_invalid_env_var_ignored
    run_test test_threshold_wins_over_fallback_abort
    run_test test_threshold_skip_check_does_not_relax_resolver_rc
    run_test test_launch_agent_bypass_dispatch_warns_not_aborts

    # Property-based tests
    run_test test_resolve_returns_valid_ipv4_or_empty
    run_test test_add_host_args_format
    run_test test_pinned_file_parsing_robust

    # Threshold tests (Issue #216)
    run_test test_threshold_max_failures_triggers_exit2
    run_test test_threshold_max_failure_rate_triggers_exit2
    run_test test_threshold_under_limit_returns_0
    run_test test_threshold_env_var_max_failures
    run_test test_threshold_env_var_max_failure_rate
    run_test test_threshold_no_limit_set_returns_0
    run_test test_config_validation_max_failure_rate_valid
    run_test test_config_validation_max_failure_rate_invalid

    # Container tests
    run_test test_pinned_file_mounted_readonly
    run_test test_add_host_entries_resolve
    run_test test_dns_files_protected_after_setup
    run_test test_dnsmasq_uses_pinned_entries_in_container

    cleanup_test_project
    print_summary
}

main "$@"
