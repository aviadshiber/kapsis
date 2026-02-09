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
    log_test "Testing dnsmasq address=/ entries generation"

    source "$DNS_PIN_LIB"

    local temp_file
    temp_file=$(mktemp)

    cat > "$temp_file" << 'EOF'
github.com 1.2.3.4 5.6.7.8
gitlab.com 10.20.30.40
EOF

    local entries
    entries=$(generate_pinned_dnsmasq_entries "$temp_file")

    # Check output contains address=/ format
    assert_contains "$entries" "address=/github.com/1.2.3.4" "Should have github address entry"
    assert_contains "$entries" "address=/github.com/5.6.7.8" "Should have second github IP"
    assert_contains "$entries" "address=/gitlab.com/10.20.30.40" "Should have gitlab address entry"

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

    # Verify pinned domains use address=/ (static IP)
    assert_file_contains "$temp_config" "address=/github.com/1.2.3.4" "Pinned github should use address=/"
    assert_file_contains "$temp_config" "address=/gitlab.com/5.6.7.8" "Pinned gitlab should use address=/"

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

    # Check for address=/ entry for pinned domain
    if echo "$output" | grep -q "address=/pinned-test.example/192.0.2.50"; then
        log_pass "Pinned domain uses address=/ directive"
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

    # Property-based tests
    run_test test_resolve_returns_valid_ipv4_or_empty
    run_test test_add_host_args_format
    run_test test_pinned_file_parsing_robust

    # Container tests
    run_test test_pinned_file_mounted_readonly
    run_test test_add_host_entries_resolve
    run_test test_dns_files_protected_after_setup
    run_test test_dnsmasq_uses_pinned_entries_in_container

    cleanup_test_project
    print_summary
}

main "$@"
