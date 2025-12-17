#!/usr/bin/env bash
#===============================================================================
# Kapsis - Pre-Flight Validation Script
#
# Validates all prerequisites before launching a Kapsis agent.
# Called automatically by launch-agent.sh when using --branch flag.
#
# Exit codes:
#   0 - All checks pass
#   1 - Critical failure (blocks launch)
#   2 - Warnings only (can proceed)
#
# Usage:
#   source preflight-check.sh
#   preflight_check <project_path> <target_branch> [spec_file]
#===============================================================================

set -euo pipefail

# Script directory
PREFLIGHT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging library (only if not already loaded)
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$PREFLIGHT_SCRIPT_DIR/lib/logging.sh"
    log_init "preflight-check"
fi

#===============================================================================
# PREFLIGHT CHECK RESULTS
#===============================================================================
_PREFLIGHT_ERRORS=0
_PREFLIGHT_WARNINGS=0

preflight_error() {
    log_error "$1"
    ((_PREFLIGHT_ERRORS++)) || true
}

preflight_warn() {
    log_warn "$1"
    ((_PREFLIGHT_WARNINGS++)) || true
}

preflight_ok() {
    log_success "$1"
}

#===============================================================================
# INDIVIDUAL CHECKS
#===============================================================================

# Check if Podman is available and machine is running
check_podman() {
    log_info "Checking Podman..."

    if ! command -v podman &>/dev/null; then
        preflight_error "Podman is not installed or not in PATH"
        return 1
    fi

    if ! podman machine inspect podman-machine-default &>/dev/null; then
        preflight_error "Podman machine 'podman-machine-default' not found"
        preflight_error "  Run: podman machine init"
        return 1
    fi

    local machine_state
    machine_state=$(podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null || echo "unknown")

    if [[ "$machine_state" != "running" ]]; then
        preflight_error "Podman machine is not running (state: $machine_state)"
        preflight_error "  Run: podman machine start"
        return 1
    fi

    preflight_ok "Podman machine is running"
    return 0
}

# Check if Kapsis images are available
check_images() {
    local image_name="${1:-kapsis-sandbox:latest}"

    log_info "Checking Kapsis image: $image_name"

    if ! podman image exists "$image_name" 2>/dev/null; then
        preflight_error "Kapsis image not found: $image_name"
        preflight_error "  Run: ~/git/kapsis/scripts/build-image.sh"
        if [[ "$image_name" == *"claude"* ]]; then
            preflight_error "  Then: ~/git/kapsis/scripts/build-agent-image.sh claude-cli"
        fi
        return 1
    fi

    preflight_ok "Image available: $image_name"
    return 0
}

# Check git status (clean working tree)
check_git_status() {
    local project_path="$1"

    log_info "Checking git status..."

    if [[ ! -d "$project_path/.git" ]]; then
        preflight_error "Not a git repository: $project_path"
        return 1
    fi

    cd "$project_path"

    local status
    status=$(git status --porcelain 2>/dev/null || echo "ERROR")

    if [[ "$status" == "ERROR" ]]; then
        preflight_error "Failed to check git status in $project_path"
        return 1
    fi

    if [[ -n "$status" ]]; then
        local change_count
        change_count=$(echo "$status" | wc -l | tr -d ' ')
        preflight_warn "Git working tree has $change_count uncommitted change(s)"
        preflight_warn "  Consider: git stash or git commit"
        # This is a warning, not an error - worktree still works
        return 0
    fi

    preflight_ok "Git working tree is clean"
    return 0
}

# CRITICAL: Check if main repo is on the target branch
check_branch_conflict() {
    local project_path="$1"
    local target_branch="$2"

    log_info "Checking for branch conflict..."

    cd "$project_path"

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -z "$current_branch" ]]; then
        preflight_error "Could not determine current branch in $project_path"
        return 1
    fi

    # Normalize branch names (remove feature/ prefix for comparison if needed)
    local target_normalized="${target_branch#feature/}"
    local current_normalized="${current_branch#feature/}"

    if [[ "$current_branch" == "$target_branch" ]] || \
       [[ "$current_normalized" == "$target_normalized" && "$current_branch" == "feature/$target_normalized" ]]; then
        preflight_error "BRANCH CONFLICT: Main repo is on '$current_branch'"
        preflight_error ""
        preflight_error "Git worktrees cannot use a branch already checked out elsewhere."
        preflight_error ""
        preflight_error "To fix this, switch the main repo to a different branch:"
        preflight_error "  cd $project_path"
        preflight_error "  git checkout main  # or: git checkout stable/trunk"
        preflight_error "  git stash          # if you have uncommitted changes"
        preflight_error ""
        preflight_error "Then retry the Kapsis launch."
        return 1
    fi

    preflight_ok "No branch conflict (main repo on: $current_branch)"
    return 0
}

# Check if spec file exists (if provided)
check_spec_file() {
    local spec_file="$1"

    if [[ -z "$spec_file" ]]; then
        return 0
    fi

    log_info "Checking spec file..."

    if [[ ! -f "$spec_file" ]]; then
        preflight_error "Spec file not found: $spec_file"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$spec_file" | tr -d ' ')

    if [[ "$line_count" -lt 5 ]]; then
        preflight_warn "Spec file is very short ($line_count lines) - may need more detail"
    else
        preflight_ok "Spec file exists: $spec_file ($line_count lines)"
    fi

    return 0
}

# Check for existing worktree that might conflict
check_existing_worktree() {
    local project_path="$1"
    local agent_id="$2"

    log_info "Checking for existing worktree..."

    local project_name
    project_name=$(basename "$project_path")
    local worktree_path="${KAPSIS_WORKTREE_BASE:-$HOME/.kapsis/worktrees}/${project_name}-${agent_id}"

    if [[ -d "$worktree_path" ]]; then
        preflight_warn "Existing worktree found: $worktree_path"
        preflight_warn "  Will be reused if on compatible branch"
    else
        preflight_ok "No conflicting worktree"
    fi

    return 0
}

#===============================================================================
# MAIN PREFLIGHT CHECK
#===============================================================================
preflight_check() {
    local project_path="${1:-.}"
    local target_branch="${2:-}"
    local spec_file="${3:-}"
    local image_name="${4:-kapsis-sandbox:latest}"
    local agent_id="${5:-1}"

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    log_section "Kapsis Pre-Flight Check"
    echo ""

    # Run all checks
    check_podman || true
    check_images "$image_name" || true

    if [[ -n "$target_branch" ]]; then
        check_git_status "$project_path" || true
        check_branch_conflict "$project_path" "$target_branch" || true
        check_existing_worktree "$project_path" "$agent_id" || true
    fi

    if [[ -n "$spec_file" ]]; then
        check_spec_file "$spec_file" || true
    fi

    echo ""

    # Summary
    if [[ $_PREFLIGHT_ERRORS -gt 0 ]]; then
        log_error "Pre-flight check FAILED: $_PREFLIGHT_ERRORS error(s), $_PREFLIGHT_WARNINGS warning(s)"
        echo ""
        return 1
    elif [[ $_PREFLIGHT_WARNINGS -gt 0 ]]; then
        log_warn "Pre-flight check PASSED with $_PREFLIGHT_WARNINGS warning(s)"
        echo ""
        return 0  # Warnings don't block launch
    else
        log_success "Pre-flight check PASSED: All checks OK"
        echo ""
        return 0
    fi
}

#===============================================================================
# STANDALONE EXECUTION
#===============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Called directly - run checks with provided args
    PROJECT_PATH="${1:-.}"
    TARGET_BRANCH="${2:-}"
    SPEC_FILE="${3:-}"
    IMAGE_NAME="${4:-kapsis-sandbox:latest}"
    AGENT_ID="${5:-1}"

    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        echo "Usage: $0 <project_path> [target_branch] [spec_file] [image_name] [agent_id]"
        echo ""
        echo "Validates prerequisites before launching a Kapsis agent."
        echo ""
        echo "Arguments:"
        echo "  project_path   Path to the project directory (default: .)"
        echo "  target_branch  Git branch for worktree (optional)"
        echo "  spec_file      Task specification file (optional)"
        echo "  image_name     Container image (default: kapsis-sandbox:latest)"
        echo "  agent_id       Agent identifier (default: 1)"
        echo ""
        echo "Exit codes:"
        echo "  0 - All checks pass"
        echo "  1 - Critical failure"
        exit 0
    fi

    preflight_check "$PROJECT_PATH" "$TARGET_BRANCH" "$SPEC_FILE" "$IMAGE_NAME" "$AGENT_ID"
    exit $?
fi
