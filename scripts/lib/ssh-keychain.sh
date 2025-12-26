#!/usr/bin/env bash
# ==============================================================================
# SSH Host Key Verification with Keychain Integration
# ==============================================================================
# Automatically fetches, verifies, and caches SSH host keys for known providers.
# Keys are verified against official API fingerprints to prevent MITM attacks.
#
# Usage:
#   source scripts/lib/ssh-keychain.sh
#   ssh_verify_and_cache_keys
#   ssh_generate_known_hosts "/path/to/known_hosts"
# ==============================================================================

set -euo pipefail

# Keychain service name for SSH keys
SSH_KEYCHAIN_SERVICE="${SSH_KEYCHAIN_SERVICE:-kapsis-ssh-known-hosts}"

# Default TTL: 24 hours in seconds
SSH_KEY_TTL="${SSH_KEY_TTL:-86400}"

# Custom fingerprints can be loaded from config
# Note: Bash 4+ required for associative arrays
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    declare -A SSH_CUSTOM_FINGERPRINTS
fi

# Configuration file for custom hosts (optional)
# Format: host:fingerprint per line
SSH_CUSTOM_CONFIG="${SSH_CUSTOM_CONFIG:-${HOME}/.kapsis/ssh-hosts.conf}"

# TOFU (Trust On First Use) mode for enterprise hosts
# When true, unknown hosts will prompt for verification
SSH_TOFU_ENABLED="${SSH_TOFU_ENABLED:-false}"

# ==============================================================================
# Keychain Operations (macOS)
# ==============================================================================

# Check if running on macOS with Keychain support
ssh_has_keychain() {
    [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null
}

# Get cached SSH key from Keychain
# Args: $1 = hostname
# Returns: key data or empty string
ssh_keychain_get() {
    local host="$1"
    local key_data timestamp current_time

    if ! ssh_has_keychain; then
        return 1
    fi

    # Try to get the key
    key_data=$(security find-generic-password \
        -s "$SSH_KEYCHAIN_SERVICE" \
        -a "$host" \
        -w 2>/dev/null) || return 1

    # Check timestamp (stored as separate entry)
    timestamp=$(security find-generic-password \
        -s "${SSH_KEYCHAIN_SERVICE}-timestamp" \
        -a "$host" \
        -w 2>/dev/null) || timestamp=0

    current_time=$(date +%s)
    if (( current_time - timestamp > SSH_KEY_TTL )); then
        # Key expired
        return 1
    fi

    echo "$key_data"
}

# Store SSH key in Keychain
# Args: $1 = hostname, $2 = key data
ssh_keychain_set() {
    local host="$1"
    local key_data="$2"
    local timestamp

    if ! ssh_has_keychain; then
        return 1
    fi

    timestamp=$(date +%s)

    # Delete existing entries (ignore errors)
    security delete-generic-password -s "$SSH_KEYCHAIN_SERVICE" -a "$host" 2>/dev/null || true
    security delete-generic-password -s "${SSH_KEYCHAIN_SERVICE}-timestamp" -a "$host" 2>/dev/null || true

    # Store key
    security add-generic-password \
        -s "$SSH_KEYCHAIN_SERVICE" \
        -a "$host" \
        -w "$key_data" \
        -U 2>/dev/null || return 1

    # Store timestamp
    security add-generic-password \
        -s "${SSH_KEYCHAIN_SERVICE}-timestamp" \
        -a "$host" \
        -w "$timestamp" \
        -U 2>/dev/null || return 1

    return 0
}

# ==============================================================================
# Fingerprint Verification
# ==============================================================================

# Fetch official SSH fingerprints from GitHub
# Returns: JSON with fingerprints or empty
ssh_fetch_github_fingerprints() {
    local response
    response=$(curl -sS --max-time 10 "https://api.github.com/meta" 2>/dev/null) || return 1
    echo "$response" | jq -r '.ssh_key_fingerprints | to_entries[] | "\(.key):\(.value)"' 2>/dev/null
}

# Fetch official SSH fingerprints from GitLab
ssh_fetch_gitlab_fingerprints() {
    local response
    # GitLab's metadata API requires authentication for some instances
    # For gitlab.com, we can use their documented fingerprints
    # https://docs.gitlab.com/ee/user/gitlab_com/index.html#ssh-host-keys-fingerprints
    cat <<'EOF'
SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ
SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw
SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8
EOF
}

# Fetch official SSH fingerprints for Bitbucket
ssh_fetch_bitbucket_fingerprints() {
    # Bitbucket's official fingerprints
    # https://support.atlassian.com/bitbucket-cloud/docs/configure-ssh-and-two-step-verification/
    cat <<'EOF'
SHA256:zzXQOXSRBEiUtuE8AikoYKwbHaxvSc0ojez9YXaGp1A
SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E
EOF
}

# Load custom fingerprints from config file
# Config format: hostname SHA256:fingerprint
ssh_load_custom_config() {
    local config_file="${1:-$SSH_CUSTOM_CONFIG}"

    [[ ! -f "$config_file" ]] && return 0

    while IFS=' ' read -r host fingerprint; do
        [[ -z "$host" || "$host" =~ ^# ]] && continue
        if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
            SSH_CUSTOM_FINGERPRINTS["$host"]="$fingerprint"
        fi
    done < "$config_file"
}

# Add a custom host fingerprint (persists to config file)
# Args: $1 = hostname, $2 = fingerprint (SHA256:...)
ssh_add_custom_host() {
    local host="$1"
    local fingerprint="$2"
    local config_dir

    config_dir=$(dirname "$SSH_CUSTOM_CONFIG")
    mkdir -p "$config_dir"

    # Remove existing entry for this host
    if [[ -f "$SSH_CUSTOM_CONFIG" ]]; then
        grep -v "^${host} " "$SSH_CUSTOM_CONFIG" > "${SSH_CUSTOM_CONFIG}.tmp" || true
        mv "${SSH_CUSTOM_CONFIG}.tmp" "$SSH_CUSTOM_CONFIG"
    fi

    # Add new entry
    echo "$host $fingerprint" >> "$SSH_CUSTOM_CONFIG"
    chmod 600 "$SSH_CUSTOM_CONFIG"

    echo "Added custom host: $host -> $fingerprint" >&2

    # Update in-memory if bash 4+
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        SSH_CUSTOM_FINGERPRINTS["$host"]="$fingerprint"
    fi
}

# Get fingerprints for a host (official or custom)
# Args: $1 = hostname
ssh_get_official_fingerprints() {
    local host="$1"

    # Check custom config first
    ssh_load_custom_config
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]] && [[ -n "${SSH_CUSTOM_FINGERPRINTS[$host]:-}" ]]; then
        echo "${SSH_CUSTOM_FINGERPRINTS[$host]}"
        return 0
    fi

    case "$host" in
        github.com)
            ssh_fetch_github_fingerprints
            ;;
        gitlab.com)
            ssh_fetch_gitlab_fingerprints
            ;;
        bitbucket.org)
            ssh_fetch_bitbucket_fingerprints
            ;;
        *)
            # Unknown host - no official fingerprints available
            return 1
            ;;
    esac
}

# TOFU: Trust On First Use for enterprise hosts
# Scans key, shows fingerprint, asks for confirmation
# Args: $1 = hostname
ssh_tofu_verify() {
    local host="$1"
    local key_data fingerprint response

    echo "Enterprise host detected: $host" >&2
    echo "No official fingerprint source available." >&2
    echo "" >&2

    # Fetch key
    key_data=$(ssh-keyscan -t ed25519,rsa,ecdsa "$host" 2>/dev/null) || {
        echo "ERROR: Could not scan SSH key for $host" >&2
        return 1
    }

    # Show fingerprints
    echo "SSH Host Key Fingerprints for $host:" >&2
    echo "============================================" >&2
    while IFS= read -r key_line; do
        [[ -z "$key_line" ]] && continue
        [[ "$key_line" =~ ^# ]] && continue
        fingerprint=$(ssh_compute_fingerprint "$key_line")
        key_type=$(echo "$key_line" | awk '{print $2}')
        echo "  $key_type: $fingerprint" >&2
    done <<< "$key_data"
    echo "============================================" >&2
    echo "" >&2

    if [[ "$SSH_TOFU_ENABLED" == "true" ]]; then
        # Interactive mode - ask for confirmation
        echo "IMPORTANT: Verify these fingerprints with your IT administrator!" >&2
        echo -n "Do you trust this host? (yes/no): " >&2
        read -r response

        if [[ "$response" == "yes" ]]; then
            # Store the primary fingerprint (ed25519 preferred, then rsa)
            local primary_key
            primary_key=$(echo "$key_data" | grep -E "ed25519|rsa" | head -1)
            fingerprint=$(ssh_compute_fingerprint "$primary_key")
            ssh_add_custom_host "$host" "$fingerprint"
            echo "$key_data"
            return 0
        else
            echo "Host not trusted. Skipping." >&2
            return 1
        fi
    else
        # Non-interactive mode - provide instructions
        echo "To trust this host, add it to your config:" >&2
        local primary_key
        primary_key=$(echo "$key_data" | grep -E "ed25519|rsa" | head -1)
        fingerprint=$(ssh_compute_fingerprint "$primary_key")
        echo "" >&2
        echo "  echo '$host $fingerprint' >> ~/.kapsis/ssh-hosts.conf" >&2
        echo "" >&2
        echo "Or run with SSH_TOFU_ENABLED=true for interactive verification." >&2
        return 1
    fi
}

# Compute fingerprint from SSH key
# Args: $1 = key line from ssh-keyscan
ssh_compute_fingerprint() {
    local key_line="$1"
    echo "$key_line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
}

# Verify a key against official fingerprints
# Args: $1 = hostname, $2 = key data from ssh-keyscan
ssh_verify_key() {
    local host="$1"
    local key_data="$2"
    local official_fps actual_fp

    # Get official fingerprints
    official_fps=$(ssh_get_official_fingerprints "$host") || {
        echo "WARNING: No official fingerprints available for $host" >&2
        return 1
    }

    # Verify each key line
    while IFS= read -r key_line; do
        [[ -z "$key_line" ]] && continue
        [[ "$key_line" =~ ^# ]] && continue

        actual_fp=$(ssh_compute_fingerprint "$key_line")

        # Check if fingerprint matches any official one
        if echo "$official_fps" | grep -qF "${actual_fp#SHA256:}"; then
            return 0  # Match found
        fi

        # Also try with full SHA256: prefix
        if echo "$official_fps" | grep -qF "$actual_fp"; then
            return 0
        fi
    done <<< "$key_data"

    echo "ERROR: SSH key fingerprint mismatch for $host - possible MITM attack!" >&2
    echo "Scanned fingerprint: $actual_fp" >&2
    echo "Official fingerprints:" >&2
    echo "$official_fps" >&2
    return 1
}

# ==============================================================================
# Main Functions
# ==============================================================================

# Verify and cache SSH keys for known providers
# Args: $@ = list of hosts (default: github.com gitlab.com bitbucket.org)
ssh_verify_and_cache_keys() {
    local hosts=("${@:-github.com gitlab.com bitbucket.org}")
    local host key_data cached_key
    local verified_keys=()

    for host in "${hosts[@]}"; do
        echo "Verifying SSH host key for $host..." >&2

        # Check cache first
        if cached_key=$(ssh_keychain_get "$host" 2>/dev/null); then
            echo "  Using cached key from Keychain" >&2
            verified_keys+=("$cached_key")
            continue
        fi

        # Fetch key via ssh-keyscan
        echo "  Fetching key via ssh-keyscan..." >&2
        key_data=$(ssh-keyscan -t ed25519,rsa,ecdsa "$host" 2>/dev/null) || {
            echo "  WARNING: Could not scan SSH key for $host" >&2
            continue
        }

        if [[ -z "$key_data" ]]; then
            echo "  WARNING: No SSH key returned for $host" >&2
            continue
        fi

        # Verify against official fingerprints
        echo "  Verifying against official fingerprints..." >&2
        if ssh_verify_key "$host" "$key_data"; then
            echo "  ✓ Key verified successfully" >&2

            # Cache in keychain
            if ssh_keychain_set "$host" "$key_data"; then
                echo "  ✓ Cached in Keychain" >&2
            fi

            verified_keys+=("$key_data")
        else
            # No official fingerprints - try TOFU for enterprise hosts
            if tofu_result=$(ssh_tofu_verify "$host"); then
                echo "  ✓ Key trusted via TOFU" >&2
                if ssh_keychain_set "$host" "$tofu_result"; then
                    echo "  ✓ Cached in Keychain" >&2
                fi
                verified_keys+=("$tofu_result")
            else
                echo "  ✗ Key verification FAILED - skipping $host" >&2
            fi
        fi
    done

    # Output all verified keys
    printf '%s\n' "${verified_keys[@]}"
}

# Generate known_hosts file from verified keys
# Args: $1 = output file path
ssh_generate_known_hosts() {
    local output_file="$1"
    local hosts=("${@:2}")  # Additional hosts after output file

    [[ ${#hosts[@]} -eq 0 ]] && hosts=(github.com gitlab.com bitbucket.org)

    # Create parent directory if needed
    mkdir -p "$(dirname "$output_file")"

    # Generate with proper permissions
    umask 0077
    ssh_verify_and_cache_keys "${hosts[@]}" > "$output_file"

    if [[ -s "$output_file" ]]; then
        echo "Generated $output_file with $(wc -l < "$output_file") entries" >&2
        return 0
    else
        echo "WARNING: Generated empty known_hosts file" >&2
        return 1
    fi
}

# Clear all cached SSH keys from Keychain
ssh_clear_cache() {
    local hosts=("${@:-github.com gitlab.com bitbucket.org}")
    local host

    if ! ssh_has_keychain; then
        echo "Keychain not available on this platform" >&2
        return 1
    fi

    for host in "${hosts[@]}"; do
        security delete-generic-password -s "$SSH_KEYCHAIN_SERVICE" -a "$host" 2>/dev/null || true
        security delete-generic-password -s "${SSH_KEYCHAIN_SERVICE}-timestamp" -a "$host" 2>/dev/null || true
        echo "Cleared cache for $host" >&2
    done
}

# ==============================================================================
# CLI Interface (when run directly)
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        verify)
            shift
            ssh_verify_and_cache_keys "$@"
            ;;
        generate)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 generate <output-file> [hosts...]" >&2
                exit 1
            fi
            ssh_generate_known_hosts "$2" "${@:3}"
            ;;
        add-host)
            # Interactive mode to add enterprise/custom host
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 add-host <hostname>" >&2
                exit 1
            fi
            SSH_TOFU_ENABLED=true ssh_tofu_verify "$2"
            ;;
        list-hosts)
            # List configured custom hosts
            if [[ -f "$SSH_CUSTOM_CONFIG" ]]; then
                echo "Custom SSH hosts ($SSH_CUSTOM_CONFIG):"
                cat "$SSH_CUSTOM_CONFIG"
            else
                echo "No custom hosts configured."
                echo "Add hosts with: $0 add-host <hostname>"
            fi
            ;;
        clear)
            shift
            ssh_clear_cache "$@"
            ;;
        *)
            echo "SSH Host Key Verification Tool"
            echo ""
            echo "Usage: $0 <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  verify [hosts...]           Verify and cache SSH keys for known providers"
            echo "  generate <file> [hosts...]  Generate known_hosts file"
            echo "  add-host <hostname>         Add enterprise/custom host (interactive TOFU)"
            echo "  list-hosts                  List configured custom hosts"
            echo "  clear [hosts...]            Clear cached keys from Keychain"
            echo ""
            echo "Known providers (automatic verification):"
            echo "  github.com, gitlab.com, bitbucket.org"
            echo ""
            echo "Enterprise hosts (e.g., git.taboolasyndication.com):"
            echo "  Use 'add-host' to interactively verify and trust"
            echo ""
            echo "Environment variables:"
            echo "  SSH_KEYCHAIN_SERVICE   Keychain service name (default: kapsis-ssh-known-hosts)"
            echo "  SSH_KEY_TTL            Cache TTL in seconds (default: 86400)"
            echo "  SSH_CUSTOM_CONFIG      Config file path (default: ~/.kapsis/ssh-hosts.conf)"
            echo "  SSH_TOFU_ENABLED       Enable Trust On First Use (default: false)"
            ;;
    esac
fi
