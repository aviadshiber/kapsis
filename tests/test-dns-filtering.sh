#!/usr/bin/env bash
#===============================================================================
# Test: DNS-Based Network Filtering (filtered mode)
#
# Verifies DNS-based network filtering using dnsmasq works correctly.
# Part of Phase 1.5 security feature - enables controlled network access.
#
# Tests:
#   - Filtered mode flag validation
#   - Allowlist parsing from config
#   - dnsmasq config generation
#   - Allowed domains resolve successfully
#   - Blocked domains return NXDOMAIN
#   - Integration with launch-agent.sh
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

LAUNCH_SCRIPT="$KAPSIS_ROOT/scripts/launch-agent.sh"
DNS_FILTER_LIB="$KAPSIS_ROOT/scripts/lib/dns-filter.sh"
ALLOWLIST_CONFIG="$KAPSIS_ROOT/configs/network-allowlist.yaml"

#===============================================================================
# QUICK TESTS (no container required)
#===============================================================================

test_network_mode_filtered_flag_accepted() {
    log_test "Testing --network-mode=filtered is accepted"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode filtered --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed with network-mode=filtered"
    assert_contains "$output" "Network: filtered" "Should log filtered network mode"
    assert_contains "$output" "DNS-based allowlist" "Should mention DNS-based allowlist"
}

test_network_mode_filtered_env_vars() {
    log_test "Testing filtered mode sets correct environment variables"

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode filtered --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "KAPSIS_NETWORK_MODE=filtered" "Should set KAPSIS_NETWORK_MODE"
}

test_network_mode_validation_includes_filtered() {
    log_test "Testing network mode validation includes 'filtered'"

    local output
    local exit_code=0

    # Test invalid mode shows all valid options including filtered
    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --network-mode "invalid" --task "test" 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should fail with invalid network mode"
    assert_contains "$output" "filtered" "Error should mention 'filtered' as valid option"
}

test_dns_filter_library_exists() {
    log_test "Testing DNS filter library exists"

    assert_file_exists "$DNS_FILTER_LIB" "DNS filter library should exist"
    assert_command_succeeds "bash -n '$DNS_FILTER_LIB'" "DNS filter library should be valid bash"
}

test_default_allowlist_exists() {
    log_test "Testing default network allowlist config exists"

    assert_file_exists "$ALLOWLIST_CONFIG" "Default allowlist config should exist"
}

test_default_allowlist_has_required_domains() {
    log_test "Testing default allowlist contains essential domains"

    # Check for essential domains
    assert_file_contains "$ALLOWLIST_CONFIG" "github.com" "Should include github.com"
    assert_file_contains "$ALLOWLIST_CONFIG" "npmjs.org" "Should include npmjs.org"
    assert_file_contains "$ALLOWLIST_CONFIG" "pypi.org" "Should include pypi.org"
    assert_file_contains "$ALLOWLIST_CONFIG" "repo1.maven.org" "Should include Maven Central"
    assert_file_contains "$ALLOWLIST_CONFIG" "api.anthropic.com" "Should include Anthropic API"
}

test_allowlist_mode_is_filtered() {
    log_test "Testing default allowlist sets mode to filtered"

    local mode
    mode=$(yq -r '.network.mode' "$ALLOWLIST_CONFIG")

    assert_equals "filtered" "$mode" "Default allowlist should use filtered mode"
}

test_dns_filter_domain_validation() {
    log_test "Testing domain validation function"

    # Source the library for testing
    # Disable logging to avoid noise
    export KAPSIS_DEBUG=""
    source "$DNS_FILTER_LIB"

    # Valid domains
    assert_command_succeeds "validate_domain_pattern 'github.com'" "github.com should be valid"
    assert_command_succeeds "validate_domain_pattern '*.github.com'" "*.github.com should be valid"
    assert_command_succeeds "validate_domain_pattern 'sub.domain.example.org'" "Subdomain should be valid"
    assert_command_succeeds "validate_domain_pattern 'registry-1.docker.io'" "Hyphenated domain should be valid"

    # Invalid domains
    assert_command_fails "validate_domain_pattern '*'" "Bare wildcard should be invalid"
    assert_command_fails "validate_domain_pattern ''" "Empty string should be invalid"
    assert_command_fails "validate_domain_pattern '#comment'" "Comment should be invalid"
}

test_dnsmasq_config_generation() {
    log_test "Testing dnsmasq config generation"

    # Source the library
    export KAPSIS_DEBUG=""
    source "$DNS_FILTER_LIB"

    # Set up temp config location
    local temp_config
    temp_config=$(mktemp)
    export KAPSIS_DNS_CONFIG_FILE="$temp_config"

    # Set an allowlist via environment
    export KAPSIS_DNS_ALLOWLIST="github.com,*.gitlab.com,npmjs.org"
    export KAPSIS_DNS_SERVERS="8.8.8.8"

    # Generate config
    generate_dnsmasq_config

    # Verify config was created
    assert_file_exists "$temp_config" "dnsmasq config should be created"

    # Verify config contents
    assert_file_contains "$temp_config" "server=/github.com/8.8.8.8" "Should forward github.com"
    assert_file_contains "$temp_config" "server=/.gitlab.com/8.8.8.8" "Should forward *.gitlab.com"
    assert_file_contains "$temp_config" "server=/npmjs.org/8.8.8.8" "Should forward npmjs.org"
    assert_file_contains "$temp_config" "address=/#/0.0.0.0" "Should block all other domains"

    # Cleanup
    rm -f "$temp_config"
    unset KAPSIS_DNS_ALLOWLIST KAPSIS_DNS_SERVERS KAPSIS_DNS_CONFIG_FILE
}

test_dnsmasq_config_from_yaml() {
    log_test "Testing dnsmasq config generation from YAML file"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    # Source the library
    export KAPSIS_DEBUG=""
    source "$DNS_FILTER_LIB"

    # Set up temp config location
    local temp_config
    temp_config=$(mktemp)
    export KAPSIS_DNS_CONFIG_FILE="$temp_config"

    # Generate config from the default allowlist
    generate_dnsmasq_config "$ALLOWLIST_CONFIG"

    # Verify config was created with content from YAML
    assert_file_exists "$temp_config" "dnsmasq config should be created"
    assert_file_contains "$temp_config" "github.com" "Should include domains from YAML"

    # Cleanup
    rm -f "$temp_config"
    unset KAPSIS_DNS_CONFIG_FILE
}

test_config_parsing_extracts_allowlist() {
    log_test "Testing launch-agent.sh extracts allowlist from config"

    # Skip if yq not available
    if ! command -v yq &>/dev/null; then
        log_skip "yq not installed"
        return 0
    fi

    # Create a test config with allowlist
    local test_config
    test_config=$(mktemp --suffix=.yaml)
    cat > "$test_config" << 'EOF'
agent:
  command: bash
network:
  mode: filtered
  allowlist:
    hosts:
      - github.com
      - gitlab.com
    registries:
      - npmjs.org
EOF

    local output
    local exit_code=0

    output=$("$LAUNCH_SCRIPT" "$TEST_PROJECT" --config "$test_config" --task "test" --dry-run 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "Should succeed"
    assert_contains "$output" "KAPSIS_DNS_ALLOWLIST" "Should set DNS allowlist env var"

    # Cleanup
    rm -f "$test_config"
}

#===============================================================================
# CONTAINER TESTS (require Podman)
# These verify DNS filtering actually works at runtime
#===============================================================================

test_container_has_dnsmasq() {
    log_test "Testing container image has dnsmasq installed"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    output=$(podman run --rm "$KAPSIS_TEST_IMAGE" which dnsmasq 2>&1) || true

    assert_contains "$output" "/usr/sbin/dnsmasq" "dnsmasq should be installed in container"
}

test_dns_filter_start_inside_container() {
    log_test "Testing DNS filter can start inside container"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    local exit_code=0

    # Run container and try to start DNS filtering
    output=$(timeout 30 podman run --rm \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="github.com,gitlab.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            source /opt/kapsis/lib/dns-filter.sh
            generate_dnsmasq_config
            cat /tmp/kapsis-dnsmasq.conf
        ' 2>&1) || exit_code=$?

    assert_equals 0 "$exit_code" "DNS filter setup should succeed"
    assert_contains "$output" "server=/github.com/8.8.8.8" "Config should forward github.com"
    assert_contains "$output" "address=/#/0.0.0.0" "Config should block other domains"
}

test_filtered_mode_allows_allowlisted_domain() {
    log_test "Testing filtered mode allows allowlisted domains to resolve"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    local exit_code=0

    # Run container with filtered mode and test DNS resolution
    # Note: This test requires network access to actually resolve domains
    output=$(timeout 60 podman run --rm \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="github.com,*.github.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            # Source and initialize DNS filtering
            source /opt/kapsis/lib/dns-filter.sh
            dns_filter_init || { echo "DNS filter init failed"; exit 1; }

            # Test that github.com resolves
            if nslookup github.com 127.0.0.1 2>&1 | grep -qE "Address.*[0-9]+\.[0-9]+"; then
                echo "ALLOWED_DOMAIN_RESOLVED"
            else
                echo "ALLOWED_DOMAIN_FAILED"
                # Show actual output for debugging
                nslookup github.com 127.0.0.1 2>&1 || true
            fi
        ' 2>&1) || exit_code=$?

    assert_contains "$output" "ALLOWED_DOMAIN_RESOLVED" "Allowlisted domain should resolve"
}

test_filtered_mode_blocks_non_allowlisted_domain() {
    log_test "Testing filtered mode blocks non-allowlisted domains"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    local exit_code=0

    # Run container with filtered mode and test DNS resolution for blocked domain
    output=$(timeout 60 podman run --rm \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="github.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            # Source and initialize DNS filtering
            source /opt/kapsis/lib/dns-filter.sh
            dns_filter_init || { echo "DNS filter init failed"; exit 1; }

            # Test that a random domain is blocked (returns 0.0.0.0 or NXDOMAIN)
            result=$(nslookup definitely-not-allowed-domain-xyz123.com 127.0.0.1 2>&1)
            if echo "$result" | grep -qE "0\.0\.0\.0|NXDOMAIN|SERVFAIL|can.t find"; then
                echo "BLOCKED_DOMAIN_REJECTED"
            else
                echo "BLOCKED_DOMAIN_ALLOWED"
                echo "Result was: $result"
            fi
        ' 2>&1) || exit_code=$?

    assert_contains "$output" "BLOCKED_DOMAIN_REJECTED" "Non-allowlisted domain should be blocked"
}

test_entrypoint_starts_dns_filter() {
    log_test "Testing entrypoint starts DNS filter in filtered mode"

    # Skip in quick mode
    if [[ "${KAPSIS_QUICK_TESTS:-}" == "1" ]]; then
        log_skip "Container test in quick mode"
        return 0
    fi

    if ! skip_if_no_container; then
        return 0
    fi

    local output
    local exit_code=0

    # Run container through entrypoint with filtered mode
    output=$(timeout 60 podman run --rm \
        -e KAPSIS_NETWORK_MODE=filtered \
        -e KAPSIS_DNS_ALLOWLIST="github.com,gitlab.com" \
        -e KAPSIS_DNS_SERVERS="8.8.8.8" \
        -e KAPSIS_AGENT_ID="test-dns" \
        -e KAPSIS_PROJECT="test" \
        "$KAPSIS_TEST_IMAGE" \
        bash -c '
            # Check if dnsmasq is running
            if pgrep dnsmasq >/dev/null; then
                echo "DNSMASQ_RUNNING"
            else
                echo "DNSMASQ_NOT_RUNNING"
            fi

            # Check resolv.conf
            if grep -q "127.0.0.1" /etc/resolv.conf; then
                echo "RESOLV_CONF_CONFIGURED"
            else
                echo "RESOLV_CONF_NOT_CONFIGURED"
                cat /etc/resolv.conf
            fi
        ' 2>&1) || exit_code=$?

    assert_contains "$output" "DNSMASQ_RUNNING" "dnsmasq should be running"
    assert_contains "$output" "RESOLV_CONF_CONFIGURED" "resolv.conf should point to localhost"
}

#===============================================================================
# RUN TESTS
#===============================================================================

main() {
    setup_test_project

    # Quick tests (no container) - validate flag handling and config parsing
    run_test test_network_mode_filtered_flag_accepted
    run_test test_network_mode_filtered_env_vars
    run_test test_network_mode_validation_includes_filtered
    run_test test_dns_filter_library_exists
    run_test test_default_allowlist_exists
    run_test test_default_allowlist_has_required_domains
    run_test test_allowlist_mode_is_filtered
    run_test test_dns_filter_domain_validation
    run_test test_dnsmasq_config_generation
    run_test test_dnsmasq_config_from_yaml
    run_test test_config_parsing_extracts_allowlist

    # Container tests - verify DNS filtering works at runtime
    run_test test_container_has_dnsmasq
    run_test test_dns_filter_start_inside_container
    run_test test_filtered_mode_allows_allowlisted_domain
    run_test test_filtered_mode_blocks_non_allowlisted_domain
    run_test test_entrypoint_starts_dns_filter

    cleanup_test_project
    print_summary
}

main "$@"
