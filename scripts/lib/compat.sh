#!/usr/bin/env bash
#===============================================================================
# compat.sh - Cross-platform compatibility helpers
#
# Provides consistent behavior across macOS and Linux for common operations
# where command syntax differs between platforms.
#===============================================================================

[[ -n "${_KAPSIS_COMPAT_LOADED:-}" ]] && return 0
_KAPSIS_COMPAT_LOADED=1

# Detect OS once at source time
_KAPSIS_OS="$(uname)"

#-------------------------------------------------------------------------------
# get_file_size <file>
#
# Returns file size in bytes. Works on both macOS and Linux.
# Returns 0 if file doesn't exist or on error.
#-------------------------------------------------------------------------------
get_file_size() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo 0
        return
    fi

    if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
        stat -f%z "$file" 2>/dev/null || echo 0
    else
        stat -c%s "$file" 2>/dev/null || echo 0
    fi
}

#-------------------------------------------------------------------------------
# get_file_mode <file>
#
# Returns file permission mode as octal string (e.g., "644", "600", "755").
# Works on both macOS and Linux.
# Returns empty string if file doesn't exist or on error.
#-------------------------------------------------------------------------------
get_file_mode() {
    local file="$1"

    if [[ ! -e "$file" ]]; then
        echo ""
        return 1
    fi

    if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
        stat -f "%Lp" "$file" 2>/dev/null || echo ""
    else
        stat -c "%a" "$file" 2>/dev/null || echo ""
    fi
}

#-------------------------------------------------------------------------------
# get_file_mtime <file>
#
# Returns file modification time as Unix epoch (seconds since 1970).
# Works on both macOS and Linux.
# Returns empty string if file doesn't exist or on error.
#-------------------------------------------------------------------------------
get_file_mtime() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi

    if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
        stat -f "%m" "$file" 2>/dev/null
    else
        stat -c "%Y" "$file" 2>/dev/null
    fi
}

#-------------------------------------------------------------------------------
# is_macos
#
# Returns 0 (true) if running on macOS, 1 (false) otherwise.
#-------------------------------------------------------------------------------
is_macos() {
    [[ "$_KAPSIS_OS" == "Darwin" ]]
}

#-------------------------------------------------------------------------------
# is_linux
#
# Returns 0 (true) if running on Linux, 1 (false) otherwise.
#-------------------------------------------------------------------------------
is_linux() {
    [[ "$_KAPSIS_OS" == "Linux" ]]
}

#-------------------------------------------------------------------------------
# get_file_md5 <file>
#
# Returns MD5 hash of file. Works on both macOS and Linux.
# macOS uses 'md5', Linux uses 'md5sum'.
#-------------------------------------------------------------------------------
get_file_md5() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi

    if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
        md5 -q "$file" 2>/dev/null
    else
        md5sum "$file" 2>/dev/null | cut -d' ' -f1
    fi
}

#-------------------------------------------------------------------------------
# expand_path_vars <path>
#
# Expands environment variables and tilde in a path string.
# Supports:
#   - ~ (tilde) -> $HOME
#   - $HOME -> actual home directory path
#   - $KAPSIS_ROOT -> actual Kapsis installation path
#
# This is used to expand paths read from YAML config files where
# shell expansion doesn't occur automatically.
#
# Security: Uses explicit variable substitution instead of eval to
# prevent command injection attacks.
#-------------------------------------------------------------------------------
expand_path_vars() {
    local path="$1"

    # Expand tilde at start of path
    path="${path/#\~/$HOME}"

    # Expand $HOME (with optional braces)
    path="${path//\$\{HOME\}/$HOME}"
    path="${path//\$HOME/$HOME}"

    # Expand $KAPSIS_ROOT (with optional braces)
    if [[ -n "${KAPSIS_ROOT:-}" ]]; then
        path="${path//\$\{KAPSIS_ROOT\}/$KAPSIS_ROOT}"
        path="${path//\$KAPSIS_ROOT/$KAPSIS_ROOT}"
    fi

    echo "$path"
}

#-------------------------------------------------------------------------------
# resolve_domain_ips <domain> [timeout]
#
# Resolves a domain to IPv4 addresses using available DNS tools.
# Returns: newline-separated IPv4 addresses, empty on failure
#
# Used for DNS IP pinning - resolves domains on the trusted host before
# container launch to prevent DNS manipulation attacks inside containers.
#
# Fallback chain: dig > host > nslookup > python3
# Skips wildcard domains (cannot be pre-resolved).
#-------------------------------------------------------------------------------
resolve_domain_ips() {
    local domain="$1"
    local timeout="${2:-5}"
    local ips=""

    # Validate domain is not empty
    [[ -z "$domain" ]] && return 0

    # Skip wildcard domains — cannot be pre-resolved
    [[ "$domain" == "*."* ]] && return 0

    # Skip domains that are already IP addresses
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$domain"
        return 0
    fi

    # Try dig (available on macOS + most Linux)
    if command -v dig &>/dev/null; then
        ips=$(dig +short +time="$timeout" +tries=1 A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -10)
    fi

    # Try host
    if [[ -z "$ips" ]] && command -v host &>/dev/null; then
        # host command doesn't have a timeout option on all platforms
        if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
            ips=$(host -t A "$domain" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -10)
        else
            ips=$(timeout "$timeout" host -t A "$domain" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -10)
        fi
    fi

    # Try nslookup
    if [[ -z "$ips" ]] && command -v nslookup &>/dev/null; then
        if [[ "$_KAPSIS_OS" == "Darwin" ]]; then
            ips=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -10)
        else
            ips=$(timeout "$timeout" nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -10)
        fi
    fi

    # Try python3 (always available on modern systems)
    # Security: pass domain as sys.argv[1] to prevent command injection
    if [[ -z "$ips" ]] && command -v python3 &>/dev/null; then
        ips=$(python3 -c "
import socket, sys
try:
    results = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
    seen = set()
    for r in results:
        ip = r[4][0]
        if ip not in seen:
            seen.add(ip)
            print(ip)
except Exception:
    sys.exit(0)
" "$domain" 2>/dev/null | head -10)
    fi

    echo "$ips"
}
