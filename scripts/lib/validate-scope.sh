#!/usr/bin/env bash
#===============================================================================
# Kapsis - Filesystem Scope Validation
#
# Validates that container only modified files within allowed paths.
# This is a critical security control to prevent prompt injection attacks
# from modifying host configuration files.
#
# Usage:
#   source validate-scope.sh
#   validate_scope "$worktree_path" "$upper_dir"
#
# Returns:
#   0 - All modifications within allowed scope
#   1 - Scope violations detected (abort)
#   2 - Warning-level violations (git hooks)
#===============================================================================

set -euo pipefail

# Source logging if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_info &>/dev/null; then
    source "$SCRIPT_DIR/logging.sh"
fi

#===============================================================================
# SCOPE CONFIGURATION
#===============================================================================

# Allowed paths (modifications permitted)
# These are container paths, not host paths
ALLOWED_PATHS=(
    "^workspace/"
    "^tmp/"
    "^home/developer/.m2/"
    "^home/developer/.gradle/"
    "^home/developer/.npm/"
    "^home/developer/.cache/"
    "^kapsis-status/"
    "^var/tmp/"
)

# Blocked paths (ABORT on modification)
BLOCKED_PATHS=(
    "\.ssh/"
    "\.claude/"
    "\.bashrc$"
    "\.zshrc$"
    "\.profile$"
    "\.bash_profile$"
    "\.gitconfig$"
    "^etc/"
    "\.aws/"
    "\.kube/"
    "\.gnupg/"
    "\.config/git/"
)

# Warning-only paths (log warning but allow)
WARNING_PATHS=(
    "\.git/hooks/"
)

#===============================================================================
# VALIDATION FUNCTIONS
#===============================================================================

# Check if a path is in the allowed list
# Usage: is_path_allowed "relative/path"
is_path_allowed() {
    local path="$1"

    for pattern in "${ALLOWED_PATHS[@]}"; do
        if [[ "$path" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Check if a path is in the blocked list
# Usage: is_path_blocked "relative/path"
is_path_blocked() {
    local path="$1"

    for pattern in "${BLOCKED_PATHS[@]}"; do
        if [[ "$path" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Check if a path is in the warning list
# Usage: is_path_warning "relative/path"
is_path_warning() {
    local path="$1"

    for pattern in "${WARNING_PATHS[@]}"; do
        if [[ "$path" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Validate filesystem scope for worktree mode
# Usage: validate_scope_worktree "$worktree_path"
validate_scope_worktree() {
    local worktree_path="$1"
    local violations=()
    local warnings=()

    log_info "Validating filesystem scope (worktree mode)..."

    # Get list of modified files from git
    local modified_files
    if ! modified_files=$(cd "$worktree_path" && git status --porcelain 2>/dev/null); then
        log_warn "Could not get git status - skipping scope validation"
        return 0
    fi

    if [[ -z "$modified_files" ]]; then
        log_debug "No modified files to validate"
        return 0
    fi

    # Check each modified file
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Extract file path (format: XY path or XY old -> new for renames)
        local file_path
        file_path=$(echo "$line" | awk '{print $2}')

        # Check for blocked paths first
        if is_path_blocked "$file_path"; then
            violations+=("$file_path")
            continue
        fi

        # Check for warning paths
        if is_path_warning "$file_path"; then
            warnings+=("$file_path")
            continue
        fi

        # For worktree mode, all files should be in workspace
        # This is mostly a sanity check since git won't track files outside the repo
        log_debug "Validated: $file_path"
    done <<< "$modified_files"

    # Report warnings (non-fatal)
    if [[ ${#warnings[@]} -gt 0 ]]; then
        log_warn "Git hooks modified (review carefully):"
        for w in "${warnings[@]}"; do
            log_warn "  ⚠️  $w"
        done
    fi

    # Report violations (fatal)
    if [[ ${#violations[@]} -gt 0 ]]; then
        log_error "⛔ SCOPE VIOLATION DETECTED"
        log_error "The following files were modified in blocked paths:"
        log_error ""
        for v in "${violations[@]}"; do
            log_error "  ❌ $v"
        done
        log_error ""
        log_error "ACTION TAKEN:"
        log_error "  - Container output will NOT be committed"
        log_error "  - Worktree preserved for forensic analysis"
        log_error ""
        log_error "Worktree location: $worktree_path"

        # Log to audit file
        log_scope_violation "$worktree_path" "${violations[@]}"

        return 1
    fi

    log_success "✓ Filesystem scope validation passed"
    return 0
}

# Validate filesystem scope for overlay mode
# Usage: validate_scope_overlay "$upper_dir"
validate_scope_overlay() {
    local upper_dir="$1"
    local violations=()
    local warnings=()

    log_info "Validating filesystem scope (overlay mode)..."

    if [[ ! -d "$upper_dir" ]]; then
        log_debug "Upper directory does not exist - no modifications"
        return 0
    fi

    # Find all modified files in upper directory
    local modified_files
    modified_files=$(find "$upper_dir" -type f 2>/dev/null || echo "")

    if [[ -z "$modified_files" ]]; then
        log_debug "No modified files to validate"
        return 0
    fi

    # Check each modified file
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Get path relative to upper directory
        local relative_path="${file#"${upper_dir}/"}"

        # Check for blocked paths first
        if is_path_blocked "$relative_path"; then
            violations+=("$relative_path")
            continue
        fi

        # Check for warning paths
        if is_path_warning "$relative_path"; then
            warnings+=("$relative_path")
            continue
        fi

        # Check if path is allowed
        if ! is_path_allowed "$relative_path"; then
            violations+=("$relative_path (outside allowed paths)")
            continue
        fi

        log_debug "Validated: $relative_path"
    done <<< "$modified_files"

    # Report warnings (non-fatal)
    if [[ ${#warnings[@]} -gt 0 ]]; then
        log_warn "Git hooks modified (review carefully):"
        for w in "${warnings[@]}"; do
            log_warn "  ⚠️  $w"
        done
    fi

    # Report violations (fatal)
    if [[ ${#violations[@]} -gt 0 ]]; then
        log_error "⛔ SCOPE VIOLATION DETECTED"
        log_error "The following files were modified outside allowed paths:"
        log_error ""
        for v in "${violations[@]}"; do
            log_error "  ❌ $v"
        done
        log_error ""
        log_error "ACTION TAKEN:"
        log_error "  - Container output will NOT be merged"
        log_error "  - Sandbox preserved for forensic analysis"
        log_error ""
        log_error "Upper directory: $upper_dir"

        # Log to audit file
        log_scope_violation "$upper_dir" "${violations[@]}"

        return 1
    fi

    log_success "✓ Filesystem scope validation passed"
    return 0
}

# Main validation entry point
# Usage: validate_scope "$worktree_path" "$upper_dir"
# Pass empty string for unused mode
validate_scope() {
    local worktree_path="${1:-}"
    local upper_dir="${2:-}"

    if [[ -n "$worktree_path" ]] && [[ -d "$worktree_path" ]]; then
        validate_scope_worktree "$worktree_path"
    elif [[ -n "$upper_dir" ]] && [[ -d "$upper_dir" ]]; then
        validate_scope_overlay "$upper_dir"
    else
        log_debug "No scope validation needed (no worktree or upper_dir)"
        return 0
    fi
}

#===============================================================================
# AUDIT LOGGING
#===============================================================================

# Log scope violations to audit file
# Usage: log_scope_violation "$path" "${violations[@]}"
log_scope_violation() {
    local path="$1"
    shift
    local violations=("$@")

    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
    local audit_file="$audit_dir/scope-violations.jsonl"

    # Ensure audit directory exists
    mkdir -p "$audit_dir"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build violations JSON array
    local violations_json="["
    local first=true
    for v in "${violations[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            violations_json+=","
        fi
        violations_json+="\"$v\""
    done
    violations_json+="]"

    # Write audit entry
    cat >> "$audit_file" <<EOF
{"timestamp":"$timestamp","path":"$path","violations":$violations_json,"action":"aborted"}
EOF

    log_debug "Scope violation logged to: $audit_file"
}
