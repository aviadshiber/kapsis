#!/usr/bin/env bash
#===============================================================================
# Kapsis DNS Pinning Library
#
# Resolves DNS allowlist domains on the trusted host before container launch
# and generates pinned IP configurations to prevent DNS manipulation attacks.
#
# Attack vectors mitigated:
#   1. Agent kills dnsmasq, rewrites /etc/resolv.conf
#   2. Upstream DNS poisoning returns malicious IPs
#   3. Agent modifies /etc/hosts after dnsmasq killed
#
# Solution:
#   - Resolve domains on host (trusted) before container launch
#   - Pin IPs in container via dnsmasq address=/ directives
#   - Add --add-host flags as belt-and-suspenders
#   - Protect /etc/resolv.conf and /etc/hosts from modification
#
# Usage:
#   source "$SCRIPT_DIR/lib/dns-pin.sh"
#   resolved=$(resolve_allowlist_domains "$domains" 5 "dynamic")
#   write_pinned_dns_file "/tmp/pinned.conf" "$resolved"
#   add_host_args=$(generate_add_host_args "/tmp/pinned.conf")
#===============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_DNS_PIN_LOADED:-}" ]] && return 0
_KAPSIS_DNS_PIN_LOADED=1

# Source compat.sh for resolve_domain_ips() if not already sourced
_DNS_PIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! type resolve_domain_ips &>/dev/null; then
    source "$_DNS_PIN_DIR/compat.sh"
fi

#===============================================================================
# LOGGING HELPERS
#===============================================================================

# Define logging fallbacks if not already defined
type log_info &>/dev/null || log_info() { echo "[DNS-PIN] INFO: $*" >&2; }
type log_debug &>/dev/null || log_debug() { [[ -n "${KAPSIS_DEBUG:-}" ]] && echo "[DNS-PIN] DEBUG: $*" >&2 || true; }
type log_warn &>/dev/null || log_warn() { echo "[DNS-PIN] WARN: $*" >&2; }
type log_error &>/dev/null || log_error() { echo "[DNS-PIN] ERROR: $*" >&2; }
type log_success &>/dev/null || log_success() { echo "[DNS-PIN] SUCCESS: $*" >&2; }

#===============================================================================
# DOMAIN RESOLUTION
#===============================================================================

# resolve_allowlist_domains <comma-domains> [timeout] [fallback]
#
# Resolves comma-separated domains to IP addresses on the host.
# Skips wildcards (emitting security warning) and returns pinned mappings.
#
# Arguments:
#   $1 - Comma-separated list of domains (from KAPSIS_DNS_ALLOWLIST)
#   $2 - Resolution timeout in seconds (default: 5)
#   $3 - Fallback behavior: "dynamic" (default) or "abort"
#
# Output:
#   domain IP1 IP2 ...
#   (one line per domain with resolved IPs, space-separated)
#
# Returns: 0 on success (even partial), 1 on complete failure with abort mode
resolve_allowlist_domains() {
    local domain_list="$1"
    local timeout="${2:-5}"
    local fallback="${3:-dynamic}"

    [[ -z "$domain_list" ]] && return 0

    local resolved_count=0
    local failed_count=0
    local wildcard_count=0

    log_debug "Resolving domains with timeout=${timeout}s, fallback=${fallback}"

    # Split by comma and process each domain
    IFS=',' read -ra domains <<< "$domain_list"

    for domain in "${domains[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$domain" ]] && continue

        # Skip and warn about wildcards
        if [[ "$domain" == "*."* ]]; then
            log_warn "SECURITY: Wildcard '$domain' cannot be IP-pinned - vulnerable to DNS manipulation"
            log_warn "  Consider using concrete subdomains instead of wildcards for better security"
            ((wildcard_count++))
            continue
        fi

        # Skip if already an IP address (just echo it back)
        if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$domain $domain"
            ((resolved_count++))
            continue
        fi

        # Resolve domain
        local ips
        ips=$(resolve_domain_ips "$domain" "$timeout")

        if [[ -n "$ips" ]]; then
            # Convert newlines to spaces for output format
            local ip_list
            ip_list=$(echo "$ips" | tr '\n' ' ' | sed 's/ $//')
            echo "$domain $ip_list"
            log_debug "Resolved $domain -> $ip_list"
            ((resolved_count++))
        else
            log_warn "Failed to resolve domain: $domain"
            ((failed_count++))
        fi
    done

    log_info "DNS pinning: resolved $resolved_count domains, $failed_count failed, $wildcard_count wildcards skipped"

    # Handle failures based on fallback mode
    if [[ "$failed_count" -gt 0 ]] && [[ "$fallback" == "abort" ]]; then
        log_error "DNS resolution failed with fallback=abort"
        return 1
    fi

    return 0
}

#===============================================================================
# PINNED FILE GENERATION
#===============================================================================

# write_pinned_dns_file <output-file> <resolved-output>
#
# Writes resolved domain->IP mappings to a file for mounting in container.
# Format: domain IP1 IP2 ... (one per line)
#
# Arguments:
#   $1 - Path to output file
#   $2 - Output from resolve_allowlist_domains (multiline)
#
# Returns: 0 on success, 1 on write failure
write_pinned_dns_file() {
    local output_file="$1"
    local resolved_data="$2"

    [[ -z "$output_file" ]] && return 1
    [[ -z "$resolved_data" ]] && return 0

    # Write with header
    {
        echo "# Kapsis DNS Pinning - Resolved on host at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Format: domain IP1 IP2 ..."
        echo "# Mounted read-only at /etc/kapsis/pinned-dns.conf"
        echo ""
        echo "$resolved_data"
    } > "$output_file"

    # Set restrictive permissions (owner read/write only)
    chmod 600 "$output_file"

    log_debug "Wrote pinned DNS file: $output_file"
    return 0
}

#===============================================================================
# PODMAN ARGUMENTS GENERATION
#===============================================================================

# generate_add_host_args <pinned-file>
#
# Generates --add-host arguments for Podman from pinned DNS file.
# This provides belt-and-suspenders protection by adding entries to /etc/hosts.
#
# Arguments:
#   $1 - Path to pinned DNS file
#
# Output:
#   --add-host domain:IP
#   (one line per domain:IP pair)
#
# Returns: 0 on success
generate_add_host_args() {
    local pinned_file="$1"

    [[ ! -f "$pinned_file" ]] && return 0

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* ]] && continue

        # Parse: domain IP1 IP2 ...
        local domain ips
        domain=$(echo "$line" | awk '{print $1}')
        ips=$(echo "$line" | cut -d' ' -f2-)

        [[ -z "$domain" || -z "$ips" ]] && continue

        # Generate --add-host for first IP only (Podman limitation)
        local first_ip
        first_ip=$(echo "$ips" | awk '{print $1}')
        echo "--add-host"
        echo "${domain}:${first_ip}"
    done < "$pinned_file"
}

# generate_pinned_dnsmasq_entries <pinned-file>
#
# Generates dnsmasq address=/ directives from pinned DNS file.
# Used by dns-filter.sh to create static IP bindings.
#
# Arguments:
#   $1 - Path to pinned DNS file
#
# Output:
#   address=/domain/IP
#   (one line per domain:IP pair)
#
# Returns: 0 on success
generate_pinned_dnsmasq_entries() {
    local pinned_file="$1"

    [[ ! -f "$pinned_file" ]] && return 0

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* ]] && continue

        # Parse: domain IP1 IP2 ...
        local domain
        domain=$(echo "$line" | awk '{print $1}')
        local ips
        ips=$(echo "$line" | cut -d' ' -f2-)

        [[ -z "$domain" || -z "$ips" ]] && continue

        # Generate address= directive for each IP
        for ip in $ips; do
            echo "address=/${domain}/${ip}"
        done
    done < "$pinned_file"
}

# get_pinned_domains <pinned-file>
#
# Returns list of domains that have been pinned (for skipping in dynamic rules).
#
# Arguments:
#   $1 - Path to pinned DNS file
#
# Output:
#   domain names, one per line
get_pinned_domains() {
    local pinned_file="$1"

    [[ ! -f "$pinned_file" ]] && return 0

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* ]] && continue
        # Extract domain (first field)
        echo "$line" | awk '{print $1}'
    done < "$pinned_file"
}

# count_pinned_domains <pinned-file>
#
# Returns the count of pinned domains.
count_pinned_domains() {
    local pinned_file="$1"

    [[ ! -f "$pinned_file" ]] && echo 0 && return 0

    grep -v '^#' "$pinned_file" | grep -v '^$' | wc -l | tr -d ' '
}

#===============================================================================
# VALIDATION
#===============================================================================

# validate_pinned_entry <line>
#
# Validates a single pinned DNS entry line.
# Returns 0 if valid, 1 if invalid.
validate_pinned_entry() {
    local line="$1"

    # Skip empty lines and comments
    [[ -z "$line" || "$line" == "#"* ]] && return 0

    # Parse domain
    local domain
    domain=$(echo "$line" | awk '{print $1}')
    [[ -z "$domain" ]] && return 1

    # Parse IPs
    local ips
    ips=$(echo "$line" | cut -d' ' -f2-)
    [[ -z "$ips" ]] && return 1

    # Validate each IP
    for ip in $ips; do
        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            return 1
        fi
        # Validate octets are in range 0-255
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
    done

    return 0
}

# validate_pinned_file <pinned-file>
#
# Validates all entries in a pinned DNS file.
# Returns 0 if all valid, 1 if any invalid.
validate_pinned_file() {
    local pinned_file="$1"
    local invalid_count=0

    [[ ! -f "$pinned_file" ]] && return 0

    while IFS= read -r line; do
        if ! validate_pinned_entry "$line"; then
            log_warn "Invalid pinned DNS entry: $line"
            ((invalid_count++))
        fi
    done < "$pinned_file"

    [[ "$invalid_count" -eq 0 ]]
}
