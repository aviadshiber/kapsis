#!/usr/bin/env bash
#===============================================================================
# Kapsis - Shared Git Operations
#
# Provides reusable git primitives used by multiple scripts:
#   - entrypoint.sh (post_exit_git)
#   - post-container-git.sh (verify_push, push_changes)
#   - post-exit-git.sh (push)
#
# Eliminates 3-way duplication of push verification and change detection.
#
# Dependencies (must be sourced before this file):
#   - log_info, log_debug, log_success, log_warn, log_error (from logging.sh)
#   - status_set_push_info (from status.sh, optional — guarded with 'type')
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_GIT_OPERATIONS_LOADED:-}" ]] && return 0
readonly _KAPSIS_GIT_OPERATIONS_LOADED=1

#===============================================================================
# CHANGE DETECTION
#===============================================================================

# Check if the working directory has uncommitted changes
# (staged, unstaged, or untracked files)
# Returns: 0 if changes exist, 1 if clean
has_git_changes() {
    if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]; then
        return 0
    fi
    return 1
}

# Check if the current branch has unpushed commits relative to remote
# Arguments:
#   $1 - remote name (default: origin)
#   $2 - remote branch name (default: current branch)
# Returns: 0 if unpushed commits exist, 1 if none
has_unpushed_commits() {
    local remote="${1:-origin}"
    local remote_branch="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

    if git rev-parse --verify "${remote}/${remote_branch}" >/dev/null 2>&1; then
        local ahead
        ahead=$(git rev-list --count "${remote}/${remote_branch}..HEAD" 2>/dev/null || echo "0")
        [[ "$ahead" -gt 0 ]] && return 0
    else
        # Remote branch doesn't exist — any local commits are unpushed
        local commits
        commits=$(git rev-list --count HEAD 2>/dev/null || echo "0")
        [[ "$commits" -gt 0 ]] && return 0
    fi
    return 1
}

#===============================================================================
# PUSH WITH REFSPEC
#
# Pushes using refspec syntax (local_branch:remote_branch).
# Arguments:
#   $1 - remote name
#   $2 - local branch name
#   $3 - remote branch name (defaults to $2)
# Returns: 0 on success, 1 on failure
#===============================================================================
git_push_refspec() {
    local remote="$1"
    local local_branch="$2"
    local remote_branch="${3:-$local_branch}"

    git push --set-upstream "$remote" "${local_branch}:${remote_branch}"
}

#===============================================================================
# PUSH VERIFICATION
#
# Verifies that a push succeeded by comparing local and remote HEAD.
# Arguments:
#   $1 - remote name
#   $2 - branch name (remote tracking branch)
# Returns: 0 if verified, 1 if failed, 2 if unverifiable
#===============================================================================
verify_git_push() {
    local remote="$1"
    local branch="$2"

    log_info "Verifying push to ${remote}/${branch}..."

    # Get local HEAD commit
    local local_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -z "$local_commit" ]]; then
        log_error "Could not determine local HEAD commit"
        _git_ops_set_push_info "failed" "" ""
        return 1
    fi
    log_debug "Local commit: $local_commit"

    # Fetch latest from remote to ensure we have current state
    if ! git fetch "$remote" "$branch" --quiet 2>/dev/null; then
        log_warn "Could not fetch from remote for verification"
        _git_ops_set_push_info "unverified" "$local_commit" ""
        return 2
    fi

    # Get remote HEAD commit after fetch
    local remote_commit
    remote_commit=$(git rev-parse "${remote}/${branch}" 2>/dev/null || echo "")
    log_debug "Remote commit: ${remote_commit:-unknown}"

    # Compare commits
    if [[ "$local_commit" == "$remote_commit" ]]; then
        log_success "Push verified: local and remote HEAD match"
        log_info "  Commit: ${local_commit:0:12}"
        _git_ops_set_push_info "success" "$local_commit" "$remote_commit"
        return 0
    elif [[ -z "$remote_commit" ]]; then
        log_warn "Could not verify push - fetch may have failed"
        log_info "  Local commit: ${local_commit:0:12}"
        _git_ops_set_push_info "unverified" "$local_commit" ""
        return 2
    else
        log_error "Push verification FAILED: commits do not match!"
        log_error "  Local:  $local_commit"
        log_error "  Remote: ${remote_commit:-not found}"
        _git_ops_set_push_info "failed" "$local_commit" "${remote_commit:-unknown}"
        return 1
    fi
}

# Internal helper: safely call status_set_push_info if available
_git_ops_set_push_info() {
    if type status_set_push_info &>/dev/null; then
        status_set_push_info "$@"
    fi
}
