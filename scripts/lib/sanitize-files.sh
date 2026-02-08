#!/usr/bin/env bash
#===============================================================================
# Kapsis - File Sanitization for Invisible Character Attacks
#
# Detects and strips dangerous invisible/non-printable Unicode characters from
# files modified by AI agents before committing. This prevents:
#   - Trojan Source attacks (CVE-2021-42574)
#   - Zero-width character injection
#   - ANSI escape sequence attacks
#   - Other invisible character exploits
#
# DESIGN DECISION: Auto-clean, don't block
#   Strip dangerous characters automatically, re-stage cleaned files, log what
#   was removed, and proceed with commit. Report in commit message trailers
#   and status JSON.
#
# Usage:
#   source sanitize-files.sh
#   sanitize_staged_files "$worktree_path"
#
# Returns:
#   0 - Clean or cleaned successfully
#   1 - Fatal error only
#
# Sets global:
#   KAPSIS_SANITIZE_SUMMARY - Trailer text for commit message
#===============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_SANITIZE_FILES_LOADED:-}" ]] && return 0
readonly _KAPSIS_SANITIZE_FILES_LOADED=1

set -euo pipefail

# Script directory
_SANITIZE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
# Always source logging.sh to ensure log_debug/log_success are available
# (test-framework.sh defines its own log_info but not the full set)
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$_SANITIZE_LIB_DIR/logging.sh"
fi

source "$_SANITIZE_LIB_DIR/constants.sh"
source "$_SANITIZE_LIB_DIR/json-utils.sh"

#===============================================================================
# CONFIGURATION
#===============================================================================

# Default enabled - can be overridden with KAPSIS_SANITIZE_ENABLED=false
: "${KAPSIS_SANITIZE_ENABLED:=${KAPSIS_DEFAULT_SANITIZE_ENABLED:-true}}"

# Skip homoglyph warnings (warn-only by default)
: "${KAPSIS_SANITIZE_SKIP_HOMOGLYPHS:=false}"

# Global output for commit message trailer
export KAPSIS_SANITIZE_SUMMARY=""

#===============================================================================
# DANGEROUS CHARACTER BYTE PATTERNS
#
# All patterns defined using $'...' quoting for raw UTF-8 bytes.
# This approach works on both macOS and Linux without grep -P.
#===============================================================================

# BiDi control characters (3 bytes each) - stored as space-separated string
_BIDI_PATTERNS="$'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae' $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'"

# Zero-width characters (3 bytes each)
_ZERO_WIDTH_PATTERNS="$'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x81\xa0' $'\xe2\x81\xa3'"

# Format control characters (various byte lengths)
_FORMAT_PATTERNS="$'\xc2\xad' $'\xd8\x9c' $'\xe1\xa0\x8e' $'\xe2\x80\xa8' $'\xe2\x80\xa9'"

# BOM pattern - only stripped when NOT at byte 0
_BOM_PATTERN=$'\xef\xbb\xbf'

# Cyrillic homoglyphs for detection (warn only, don't strip)
_HOMOGLYPH_PATTERNS="$'\xd0\xb0' $'\xd1\x81' $'\xd0\xb5' $'\xd0\xbe' $'\xd1\x80'"

#===============================================================================
# INTERNAL HELPER FUNCTIONS
#===============================================================================

# Check if a file is a code file based on extension
# Usage: _sanitize_is_code_file "path/to/file.js"
_sanitize_is_code_file() {
    local file_path="$1"
    # Use the pattern from constants.sh
    local pattern="${KAPSIS_CODE_FILE_EXTENSIONS:-\.(jsx?|tsx?|py|java|go|rb|rs|[ch](pp)?|cs|sh|bash|zsh|pl|php|swift|kt|scala|lua|r|sql|proto|thrift|avdl)$}"
    if [[ "$file_path" =~ $pattern ]]; then
        return 0
    fi
    return 1
}

# Get list of staged text files (excludes binaries)
# Usage: files=$(_sanitize_get_staged_text_files)
_sanitize_get_staged_text_files() {
    # git diff --cached --numstat shows "- -" for binary files
    # We filter those out and return only text files
    git diff --cached --numstat 2>/dev/null | while IFS=$'\t' read -r added deleted file; do
        # Binary files show as "- -" for added/deleted counts
        if [[ "$added" != "-" && "$deleted" != "-" ]]; then
            echo "$file"
        fi
    done
}

# Quick pre-screen of entire staged diff for any dangerous patterns
# Returns 0 if dangerous patterns found, 1 if clean
_sanitize_quick_prescreen() {
    local diff_content
    diff_content=$(git diff --cached -p 2>/dev/null) || return 1

    # If diff is empty, nothing to check
    [[ -z "$diff_content" ]] && return 1

    # Check for BiDi patterns
    for pattern in $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae' $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'; do
        if LC_ALL=C grep -qF "$pattern" <<< "$diff_content" 2>/dev/null; then
            return 0
        fi
    done

    # Check for zero-width patterns
    for pattern in $'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x81\xa0' $'\xe2\x81\xa3'; do
        if LC_ALL=C grep -qF "$pattern" <<< "$diff_content" 2>/dev/null; then
            return 0
        fi
    done

    # Check for format patterns
    for pattern in $'\xc2\xad' $'\xd8\x9c' $'\xe1\xa0\x8e' $'\xe2\x80\xa8' $'\xe2\x80\xa9'; do
        if LC_ALL=C grep -qF "$pattern" <<< "$diff_content" 2>/dev/null; then
            return 0
        fi
    done

    # Check for BOM
    if LC_ALL=C grep -qF "$_BOM_PATTERN" <<< "$diff_content" 2>/dev/null; then
        return 0
    fi

    # Check for ANSI escape (0x1B)
    if LC_ALL=C grep -qF $'\x1b' <<< "$diff_content" 2>/dev/null; then
        return 0
    fi

    # Check for control characters (0x01-0x08, 0x0B-0x0C, 0x0E-0x1F, 0x7F)
    # Exclude TAB (0x09), LF (0x0A), CR (0x0D)
    # Note: Skip 0x00 (NUL) as it can't be represented in bash strings
    # Note: Character class syntax doesn't work reliably across shells, check individual bytes
    for ctrl in $'\x01' $'\x02' $'\x03' $'\x04' $'\x05' $'\x06' $'\x07' $'\x08' $'\x0b' $'\x0c' $'\x0e' $'\x0f' $'\x10' $'\x11' $'\x12' $'\x13' $'\x14' $'\x15' $'\x16' $'\x17' $'\x18' $'\x19' $'\x1a' $'\x1c' $'\x1d' $'\x1e' $'\x1f' $'\x7f'; do
        if LC_ALL=C grep -qF "$ctrl" <<< "$diff_content" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# Strip BiDi control characters from a file
# Usage: _sanitize_strip_bidi "file_path"
# Returns: Number of characters removed
_sanitize_strip_bidi() {
    local file="$1"
    local count=0
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Define patterns as variables for sed substitution
    local p1=$'\xe2\x80\xaa' p2=$'\xe2\x80\xab' p3=$'\xe2\x80\xac'
    local p4=$'\xe2\x80\xad' p5=$'\xe2\x80\xae' p6=$'\xe2\x81\xa6'
    local p7=$'\xe2\x81\xa7' p8=$'\xe2\x81\xa8' p9=$'\xe2\x81\xa9'

    # Count and strip each BiDi pattern
    for pattern in "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" "$p7" "$p8" "$p9"; do
        local matches
        matches=$(LC_ALL=C grep -o "$pattern" "$file" 2>/dev/null | wc -l) || matches=0
        count=$((count + matches))
    done

    if [[ $count -gt 0 ]]; then
        # Strip all BiDi chars using variables
        LC_ALL=C sed \
            -e "s/$p1//g" -e "s/$p2//g" -e "s/$p3//g" \
            -e "s/$p4//g" -e "s/$p5//g" -e "s/$p6//g" \
            -e "s/$p7//g" -e "s/$p8//g" -e "s/$p9//g" \
            "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi

    echo "$count"
}

# Strip zero-width characters from a file
# Usage: _sanitize_strip_zero_width "file_path"
# Returns: Number of characters removed
_sanitize_strip_zero_width() {
    local file="$1"
    local count=0
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Define patterns as variables
    local p1=$'\xe2\x80\x8b' p2=$'\xe2\x80\x8c' p3=$'\xe2\x80\x8d'
    local p4=$'\xe2\x81\xa0' p5=$'\xe2\x81\xa3'

    # Count occurrences
    for pattern in "$p1" "$p2" "$p3" "$p4" "$p5"; do
        local matches
        matches=$(LC_ALL=C grep -o "$pattern" "$file" 2>/dev/null | wc -l) || matches=0
        count=$((count + matches))
    done

    if [[ $count -gt 0 ]]; then
        # Strip all zero-width chars
        LC_ALL=C sed \
            -e "s/$p1//g" -e "s/$p2//g" -e "s/$p3//g" \
            -e "s/$p4//g" -e "s/$p5//g" \
            "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi

    echo "$count"
}

# Strip format control characters from a file
# Usage: _sanitize_strip_format "file_path"
# Returns: Number of characters removed
_sanitize_strip_format() {
    local file="$1"
    local count=0
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Define patterns as variables
    local p1=$'\xc2\xad' p2=$'\xd8\x9c' p3=$'\xe1\xa0\x8e'
    local p4=$'\xe2\x80\xa8' p5=$'\xe2\x80\xa9'

    # Count occurrences
    for pattern in "$p1" "$p2" "$p3" "$p4" "$p5"; do
        local matches
        matches=$(LC_ALL=C grep -o "$pattern" "$file" 2>/dev/null | wc -l) || matches=0
        count=$((count + matches))
    done

    if [[ $count -gt 0 ]]; then
        # Strip all format chars
        LC_ALL=C sed \
            -e "s/$p1//g" -e "s/$p2//g" -e "s/$p3//g" \
            -e "s/$p4//g" -e "s/$p5//g" \
            "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi

    echo "$count"
}

# Strip ANSI escape sequences from a file
# Usage: _sanitize_strip_ansi "file_path"
# Returns: Number of escape characters removed
_sanitize_strip_ansi() {
    local file="$1"
    local count
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Count ESC (0x1B) bytes
    count=$(LC_ALL=C grep -o $'\x1b' "$file" 2>/dev/null | wc -l) || count=0

    if [[ $count -gt 0 ]]; then
        # Strip ESC byte and common ANSI sequences
        # This handles both single ESC and full escape sequences like ESC[...m
        LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' -e $'s/\x1b//g' "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi

    echo "$count"
}

# Strip control characters from a file (except TAB, LF, CR)
# Usage: _sanitize_strip_control "file_path"
# Returns: Number of characters removed
_sanitize_strip_control() {
    local file="$1"
    local count=0
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Count control chars individually (regex char class doesn't work reliably)
    # Note: Skip 0x00 (NUL) as it can't be represented in bash strings
    for ctrl in $'\x01' $'\x02' $'\x03' $'\x04' $'\x05' $'\x06' $'\x07' $'\x08' $'\x0b' $'\x0c' $'\x0e' $'\x0f' $'\x10' $'\x11' $'\x12' $'\x13' $'\x14' $'\x15' $'\x16' $'\x17' $'\x18' $'\x19' $'\x1a' $'\x1c' $'\x1d' $'\x1e' $'\x1f' $'\x7f'; do
        local matches
        matches=$(LC_ALL=C grep -oF "$ctrl" "$file" 2>/dev/null | wc -l) || matches=0
        count=$((count + matches))
    done

    if [[ $count -gt 0 ]]; then
        # Use tr to delete control characters, preserving TAB (011), LF (012), CR (015)
        # Note: Skip 0x00/000 (NUL) as it causes issues with string handling
        # Note: 0x1B/033 (ESC) is handled by _sanitize_strip_ansi, not here
        # Use octal escapes which work reliably with tr
        LC_ALL=C tr -d '\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\034\035\036\037\177' < "$file" > "$temp_file"
        mv "$temp_file" "$file"
    fi

    echo "$count"
}

# Strip misplaced BOM from a file (BOM not at byte 0)
# Usage: _sanitize_strip_misplaced_bom "file_path"
# Returns: Number of BOMs removed
_sanitize_strip_misplaced_bom() {
    local file="$1"
    local bom="$_BOM_PATTERN"
    local count=0
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    # Check if file starts with BOM (legitimate UTF-8 BOM at byte 0)
    local first_bytes
    first_bytes=$(head -c 3 "$file" 2>/dev/null | LC_ALL=C od -An -tx1 | tr -d ' ')
    local bom_hex="efbbbf"
    local has_valid_bom=false

    if [[ "$first_bytes" == "$bom_hex"* ]]; then
        has_valid_bom=true
    fi

    # Count all BOMs in file
    local total_boms
    total_boms=$(LC_ALL=C grep -o "$bom" "$file" 2>/dev/null | wc -l) || total_boms=0

    if [[ "$has_valid_bom" == "true" ]]; then
        # If valid BOM at start, we remove all but one
        count=$((total_boms - 1))
        if [[ $count -gt 0 ]]; then
            # Keep first BOM, remove rest
            {
                head -c 3 "$file"
                tail -c +4 "$file" | LC_ALL=C sed "s/${bom}//g"
            } > "$temp_file"
            mv "$temp_file" "$file"
        fi
    else
        # No valid BOM at start, remove all BOMs
        count=$total_boms
        if [[ $count -gt 0 ]]; then
            LC_ALL=C sed "s/${bom}//g" "$file" > "$temp_file"
            mv "$temp_file" "$file"
        fi
    fi

    echo "$count"
}

# Check for homoglyphs (warn only, don't strip)
# Only flags Cyrillic mixed with Latin in code files
# Usage: _sanitize_check_homoglyphs "file_path"
# Returns: 0 if homoglyphs found (warning), 1 if clean
_sanitize_check_homoglyphs() {
    local file="$1"

    # Skip if configured to skip homoglyph warnings
    if [[ "$KAPSIS_SANITIZE_SKIP_HOMOGLYPHS" == "true" ]]; then
        return 1
    fi

    # Only check code files
    if ! _sanitize_is_code_file "$file"; then
        return 1
    fi

    local found_homoglyphs=false

    # Check each line for mixed Latin + Cyrillic
    # Note: Use "|| [[ -n "$line" ]]" to handle files without trailing newline
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Check if line contains Latin letters (a-zA-Z)
        local has_latin=false
        if [[ "$line" =~ [a-zA-Z] ]]; then
            has_latin=true
        fi

        # Check if line contains Cyrillic homoglyphs
        local has_cyrillic=false
        for pattern in $'\xd0\xb0' $'\xd1\x81' $'\xd0\xb5' $'\xd0\xbe' $'\xd1\x80'; do
            if LC_ALL=C grep -qF "$pattern" <<< "$line" 2>/dev/null; then
                has_cyrillic=true
                break
            fi
        done

        # Warn if both Latin and Cyrillic on same line
        if [[ "$has_latin" == "true" && "$has_cyrillic" == "true" ]]; then
            found_homoglyphs=true
            log_warn "HOMOGLYPH: $file - Line $line_num: Mixed Latin/Cyrillic characters detected"
        fi
    done < "$file"

    if [[ "$found_homoglyphs" == "true" ]]; then
        return 0
    fi

    return 1
}

# Scan and clean a single file
# Usage: _sanitize_scan_and_clean_file "file_path" "worktree_path"
# Returns: JSON-like summary of what was cleaned
_sanitize_scan_and_clean_file() {
    local file="$1"
    local worktree_path="$2"
    local full_path="$worktree_path/$file"

    # Skip if file doesn't exist (might have been deleted)
    [[ ! -f "$full_path" ]] && return 0

    local total_removed=0
    local categories=()

    # Strip BiDi characters
    local bidi_count
    bidi_count=$(_sanitize_strip_bidi "$full_path")
    if [[ $bidi_count -gt 0 ]]; then
        total_removed=$((total_removed + bidi_count))
        categories+=("${bidi_count}x bidi")
    fi

    # Strip zero-width characters
    local zw_count
    zw_count=$(_sanitize_strip_zero_width "$full_path")
    if [[ $zw_count -gt 0 ]]; then
        total_removed=$((total_removed + zw_count))
        categories+=("${zw_count}x zero-width")
    fi

    # Strip format control characters
    local format_count
    format_count=$(_sanitize_strip_format "$full_path")
    if [[ $format_count -gt 0 ]]; then
        total_removed=$((total_removed + format_count))
        categories+=("${format_count}x format")
    fi

    # Strip ANSI escapes
    local ansi_count
    ansi_count=$(_sanitize_strip_ansi "$full_path")
    if [[ $ansi_count -gt 0 ]]; then
        total_removed=$((total_removed + ansi_count))
        categories+=("${ansi_count}x ansi")
    fi

    # Strip control characters
    local ctrl_count
    ctrl_count=$(_sanitize_strip_control "$full_path")
    if [[ $ctrl_count -gt 0 ]]; then
        total_removed=$((total_removed + ctrl_count))
        categories+=("${ctrl_count}x control")
    fi

    # Strip misplaced BOMs
    local bom_count
    bom_count=$(_sanitize_strip_misplaced_bom "$full_path")
    if [[ $bom_count -gt 0 ]]; then
        total_removed=$((total_removed + bom_count))
        categories+=("${bom_count}x bom")
    fi

    # Re-stage if file was modified
    if [[ $total_removed -gt 0 ]]; then
        local cat_str
        cat_str=$(IFS=', '; echo "${categories[*]}")
        # Log to stderr so it doesn't get captured in subshell output
        log_info "Sanitized: $file (removed: $cat_str)" >&2
        cd "$worktree_path"
        git add "$file" >&2

        # Return summary to stdout (this is what caller captures)
        echo "${file}:${total_removed}:${cat_str}"
    fi
}

# Format console report of sanitization results
# Usage: _sanitize_report "$total_chars" "$total_files" "${file_summaries[@]}"
_sanitize_report() {
    local total_chars="$1"
    local total_files="$2"
    shift 2
    local summaries=("$@")

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ FILE SANITIZATION COMPLETE                                         │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo "  Dangerous characters removed: $total_chars"
    echo "  Files cleaned: $total_files"
    echo ""

    if [[ ${#summaries[@]} -gt 0 ]]; then
        echo "  Details:"
        for summary in "${summaries[@]}"; do
            local file="${summary%%:*}"
            local rest="${summary#*:}"
            local count="${rest%%:*}"
            local cats="${rest#*:}"
            echo "    - $file: $count chars ($cats)"
        done
        echo ""
    fi
}

# Write audit log entry
# Usage: _sanitize_audit_log "$worktree_path" "$total_chars" "$total_files" "${file_summaries[@]}"
_sanitize_audit_log() {
    local worktree_path="$1"
    local total_chars="$2"
    local total_files="$3"
    shift 3
    local summaries=("$@")

    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
    local audit_file="$audit_dir/sanitize-findings.jsonl"

    # Ensure audit directory exists
    mkdir -p "$audit_dir"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Escape worktree path
    local escaped_path
    escaped_path=$(json_escape_string "$worktree_path")

    # Build files array
    local files_json="["
    local first=true
    for summary in "${summaries[@]}"; do
        local file="${summary%%:*}"
        local rest="${summary#*:}"
        local count="${rest%%:*}"
        local cats="${rest#*:}"

        local escaped_file
        escaped_file=$(json_escape_string "$file")
        local escaped_cats
        escaped_cats=$(json_escape_string "$cats")

        if [[ "$first" == "true" ]]; then
            first=false
        else
            files_json+=","
        fi
        files_json+="{\"file\":\"$escaped_file\",\"chars_removed\":$count,\"categories\":\"$escaped_cats\"}"
    done
    files_json+="]"

    # Write audit entry
    cat >> "$audit_file" <<EOF
{"timestamp":"$timestamp","worktree":"$escaped_path","total_chars_removed":$total_chars,"files_cleaned":$total_files,"files":$files_json}
EOF

    log_debug "Sanitization audit logged to: $audit_file"
}

#===============================================================================
# PUBLIC API
#===============================================================================

# Sanitize all staged files in a worktree
# Usage: sanitize_staged_files "$worktree_path"
# Returns: 0 (clean or cleaned), 1 (fatal error only)
# Sets global: KAPSIS_SANITIZE_SUMMARY (for commit message trailer)
sanitize_staged_files() {
    local worktree_path="$1"

    # Reset global summary
    KAPSIS_SANITIZE_SUMMARY=""

    # Check if sanitization is enabled
    if [[ "$KAPSIS_SANITIZE_ENABLED" != "true" ]]; then
        log_debug "File sanitization disabled (KAPSIS_SANITIZE_ENABLED=$KAPSIS_SANITIZE_ENABLED)"
        return 0
    fi

    cd "$worktree_path" || return 1

    log_info "Scanning staged files for dangerous invisible characters..."

    # Get list of staged text files
    local files
    files=$(_sanitize_get_staged_text_files)

    if [[ -z "$files" ]]; then
        log_debug "No text files staged"
        return 0
    fi

    # Quick pre-screen - if no dangerous patterns in diff, only check homoglyphs
    local has_dangerous_patterns=false
    if _sanitize_quick_prescreen; then
        has_dangerous_patterns=true
        log_info "Potential dangerous characters detected, performing detailed scan..."
    fi

    # Process each file
    local total_chars=0
    local total_files=0
    local homoglyph_count=0
    local file_summaries=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        local full_path="$worktree_path/$file"
        [[ ! -f "$full_path" ]] && continue

        if [[ "$has_dangerous_patterns" == "true" ]]; then
            # Full scan and clean
            local summary
            summary=$(_sanitize_scan_and_clean_file "$file" "$worktree_path")

            if [[ -n "$summary" ]]; then
                file_summaries+=("$summary")
                local rest="${summary#*:}"
                local count="${rest%%:*}"
                total_chars=$((total_chars + count))
                total_files=$((total_files + 1))
            fi

            # Also count homoglyphs for status JSON reporting
            if _sanitize_check_homoglyphs "$full_path"; then
                homoglyph_count=$((homoglyph_count + 1))
            fi
        else
            # Only check for homoglyphs (warn-only)
            if _sanitize_check_homoglyphs "$full_path"; then
                homoglyph_count=$((homoglyph_count + 1))
            fi
        fi
    done <<< "$files"

    # Report and log if any cleaning was done
    if [[ $total_chars -gt 0 ]]; then
        _sanitize_report "$total_chars" "$total_files" "${file_summaries[@]}"
        _sanitize_audit_log "$worktree_path" "$total_chars" "$total_files" "${file_summaries[@]}"

        # Build commit message trailer
        local files_detail=""
        for summary in "${file_summaries[@]}"; do
            local file="${summary%%:*}"
            local rest="${summary#*:}"
            local cats="${rest#*:}"
            if [[ -n "$files_detail" ]]; then
                files_detail+=", "
            fi
            files_detail+="$file ($cats)"
        done

        KAPSIS_SANITIZE_SUMMARY="Sanitized-By: Kapsis ($total_chars dangerous chars removed from $total_files files)"
        KAPSIS_SANITIZE_SUMMARY+=$'\n'"Sanitized-Files: $files_detail"

        log_success "✓ Staged files sanitized"

        # Update status JSON if available
        if [[ -n "${KAPSIS_STATUS_FILE:-}" ]] && [[ -f "${KAPSIS_STATUS_FILE}" ]] && command -v jq &>/dev/null; then
            local sanitize_json
            sanitize_json=$(jq -n \
                --argjson cleaned true \
                --argjson total_removed "$total_chars" \
                --argjson files_cleaned "$total_files" \
                --argjson homoglyph_warnings "$homoglyph_count" \
                '{cleaned: $cleaned, total_removed: $total_removed, files_cleaned: $files_cleaned, homoglyph_warnings: $homoglyph_warnings}')

            # Update status file with sanitization data
            local tmp_status
            tmp_status=$(mktemp)
            if jq --argjson sanitization "$sanitize_json" '. + {sanitization: $sanitization}' "$KAPSIS_STATUS_FILE" > "$tmp_status" 2>/dev/null; then
                mv "$tmp_status" "$KAPSIS_STATUS_FILE"
                log_debug "Updated status JSON with sanitization data"
            else
                rm -f "$tmp_status"
                log_debug "Failed to update status JSON (non-fatal)"
            fi
        fi
    else
        log_debug "All staged files are clean"
    fi

    return 0
}
