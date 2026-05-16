#!/usr/bin/env bash
#===============================================================================
# Kapsis - Stage Handoff Security Library (Issue #85)
#
# Functions for validating, sanitizing, and transferring artifacts between
# stages of a multi-stage workflow.  Each stage runs in an isolated container;
# this library enforces the security boundary at the handoff point so that
# Stage 1 (research, network-enabled, no credentials) cannot inject executable
# or prompt-injection content into Stage 2 (implementation, air-gapped,
# has credentials).
#
# Source this library in staged-launch.sh (not in containers).
#===============================================================================

[[ -n "${_KAPSIS_STAGE_HANDOFF_LOADED:-}" ]] && return 0
readonly _KAPSIS_STAGE_HANDOFF_LOADED=1

_STAGE_HANDOFF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_STAGE_HANDOFF_DIR/constants.sh"

# Logging stubs — replaced when logging.sh is sourced by the caller.
if ! declare -f log_info >/dev/null 2>&1; then
    log_debug()   { :; }
    log_info()    { echo "[INFO]    $*"; }
    log_warn()    { echo "[WARN]    $*" >&2; }
    log_error()   { echo "[ERROR]   $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

#===============================================================================
# Security validation
#===============================================================================

# Confirm that a stage flagged no_credentials=true meets its security contract:
#   - network must be "filtered" or "none" (never "open")
#   - the generated per-stage config must have no keychain entries
#
# Args: stage_name no_credentials network config_file
validate_stage_security() {
    local stage_name="$1"
    local no_credentials="$2"
    local network="$3"
    local config_file="$4"

    [[ "$no_credentials" != "true" ]] && return 0

    if [[ "$network" == "open" ]]; then
        log_error "Stage '$stage_name': no_credentials: true prohibits network: open" \
                  "(would allow exfiltration via open network + credential leak)"
        return 1
    fi

    if command -v yq &>/dev/null; then
        local keychain_count
        keychain_count=$(yq '.environment.keychain // {} | keys | length' "$config_file" 2>/dev/null || echo "0")
        if [[ "$keychain_count" -gt 0 ]]; then
            log_error "Stage '$stage_name': no_credentials: true but generated config" \
                      "has $keychain_count keychain entry/entries — aborting"
            return 1
        fi
    fi

    return 0
}

#===============================================================================
# Handoff file allowlist
#===============================================================================

# Returns 0 when the file's extension is on the handoff allowlist.
# Extension lookup is case-insensitive; leading dot is stripped.
is_allowed_handoff_extension() {
    local filename="$1"
    local ext="${filename##*.}"
    ext="${ext,,}"  # lowercase

    local allowed="${KAPSIS_STAGE_HANDOFF_ALLOWED_EXTS:-md:txt:json:yaml:yml:xml:csv:toml:rst:log:diff:patch}"
    local IFS=:
    local e
    for e in $allowed; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

# Remove files that fail the extension allowlist and apply byte-level sanitization
# to the remainder.  Logs every removal.
#
# Args: handoff_dir
sanitize_handoff_dir() {
    local handoff_dir="$1"
    [[ -d "$handoff_dir" ]] || return 0

    local removed=0 kept=0

    while IFS= read -r -d '' file; do
        if ! is_allowed_handoff_extension "$file"; then
            log_warn "Handoff: removing disallowed file type: ${file##"$handoff_dir/"}"
            rm -f "$file"
            ((removed++)) || true
        else
            ((kept++)) || true
        fi
    done < <(find "$handoff_dir" -type f -print0 2>/dev/null)

    log_info "Handoff sanitization: kept=$kept removed=$removed"

    # Byte-level sanitization for remaining files (homoglyph / invisible chars)
    local sanitize_script="$_STAGE_HANDOFF_DIR/sanitize-files.sh"
    if [[ -x "$sanitize_script" ]]; then
        local f
        while IFS= read -r -d '' f; do
            # sanitize-files.sh operates on staged files; call its inner helper
            # directly so it processes arbitrary paths without a git context.
            bash "$sanitize_script" --file "$f" 2>/dev/null || \
                log_warn "Sanitization warning for: ${f##"$handoff_dir/"}"
        done < <(find "$handoff_dir" -type f -print0 2>/dev/null)
    fi
}

#===============================================================================
# Handoff file extraction
#===============================================================================

# Copy files matching include_patterns from a committed git branch to dest_dir.
# Uses 'git ls-tree' + 'git show' so no checkout of the branch is needed.
#
# Args: project_path branch include_patterns dest_dir
#   include_patterns: newline-separated list of glob-like path fragments
extract_handoff_files() {
    local project_path="$1"
    local branch="$2"
    local include_patterns="$3"
    local dest_dir="$4"

    mkdir -p "$dest_dir"

    if [[ -z "$branch" ]] || ! (cd "$project_path" && git rev-parse --verify "$branch" &>/dev/null); then
        log_warn "Handoff: branch '$branch' not found — skipping extraction"
        return 0
    fi

    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        local escaped_pattern
        escaped_pattern=$(printf '%s' "$pattern" | sed 's/\./\\./g; s/\*/.*/g; s/?/./g')

        while IFS= read -r filepath; do
            [[ -z "$filepath" ]] && continue
            if ! echo "$filepath" | grep -qE "$escaped_pattern"; then
                continue
            fi
            local dest_file="$dest_dir/$filepath"
            mkdir -p "$(dirname "$dest_file")"
            if ! (cd "$project_path" && git show "${branch}:${filepath}") > "$dest_file" 2>/dev/null; then
                log_warn "Handoff: could not extract '$filepath' from branch '$branch'"
                rm -f "$dest_file"
            fi
        done < <(cd "$project_path" && git ls-tree -r --name-only "$branch" 2>/dev/null)
    done <<< "$include_patterns"
}

#===============================================================================
# Approval gate
#===============================================================================

# Block until an operator deletes the sentinel file, or until the timeout.
#
# Creates: <handoff_base>/<workflow_id>/<stage_name>.approval-pending
# Operator deletes the sentinel to approve; creates <stage_name>.rejected to deny.
#
# Args: handoff_base workflow_id stage_name timeout_secs
#   timeout_secs: 0 = no timeout (wait forever)
# Returns:
#   0 = approved
#   1 = rejected
#   7 = timed out (KAPSIS_EXIT_APPROVAL_TIMEOUT)
wait_for_stage_approval() {
    local handoff_base="$1"
    local workflow_id="$2"
    local stage_name="$3"
    local timeout_secs="${4:-${KAPSIS_DEFAULT_STAGE_APPROVAL_TIMEOUT}}"

    local sentinel="${handoff_base}/${workflow_id}/${stage_name}${KAPSIS_STAGE_APPROVAL_SENTINEL_EXT}"
    local reject_marker="${handoff_base}/${workflow_id}/${stage_name}${KAPSIS_STAGE_REJECTION_MARKER_EXT}"

    mkdir -p "$(dirname "$sentinel")"
    touch "$sentinel"

    log_info "Stage '$stage_name' is awaiting operator approval."
    log_info "  Approve: rm '${sentinel}'"
    log_info "  Reject:  rm '${sentinel}' && touch '${reject_marker}'"
    if [[ "$timeout_secs" -gt 0 ]]; then
        log_info "  Timeout: ${timeout_secs}s"
    fi

    local elapsed=0
    while [[ -f "$sentinel" ]]; do
        sleep 5
        ((elapsed += 5)) || true
        if [[ "$timeout_secs" -gt 0 && "$elapsed" -ge "$timeout_secs" ]]; then
            log_error "Approval timeout (${timeout_secs}s) for stage '$stage_name'"
            rm -f "$sentinel"
            return "${KAPSIS_EXIT_APPROVAL_TIMEOUT}"
        fi
    done

    if [[ -f "$reject_marker" ]]; then
        rm -f "$reject_marker"
        log_error "Stage '$stage_name' rejected by operator"
        return 1
    fi

    log_success "Stage '$stage_name' approved"
    return 0
}

#===============================================================================
# Stage manifest
#===============================================================================

# Write a JSON manifest for a completed stage so operators can audit progress.
#
# Args: handoff_base workflow_id stage_name branch exit_code handoff_dir
write_stage_manifest() {
    local handoff_base="$1"
    local workflow_id="$2"
    local stage_name="$3"
    local branch="$4"
    local exit_code="$5"
    local handoff_dir="$6"

    local manifest_file="${handoff_base}/${workflow_id}/${stage_name}.manifest.json"
    mkdir -p "$(dirname "$manifest_file")"

    local completed_at
    completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)

    printf '{
  "workflow_id": "%s",
  "stage_name": "%s",
  "branch": "%s",
  "exit_code": %d,
  "handoff_dir": "%s",
  "completed_at": "%s"
}\n' "$workflow_id" "$stage_name" "$branch" "$exit_code" "$handoff_dir" "$completed_at" \
        > "$manifest_file"
}
