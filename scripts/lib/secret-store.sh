#!/usr/bin/env bash
#===============================================================================
# Kapsis Secret Store Library
#
# Provides cross-platform access to system secret stores (keychains).
# Supports macOS Keychain and Linux secret-tool (GNOME Keyring / KDE Wallet).
#
# Usage:
#   source "$SCRIPT_DIR/lib/secret-store.sh"
#   credential=$(query_secret_store "service-name" "account-name")
#   credential=$(query_secret_store_with_fallbacks "service" "acct1,acct2" "VAR_NAME")
#
# Environment:
#   KAPSIS_SECRET_STORE_ENABLED - Set to "false" to disable secret store queries
#   KAPSIS_DEBUG               - Enable debug logging for secret store operations
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_SECRET_STORE_LOADED:-}" ]] && return 0
_KAPSIS_SECRET_STORE_LOADED=1

# Default configuration
: "${KAPSIS_SECRET_STORE_ENABLED:=true}"

#===============================================================================
# LOGGING HELPERS
#===============================================================================

# Define logging fallbacks if logging library not loaded
type log_debug &>/dev/null || log_debug() { [[ -n "${KAPSIS_DEBUG:-}" ]] && echo "[SECRET-STORE] DEBUG: $*" >&2 || true; }
type log_warn &>/dev/null || log_warn() { echo "[SECRET-STORE] WARN: $*" >&2; }
type log_error &>/dev/null || log_error() { echo "[SECRET-STORE] ERROR: $*" >&2; }

#===============================================================================
# OS DETECTION
#===============================================================================

# Detect the current OS for secret store selection
# Returns: "macos", "linux", or "unknown"
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

#===============================================================================
# SECRET STORE QUERIES
#===============================================================================

# Query system secret store for a credential
# Arguments:
#   $1 - Service name (e.g., "anthropic-api-key", "github-token")
#   $2 - Account name (optional, e.g., "user@example.com")
# Returns:
#   Credential on stdout, exit 1 if not found
# Supports:
#   - macOS: Keychain via 'security' command
#   - Linux: secret-tool (GNOME Keyring / KDE Wallet)
query_secret_store() {
    local service="$1"
    local account="${2:-}"

    # Allow disabling secret store queries
    if [[ "$KAPSIS_SECRET_STORE_ENABLED" == "false" ]]; then
        log_debug "Secret store queries disabled"
        return 1
    fi

    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            # macOS Keychain via security command
            if [[ -n "$account" ]]; then
                security find-generic-password -s "$service" -a "$account" -w 2>/dev/null
            else
                security find-generic-password -s "$service" -w 2>/dev/null
            fi
            ;;
        linux)
            # Linux secret-tool (GNOME Keyring / KDE Wallet)
            if ! command -v secret-tool &>/dev/null; then
                log_warn "secret-tool not found - install libsecret-tools"
                return 1
            fi
            if [[ -n "$account" ]]; then
                secret-tool lookup service "$service" account "$account" 2>/dev/null
            else
                secret-tool lookup service "$service" 2>/dev/null
            fi
            ;;
        *)
            log_warn "Unsupported OS for secret store: $os"
            return 1
            ;;
    esac
}

# Query secret store with fallback accounts
# Tries multiple accounts in order until one succeeds.
# Arguments:
#   $1 - Service name
#   $2 - Comma-separated list of accounts to try (e.g., "user1@email.com,user2@email.com")
#   $3 - Variable name for logging context (optional)
# Returns:
#   Credential on stdout, exit 1 if none found
# Logs:
#   Which account succeeded (obfuscated for security)
query_secret_store_with_fallbacks() {
    local service="$1"
    local accounts="$2"  # Comma-separated list or single account
    local var_name="${3:-credential}"  # For logging context

    # Allow disabling secret store queries
    if [[ "$KAPSIS_SECRET_STORE_ENABLED" == "false" ]]; then
        log_debug "Secret store queries disabled"
        return 1
    fi

    # Validate service name (alphanumeric, hyphens, underscores, dots)
    if [[ ! "$service" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_warn "Invalid service name format: $service"
        return 1
    fi

    # If no commas, treat as single account (backward compat)
    if [[ "$accounts" != *,* ]]; then
        local value
        if value=$(query_secret_store "$service" "$accounts"); then
            echo "$value"
            return 0
        fi
        return 1
    fi

    # Split accounts and try each in order
    local value
    IFS=',' read -ra account_list <<< "$accounts"
    for account in "${account_list[@]}"; do
        account="${account## }"  # Trim leading space
        account="${account%% }"  # Trim trailing space
        [[ -z "$account" ]] && continue

        # Validate account format (alphanumeric, dots, @, hyphens, underscores)
        if [[ ! "$account" =~ ^[a-zA-Z0-9@._-]+$ ]]; then
            log_debug "Skipping invalid account format: $account"
            continue
        fi

        if value=$(query_secret_store "$service" "$account"); then
            # Log which account worked (obfuscate: show first 3 chars + ***)
            local masked_account="${account:0:3}***"
            log_debug "Found $var_name via account: $masked_account"
            echo "$value"
            return 0
        fi
    done
    return 1
}

#===============================================================================
# CREDENTIAL STORAGE (optional - for setting secrets)
#===============================================================================

# Store a credential in the system secret store
# Arguments:
#   $1 - Service name
#   $2 - Account name
#   $3 - Credential value (if not provided, reads from stdin)
# Returns:
#   0 on success, 1 on failure
store_secret() {
    local service="$1"
    local account="$2"
    local value="${3:-}"

    # Read from stdin if not provided
    if [[ -z "$value" ]]; then
        read -r value
    fi

    if [[ -z "$value" ]]; then
        log_error "No credential value provided"
        return 1
    fi

    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            # Add or update keychain entry
            security add-generic-password -s "$service" -a "$account" -w "$value" -U 2>/dev/null
            ;;
        linux)
            if ! command -v secret-tool &>/dev/null; then
                log_error "secret-tool not found - install libsecret-tools"
                return 1
            fi
            echo -n "$value" | secret-tool store --label="$service" service "$service" account "$account" 2>/dev/null
            ;;
        *)
            log_error "Unsupported OS for secret store: $os"
            return 1
            ;;
    esac
}

# Delete a credential from the system secret store
# Arguments:
#   $1 - Service name
#   $2 - Account name
# Returns:
#   0 on success, 1 on failure
delete_secret() {
    local service="$1"
    local account="$2"

    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            security delete-generic-password -s "$service" -a "$account" 2>/dev/null
            ;;
        linux)
            if ! command -v secret-tool &>/dev/null; then
                log_error "secret-tool not found - install libsecret-tools"
                return 1
            fi
            secret-tool clear service "$service" account "$account" 2>/dev/null
            ;;
        *)
            log_error "Unsupported OS for secret store: $os"
            return 1
            ;;
    esac
}

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Check if secret store is available on this system
# Returns: 0 if available, 1 if not
is_secret_store_available() {
    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            command -v security &>/dev/null
            ;;
        linux)
            command -v secret-tool &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Get the name of the secret store being used
# Returns: "macOS Keychain", "GNOME Keyring/KDE Wallet", or "none"
get_secret_store_name() {
    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            echo "macOS Keychain"
            ;;
        linux)
            if command -v secret-tool &>/dev/null; then
                echo "GNOME Keyring/KDE Wallet"
            else
                echo "none"
            fi
            ;;
        *)
            echo "none"
            ;;
    esac
}
