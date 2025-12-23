#!/usr/bin/env bash
#===============================================================================
# compat.sh - Cross-platform compatibility helpers
#
# Provides consistent behavior across macOS and Linux for common operations
# where command syntax differs between platforms.
#===============================================================================

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
