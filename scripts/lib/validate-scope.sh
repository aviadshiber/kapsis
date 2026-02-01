#!/usr/bin/env bash
#===============================================================================
# Kapsis - Filesystem Scope Validation
#
# Validates that container only modified files within allowed paths.
# This is a critical security control to prevent prompt injection attacks
# from modifying host configuration files.
#
# SECURITY MODEL:
#
# Worktree Mode:
#   - Container can ONLY write to the mounted worktree (/workspace)
#   - Host paths (like ~/.claude/, ~/.ssh/) are not accessible
#   - Security is enforced by mount isolation, not path validation
#   - git status only shows workspace-relative paths (e.g., .claude/CLAUDE.md)
#   - These are PROJECT config files, not host config - safe to commit
#   - Only .git/hooks/ gets a warning (could affect host on checkout)
#
# Overlay Mode:
#   - Container changes captured in upper_dir with full paths
#   - Paths like home/developer/.claude/ indicate host config modification attempts
#   - Must distinguish workspace/ paths (allowed) from home/ paths (blocked)
#   - Agent-agnostic: blocks ALL home directory agent configs, not just specific ones
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
_VALIDATE_SCOPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_info &>/dev/null; then
    source "$_VALIDATE_SCOPE_DIR/logging.sh"
fi

#===============================================================================
# SCOPE CONFIGURATION
#===============================================================================

# Allowed paths for OVERLAY mode (modifications permitted)
# These are container paths relative to upper_dir
# Workspace paths are allowed - this includes project-level agent configs
ALLOWED_PATHS_OVERLAY=(
    "^workspace/"                    # All workspace files including project agent configs
    "^tmp/"
    "^home/developer/\.m2/"          # Maven cache
    "^home/developer/\.gradle/"      # Gradle cache
    "^home/developer/\.npm/"         # NPM cache
    "^home/developer/\.cache/"       # Generic cache
    "^kapsis-status/"
    "^var/tmp/"
)

# Blocked paths for OVERLAY mode (ABORT on modification)
# These are HOME DIRECTORY paths - agent tried to modify host-level config
# Agent-agnostic: covers all known and future AI coding agent config directories
BLOCKED_PATHS_OVERLAY=(
    # SSH and security
    "^home/developer/\.ssh/"
    "^home/developer/\.gnupg/"
    "^home/developer/\.aws/"
    "^home/developer/\.kube/"

    # Shell configuration (could inject malicious commands)
    "^home/developer/\.bashrc$"
    "^home/developer/\.zshrc$"
    "^home/developer/\.profile$"
    "^home/developer/\.bash_profile$"
    "^home/developer/\.zprofile$"

    # Git configuration
    "^home/developer/\.gitconfig$"
    "^home/developer/\.config/git/"

    # AI Agent home configs (agent-agnostic - covers all agents)
    # These are HOST-LEVEL configs, not project configs
    "^home/developer/\.claude/"      # Claude Code
    "^home/developer/\.aider"        # Aider (files and dirs)
    "^home/developer/\.cursor/"      # Cursor
    "^home/developer/\.continue/"    # Continue.dev
    "^home/developer/\.codex/"       # Codex CLI
    "^home/developer/\.gemini/"      # Gemini CLI
    "^home/developer/\.codeium/"     # Codeium/Windsurf
    "^home/developer/\.copilot/"     # GitHub Copilot
    "^home/developer/\.config/github-copilot/"

    # System paths
    "^etc/"
)

# For WORKTREE mode, no paths are blocked
# Security rationale: Mount isolation prevents access to host paths.
# All paths in git status are workspace-relative (project files).
# Project-level agent configs (.claude/, .aider*, etc.) are legitimate.
# shellcheck disable=SC2034  # Intentionally empty - documents security model
BLOCKED_PATHS_WORKTREE=()

# Warning-only paths (log warning but allow) - applies to both modes
# .git/hooks/ could inject malicious hooks that run on host
WARNING_PATHS=(
    "\.git/hooks/"
)

# Legacy compatibility - used by is_path_blocked() for overlay mode
BLOCKED_PATHS=("${BLOCKED_PATHS_OVERLAY[@]}")
ALLOWED_PATHS=("${ALLOWED_PATHS_OVERLAY[@]}")

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
#
# SECURITY MODEL FOR WORKTREE MODE:
# In worktree mode, security is enforced by MOUNT ISOLATION, not path validation.
# The container can only write to /workspace (the mounted worktree).
# Host paths like ~/.claude/, ~/.ssh/ are not mounted or mounted read-only.
#
# git status only shows workspace-relative paths like:
#   .claude/CLAUDE.md     <- Project config (SAFE - not host ~/.claude/)
#   .aiderignore          <- Project config (SAFE)
#   src/main.java         <- Code (SAFE)
#
# These are all PROJECT files, not host configuration.
# Blocking them based on patterns designed for host paths is incorrect.
#
# We only WARN on .git/hooks/ because hooks could execute on the host
# when the user interacts with the repo after Kapsis completes.
validate_scope_worktree() {
    local worktree_path="$1"
    local warnings=()

    log_info "Validating filesystem scope (worktree mode)..."
    log_debug "Security: Mount isolation prevents host path access"
    log_debug "Security: All git status paths are workspace-relative (project files)"

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

    # Check each modified file - only for warnings (no blocking in worktree mode)
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Extract file path (format: XY path or XY old -> new for renames)
        local file_path
        file_path=$(echo "$line" | awk '{print $2}')

        # Check for warning paths (.git/hooks/ could affect host)
        if is_path_warning "$file_path"; then
            warnings+=("$file_path")
            continue
        fi

        # All other workspace paths are allowed
        # Project-level agent configs (.claude/, .aider*, .cursor/, etc.) are legitimate
        log_debug "Validated: $file_path"
    done <<< "$modified_files"

    # Report warnings (non-fatal) - .git/hooks/ modifications
    if [[ ${#warnings[@]} -gt 0 ]]; then
        log_warn "⚠️  Git hooks modified (review carefully before using this repo):"
        for w in "${warnings[@]}"; do
            log_warn "    $w"
        done
        log_warn "These hooks will execute on your host when you interact with this repo."
    fi

    # No blocking in worktree mode - mount isolation is the security boundary
    log_success "✓ Filesystem scope validation passed (worktree mode)"
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

    # Source json-utils for proper escaping
    source "$_VALIDATE_SCOPE_DIR/json-utils.sh"

    local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
    local audit_file="$audit_dir/scope-violations.jsonl"

    # Ensure audit directory exists
    mkdir -p "$audit_dir"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Escape the path for JSON
    local escaped_path
    escaped_path=$(json_escape_string "$path")

    # Build violations JSON array with proper escaping
    local violations_json="["
    local first=true
    for v in "${violations[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            violations_json+=","
        fi
        local escaped_v
        escaped_v=$(json_escape_string "$v")
        violations_json+="\"$escaped_v\""
    done
    violations_json+="]"

    # Write audit entry
    cat >> "$audit_file" <<EOF
{"timestamp":"$timestamp","path":"$escaped_path","violations":$violations_json,"action":"aborted"}
EOF

    log_debug "Scope violation logged to: $audit_file"
}
