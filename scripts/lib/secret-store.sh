#!/usr/bin/env bash
#===============================================================================
# Kapsis - Secret Store Library
#
# Cross-platform functions for querying system secret stores:
# - macOS: Keychain Access via 'security' command
# - Linux: GNOME Keyring / KDE Wallet via 'secret-tool'
#
# Functions:
#   detect_os                          - Detect OS for secret store selection
#   query_secret_store                 - Query a single service/account
#   query_secret_store_with_fallbacks  - Try multiple accounts in order
#
# Usage:
#   source "$KAPSIS_HOME/lib/secret-store.sh"
#   if value=$(query_secret_store "my-service" "my-account"); then
#       echo "Got secret: $value"
#   fi
#===============================================================================

# shellcheck disable=SC2034
# SC2034: Variables may be used by scripts that source this file

# Guard against multiple sourcing
if [[ -n "${_KAPSIS_SECRET_STORE_LOADED:-}" ]]; then
    return 0
fi
readonly _KAPSIS_SECRET_STORE_LOADED=1

#===============================================================================
# LOGGING FALLBACK
#===============================================================================
# Use logging library if available, otherwise provide minimal fallback

if ! type log_warn &>/dev/null; then
    log_warn() { echo "[WARN] $*" >&2; }
fi
if ! type log_debug &>/dev/null; then
    log_debug() { [[ -n "${KAPSIS_DEBUG:-}" ]] && echo "[DEBUG] $*" >&2; }
fi

#===============================================================================
# OS DETECTION
#===============================================================================

# Detect the current OS for secret store selection
# Usage: detect_os
# Returns: "macos" | "linux" | "unknown"
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
# Usage: query_secret_store "service" ["account"]
# Returns: credential on stdout, exit 1 if not found
# Supports: macOS Keychain, Linux secret-tool
query_secret_store() {
    local service="$1"
    local account="${2:-}"
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
# Usage: query_secret_store_with_fallbacks "service" "account1,account2,..." "var_name"
# Returns: credential on stdout, exit 1 if none found
# Logs which account succeeded (obfuscated for security)
query_secret_store_with_fallbacks() {
    local service="$1"
    local accounts="$2"  # Comma-separated list or single account
    local var_name="${3:-}"  # For logging context
    local value

    # If no commas, treat as single account (backward compat)
    if [[ "$accounts" != *,* ]]; then
        if value=$(query_secret_store "$service" "$accounts"); then
            echo "$value"
            return 0
        fi
        return 1
    fi

    # Split accounts and try each in order
    IFS=',' read -ra account_list <<< "$accounts"
    for account in "${account_list[@]}"; do
        account="${account## }"  # Trim leading space
        account="${account%% }"  # Trim trailing space
        [[ -z "$account" ]] && continue

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
