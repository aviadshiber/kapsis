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
# Returns: 0 = success, 1 = failed (corrupt destination removed on validation failure)
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

    # Create temp file in same directory as dst (required for atomic mv).
    # Issue #328: capture mktemp stderr so an unwritable parent (read-only
    # HOME, restrictive perms, broken bind mount) gives a debuggable error
    # instead of a silent "mktemp failed".
    local tmp_file mktemp_err
    mktemp_err=$(mktemp "$(dirname "$dst")/.atomic-copy-XXXXXX" 2>&1) && tmp_file="$mktemp_err"

    if [[ -z "${tmp_file:-}" ]] || [[ ! -e "$tmp_file" ]]; then
        log_warn "atomic_copy_file: mktemp failed for $(basename "$dst"): ${mktemp_err:-no stderr}"

        # Issue #328: cross-filesystem fallback. dirname(dst) may be RO
        # (HOME on a read-only mount); try a writable scratch dir and
        # do a best-effort non-atomic copy directly to dst. The copy
        # itself still requires dst's parent to accept writes — if it
        # doesn't, we surface that error too rather than swallowing.
        local fallback_err
        fallback_err=$(cp -p "$src" "$dst" 2>&1) || {
            log_warn "atomic_copy_file: fallback cp failed for $(basename "$dst"): ${fallback_err:-no stderr}"
            return 1
        }
        chmod u+w "$dst" 2>/dev/null || true
        if _atomic_validate_file "$src" "$dst"; then
            return 0
        fi
        log_warn "atomic_copy_file: validation failed for $(basename "$dst") (fallback path) — removing corrupt copy"
        rm -f "$dst" 2>/dev/null || true
        return 1
    fi

    # Copy to temp file
    local cp_err
    if cp_err=$(cp -p "$src" "$tmp_file" 2>&1); then
        # Atomic rename to destination
        mv "$tmp_file" "$dst"
        chmod u+w "$dst" 2>/dev/null || true

        # Validate the copy
        if _atomic_validate_file "$src" "$dst"; then
            return 0
        fi

        # Rollback: remove corrupt destination to prevent use of bad data (issue #164)
        log_warn "atomic_copy_file: validation failed for $(basename "$dst") — removing corrupt copy"
        rm -f "$dst" 2>/dev/null || true
        return 1
    else
        rm -f "$tmp_file" 2>/dev/null || true
        log_warn "atomic_copy_file: cp failed for $(basename "$dst"): ${cp_err:-no stderr}"
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

    # Create temp directory alongside destination (same filesystem for atomic mv).
    # Issue #328: capture mktemp stderr so an unwritable parent gives a
    # debuggable error instead of a silent "mktemp failed".
    local tmp_dir mktemp_err
    mktemp_err=$(mktemp -d "$(dirname "$dst")/.atomic-copy-dir-XXXXXX" 2>&1) && tmp_dir="$mktemp_err"

    if [[ -z "${tmp_dir:-}" ]] || [[ ! -d "$tmp_dir" ]]; then
        log_warn "atomic_copy_dir: mktemp failed for $(basename "$dst"): ${mktemp_err:-no stderr}"

        # Issue #328: cross-filesystem fallback. dirname(dst) may be RO; try
        # a writable scratch outside the destination tree and stage there
        # before a best-effort, non-atomic copy into dst. Atomicity is lost
        # but the alternative is a guaranteed failure.
        local scratch_base="${KAPSIS_SCRATCH_DIR:-/tmp}"
        mkdir -p "$scratch_base" 2>/dev/null || true
        local scratch_err
        scratch_err=$(mktemp -d "${scratch_base}/.kapsis-atomic-copy-XXXXXX" 2>&1) && tmp_dir="$scratch_err" || tmp_dir=""

        if [[ -z "$tmp_dir" ]] || [[ ! -d "$tmp_dir" ]]; then
            log_warn "atomic_copy_dir: scratch mktemp in ${scratch_base} also failed: ${scratch_err:-no stderr}"
            # Last resort: copy directly to dst (matches prior behaviour
            # but with surfaced stderr).
            local direct_err
            mkdir -p "$dst" 2>/dev/null || true
            direct_err=$(cp -rp "$src/." "$dst/" 2>&1) || log_warn "atomic_copy_dir: direct cp failed for $(basename "$dst"): ${direct_err:-no stderr}"
            find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
            return 1
        fi

        log_debug "atomic_copy_dir: using cross-fs scratch ${tmp_dir} for $(basename "$dst")"
        local cp_err
        if cp_err=$(cp -rp "$src/." "$tmp_dir/" 2>&1); then
            find "$tmp_dir" -type d -exec chmod u+w {} + 2>/dev/null || true
            # Non-atomic: rsync-style copy from scratch into dst. mv across
            # filesystems would degrade to cp+rm anyway.
            mkdir -p "$dst" 2>/dev/null || true
            local stage_err
            stage_err=$(cp -rp "$tmp_dir/." "$dst/" 2>&1) || {
                log_warn "atomic_copy_dir: stage cp into $dst failed: ${stage_err:-no stderr}"
                rm -rf "$tmp_dir" 2>/dev/null || true
                return 1
            }
            find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
            rm -rf "$tmp_dir" 2>/dev/null || true

            local src_count dst_count
            src_count=$(_atomic_count_files "$src")
            dst_count=$(_atomic_count_files "$dst")
            if [[ "$src_count" -eq "$dst_count" ]]; then
                return 0
            fi
            log_warn "atomic_copy_dir: scratch-path file count mismatch (src=${src_count} dst=${dst_count}) for $(basename "$dst")"
            return 1
        fi
        log_warn "atomic_copy_dir: scratch-stage cp failed for $(basename "$dst"): ${cp_err:-no stderr}"
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    # Copy contents to temp directory (preserve permissions)
    local cp_err
    if cp_err=$(cp -rp "$src/." "$tmp_dir/" 2>&1); then
        find "$tmp_dir" -type d -exec chmod u+w {} + 2>/dev/null || true

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
        log_warn "atomic_copy_dir: cp failed for $(basename "$dst"): ${cp_err:-no stderr}"
    fi

    # Fallback: copy directly (better to have potentially incomplete files than none)
    log_warn "atomic_copy_dir: using fallback copy for $(basename "$dst")"
    local fallback_err
    mkdir -p "$dst" 2>/dev/null || true
    fallback_err=$(cp -rp "$src/." "$dst/" 2>&1) || log_warn "atomic_copy_dir: fallback cp failed for $(basename "$dst"): ${fallback_err:-no stderr}"
    find "$dst" -type d -exec chmod u+w {} + 2>/dev/null || true
    return 1
}
