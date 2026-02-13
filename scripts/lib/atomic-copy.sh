#!/usr/bin/env bash
#===============================================================================
# atomic-copy.sh - Race-condition-safe file and directory copying
#
# Provides atomic copy operations with validation for use in container
# staging, where host files mounted via bind mount may be written to
# concurrently. Prevents truncated copies that cause application crashes.
#
# Key properties:
#   - Atomic write via temp file + mv (no partial-read window)
#   - Size validation against source (catches truncation)
#   - JSON validation for .json files (when jq available)
#   - Cross-platform (macOS + Linux) via compat.sh
#
# Usage:
#   source atomic-copy.sh
#   atomic_copy_file "/src/file" "/dst/file"
#   atomic_copy_dir "/src/dir" "/dst/dir"
#
# See also: GitHub issue #151
#===============================================================================

# Source guard
[[ -n "${_KAPSIS_ATOMIC_COPY_LOADED:-}" ]] && return 0
_KAPSIS_ATOMIC_COPY_LOADED=1

_ATOMIC_COPY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source compat.sh for cross-platform get_file_size()
if [[ -z "${_KAPSIS_COMPAT_LOADED:-}" ]]; then
    if [[ -f "$_ATOMIC_COPY_LIB_DIR/compat.sh" ]]; then
        source "$_ATOMIC_COPY_LIB_DIR/compat.sh"
    fi
fi

# Source logging if available
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    if [[ -f "$_ATOMIC_COPY_LIB_DIR/logging.sh" ]]; then
        source "$_ATOMIC_COPY_LIB_DIR/logging.sh"
    else
        # Minimal fallback
        log_info() { echo "[INFO] $*"; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_debug() { :; }
    fi
fi

#-------------------------------------------------------------------------------
# _atomic_validate_file <src> <dst>
#
# Validates that dst matches src in size, and for .json files, is valid JSON.
# Returns: 0 = valid, 1 = invalid
#-------------------------------------------------------------------------------
_atomic_validate_file() {
    local src="$1"
    local dst="$2"

    # Size comparison via cross-platform get_file_size()
    local src_size dst_size
    if command -v get_file_size &>/dev/null; then
        src_size=$(get_file_size "$src")
        dst_size=$(get_file_size "$dst")
    else
        # Portable fallback: wc -c works everywhere
        src_size=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
        dst_size=$(wc -c < "$dst" 2>/dev/null | tr -d ' ')
    fi

    if [[ "${src_size:-0}" -ne "${dst_size:-0}" ]]; then
        log_debug "atomic-copy: size mismatch: src=${src_size} dst=${dst_size} for $(basename "$dst")"
        return 1
    fi

    # JSON validation for .json files
    if [[ "$dst" == *.json ]] && command -v jq &>/dev/null; then
        if ! jq empty "$dst" 2>/dev/null; then
            log_debug "atomic-copy: JSON validation failed for $(basename "$dst")"
            return 1
        fi
    fi

    return 0
}

#-------------------------------------------------------------------------------
# _atomic_count_files <dir>
#
# Counts regular files (recursively) in a directory. Portable across platforms.
# Returns: file count as integer
#-------------------------------------------------------------------------------
_atomic_count_files() {
    local dir="$1"
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

#-------------------------------------------------------------------------------
# atomic_copy_file <src> <dst>
#
# Atomically copies a single file with validation.
#
# Strategy:
#   1. Copy to temp file in same directory as destination
#   2. Atomic rename (mv) to final location
#   3. Validate size match and JSON integrity
#
# Returns: 0 = success, 1 = failed (file still copied but validation failed)
#-------------------------------------------------------------------------------
atomic_copy_file() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" ]]; then
        log_warn "atomic_copy_file: source not found: $src"
        return 1
    fi

    # Ensure destination directory exists
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    # Create temp file in same directory as dst (required for atomic mv)
    local tmp_file
    tmp_file=$(mktemp "$(dirname "$dst")/.atomic-copy-XXXXXX") || {
        log_warn "atomic_copy_file: mktemp failed for $(basename "$dst")"
        # Fallback to direct copy
        cp "$src" "$dst" 2>/dev/null || true
        chmod u+w "$dst" 2>/dev/null || true
        return 1
    }

    # Copy to temp file
    if cp "$src" "$tmp_file" 2>/dev/null; then
        # Atomic rename to destination
        mv "$tmp_file" "$dst"
        chmod u+w "$dst" 2>/dev/null || true

        # Validate the copy
        if _atomic_validate_file "$src" "$dst"; then
            return 0
        fi

        log_warn "atomic_copy_file: validation failed for $(basename "$dst") (size or JSON mismatch)"
        return 1
    else
        rm -f "$tmp_file" 2>/dev/null || true
        log_warn "atomic_copy_file: cp failed for $(basename "$dst")"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# atomic_copy_dir <src_dir> <dst_dir>
#
# Atomically copies a directory's contents with validation.
#
# Strategy:
#   1. Copy to temp directory alongside destination
#   2. Validate file count matches
#   3. Atomic replace: rm old, mv temp to final
#
# Returns: 0 = success, 1 = failed (fallback copy used)
#-------------------------------------------------------------------------------
atomic_copy_dir() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" ]]; then
        log_warn "atomic_copy_dir: source not found: $src"
        return 1
    fi

    # Create temp directory alongside destination (same filesystem for atomic mv)
    local tmp_dir
    tmp_dir=$(mktemp -d "$(dirname "$dst")/.atomic-copy-dir-XXXXXX") || {
        log_warn "atomic_copy_dir: mktemp failed for $(basename "$dst")"
        # Fallback to direct copy
        mkdir -p "$dst" 2>/dev/null || true
        cp -r "$src/." "$dst/" 2>/dev/null || true
        chmod -R u+w "$dst" 2>/dev/null || true
        return 1
    }

    # Copy contents to temp directory
    if cp -r "$src/." "$tmp_dir/" 2>/dev/null; then
        chmod -R u+w "$tmp_dir" 2>/dev/null || true

        # Validate: compare file counts
        local src_count tmp_count
        src_count=$(_atomic_count_files "$src")
        tmp_count=$(_atomic_count_files "$tmp_dir")

        if [[ "$src_count" -eq "$tmp_count" ]]; then
            # Replace destination atomically
            rm -rf "$dst"
            mv "$tmp_dir" "$dst"
            return 0
        fi

        log_warn "atomic_copy_dir: file count mismatch (src=${src_count} tmp=${tmp_count}) for $(basename "$dst")"
        rm -rf "$tmp_dir" 2>/dev/null || true
    else
        rm -rf "$tmp_dir" 2>/dev/null || true
        log_warn "atomic_copy_dir: cp failed for $(basename "$dst")"
    fi

    # Fallback: copy directly (better to have potentially incomplete files than none)
    log_warn "atomic_copy_dir: using fallback copy for $(basename "$dst")"
    mkdir -p "$dst" 2>/dev/null || true
    cp -r "$src/." "$dst/" 2>/dev/null || true
    chmod -R u+w "$dst" 2>/dev/null || true
    return 1
}
