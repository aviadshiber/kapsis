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

# Configuration file for custom hosts (optional)
# Format: host:fingerprint per line
SSH_CUSTOM_CONFIG="${SSH_CUSTOM_CONFIG:-${HOME}/.kapsis/ssh-hosts.conf}"

# TOFU (Trust On First Use) mode for enterprise hosts
# When true, unknown hosts will prompt for verification
SSH_TOFU_ENABLED="${SSH_TOFU_ENABLED:-false}"

# ==============================================================================
# Secret Storage (Platform-compatible: macOS Keychain / Linux Secret Service)
# ==============================================================================

# Cache directory for Linux (file-based fallback storage)
SSH_CACHE_DIR="${SSH_CACHE_DIR:-${HOME}/.kapsis/ssh-cache}"

# Check if running on macOS with Keychain support
ssh_has_keychain() {
    [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null
}

# Check if Linux Secret Service (secret-tool) is available
# Part of libsecret, uses GNOME Keyring or KDE Wallet
ssh_has_secret_service() {
    [[ "$(uname -s)" == "Linux" ]] && command -v secret-tool &>/dev/null
}

# Get cached SSH key
# Args: $1 = hostname
# Returns: key data or empty string
ssh_keychain_get() {
    local host="$1"
    local key_data timestamp current_time

    if ssh_has_keychain; then
        # macOS: Use Keychain (stores as hex, decode on retrieval)
        key_data=$(security find-generic-password \
            -s "$SSH_KEYCHAIN_SERVICE" \
            -a "$host" \
            -w 2>/dev/null | xxd -r -p) || return 1

        timestamp=$(security find-generic-password \
            -s "${SSH_KEYCHAIN_SERVICE}-timestamp" \
            -a "$host" \
            -w 2>/dev/null) || timestamp=0
    elif ssh_has_secret_service; then
        # Linux: Use Secret Service (GNOME Keyring/KDE Wallet)
        key_data=$(secret-tool lookup service "$SSH_KEYCHAIN_SERVICE" host "$host" 2>/dev/null) || return 1
        timestamp=$(secret-tool lookup service "${SSH_KEYCHAIN_SERVICE}-timestamp" host "$host" 2>/dev/null) || timestamp=0
    else
        # Linux fallback: Use file-based cache with secure permissions
        local cache_file="${SSH_CACHE_DIR}/${host}.key"
        local ts_file="${SSH_CACHE_DIR}/${host}.ts"

        [[ ! -f "$cache_file" ]] && return 1

        key_data=$(cat "$cache_file" 2>/dev/null) || return 1
        timestamp=$(cat "$ts_file" 2>/dev/null) || timestamp=0
    fi

    current_time=$(date +%s)
    if (( current_time - timestamp > SSH_KEY_TTL )); then
        # Key expired
        return 1
    fi

    echo "$key_data"
}

# Store SSH key in cache
# Args: $1 = hostname, $2 = key data
ssh_keychain_set() {
    local host="$1"
    local key_data="$2"
    local timestamp

    timestamp=$(date +%s)

    if ssh_has_keychain; then
        # macOS: Use Keychain
        security delete-generic-password -s "$SSH_KEYCHAIN_SERVICE" -a "$host" 2>/dev/null || true
        security delete-generic-password -s "${SSH_KEYCHAIN_SERVICE}-timestamp" -a "$host" 2>/dev/null || true

        security add-generic-password \
            -s "$SSH_KEYCHAIN_SERVICE" \
            -a "$host" \
            -w "$key_data" \
            -U 2>/dev/null || return 1

        security add-generic-password \
            -s "${SSH_KEYCHAIN_SERVICE}-timestamp" \
            -a "$host" \
            -w "$timestamp" \
            -U 2>/dev/null || return 1
    elif ssh_has_secret_service; then
        # Linux: Use Secret Service (GNOME Keyring/KDE Wallet)
        # Delete existing entries first
        secret-tool clear service "$SSH_KEYCHAIN_SERVICE" host "$host" 2>/dev/null || true
        secret-tool clear service "${SSH_KEYCHAIN_SERVICE}-timestamp" host "$host" 2>/dev/null || true

        # Store key using secret-tool (reads from stdin)
        echo -n "$key_data" | secret-tool store --label="Kapsis SSH: $host" \
            service "$SSH_KEYCHAIN_SERVICE" host "$host" 2>/dev/null || return 1

        echo -n "$timestamp" | secret-tool store --label="Kapsis SSH timestamp: $host" \
            service "${SSH_KEYCHAIN_SERVICE}-timestamp" host "$host" 2>/dev/null || return 1
    else
        # Linux fallback: Use file-based cache with secure permissions
        mkdir -p "$SSH_CACHE_DIR"
        chmod 700 "$SSH_CACHE_DIR"

        local cache_file="${SSH_CACHE_DIR}/${host}.key"
        local ts_file="${SSH_CACHE_DIR}/${host}.ts"

        # Write with secure permissions (umask)
        (umask 077; echo "$key_data" > "$cache_file")
        (umask 077; echo "$timestamp" > "$ts_file")
    fi

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
# Works with Bash 3.2+ (no associative arrays needed)
ssh_load_custom_config() {
    : # Config is read directly in ssh_get_custom_fingerprint
}

# Get custom fingerprint for a host from config file
# Args: $1 = hostname
# Returns: fingerprint or empty
ssh_get_custom_fingerprint() {
    local target_host="$1"
    local config_file="$SSH_CUSTOM_CONFIG"
    local host fingerprint

    [[ ! -f "$config_file" ]] && return 1

    while IFS=' ' read -r host fingerprint; do
        [[ -z "$host" || "$host" =~ ^# ]] && continue
        if [[ "$host" == "$target_host" ]]; then
            echo "$fingerprint"
            return 0
        fi
    done < "$config_file"

    return 1
}

# Check user's ~/.ssh/known_hosts for host entries (Fix #2: fallback source)
# This allows enterprise hosts to be verified against the user's existing known_hosts
# which was likely populated via prior SSH connections.
# Args: $1 = hostname
# Returns: known_hosts entries for the host, or 1 if not found
ssh_check_user_known_hosts() {
    local target_host="$1"
    local known_hosts_file="${HOME}/.ssh/known_hosts"

    [[ ! -f "$known_hosts_file" ]] && return 1

    # Extract entries matching target host
    # Handles:
    #   - hostname ssh-rsa/ed25519 AAAA...
    #   - [hostname]:port ssh-rsa AAAA...
    #   - hostname,ip ssh-rsa AAAA...
    local entries
    entries=$(grep -E "^${target_host}[, ]|^\[${target_host}\]" "$known_hosts_file" 2>/dev/null || true)

    if [[ -n "$entries" ]]; then
        echo "$entries"
        return 0
    fi

    return 1
}

# Compute fingerprints from user known_hosts entries
# Args: $1 = hostname
# Returns: SHA256 fingerprints for the host's keys
ssh_get_user_known_hosts_fingerprints() {
    local target_host="$1"
    local entries

    entries=$(ssh_check_user_known_hosts "$target_host") || return 1

    # Compute fingerprint for each entry
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local fp
        fp=$(ssh_compute_fingerprint "$line" 2>/dev/null)
        [[ -n "$fp" ]] && echo "$fp"
    done <<< "$entries"

    return 0
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
}

# Get fingerprints for a host (official or custom)
# Args: $1 = hostname
ssh_get_official_fingerprints() {
    local host="$1"
    local custom_fp

    # Check custom config first (works with Bash 3.2+)
    if custom_fp=$(ssh_get_custom_fingerprint "$host"); then
        echo "$custom_fp"
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
            # Unknown host - try user's ~/.ssh/known_hosts as fallback (Fix #2)
            # This allows verification against hosts the user has previously connected to
            local user_fps
            if user_fps=$(ssh_get_user_known_hosts_fingerprints "$host"); then
                echo "  (verified via ~/.ssh/known_hosts)" >&2
                echo "$user_fps"
                return 0
            fi
            # No official fingerprints available
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

        # Skip if fingerprint computation failed (empty result)
        if [[ -z "$actual_fp" ]]; then
            echo "WARNING: Could not compute fingerprint for key" >&2
            continue
        fi

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

    # Output all verified keys (handle empty array)
    if [[ ${#verified_keys[@]} -gt 0 ]]; then
        printf '%s\n' "${verified_keys[@]}"
    fi
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

# Clear all cached SSH keys from Keychain/cache
ssh_clear_cache() {
    local hosts=("${@:-github.com gitlab.com bitbucket.org}")
    local host

    for host in "${hosts[@]}"; do
        if ssh_has_keychain; then
            # macOS: Use Keychain
            security delete-generic-password -s "$SSH_KEYCHAIN_SERVICE" -a "$host" 2>/dev/null || true
            security delete-generic-password -s "${SSH_KEYCHAIN_SERVICE}-timestamp" -a "$host" 2>/dev/null || true
        elif ssh_has_secret_service; then
            # Linux: Use Secret Service
            secret-tool clear service "$SSH_KEYCHAIN_SERVICE" host "$host" 2>/dev/null || true
            secret-tool clear service "${SSH_KEYCHAIN_SERVICE}-timestamp" host "$host" 2>/dev/null || true
        else
            # Linux fallback: Use file-based cache
            rm -f "${SSH_CACHE_DIR}/${host}.key" "${SSH_CACHE_DIR}/${host}.ts" 2>/dev/null || true
        fi
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
            echo "Enterprise hosts (e.g., git.company.com):"
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
