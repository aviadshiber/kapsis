#!/usr/bin/env bash
#===============================================================================
# Kapsis - Post-Container Git Operations
#
# Runs on HOST after container exits to handle git commit and push.
# This runs in a trusted environment with full git access, after the
# agent has made its changes in the sandboxed worktree.
#
# Security Model:
# - Executes on HOST (not in container)
# - Full git access for commit/push operations
# - Validates changes before committing
# - Generates PR-ready commit messages
#===============================================================================

set -euo pipefail

# Script directory
POST_GIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging library (only if not already loaded)
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$POST_GIT_SCRIPT_DIR/lib/logging.sh"
    log_init "post-container-git"
fi

# Source status reporting library (only if not already loaded)
if [[ -z "${_KAPSIS_STATUS_LOADED:-}" ]]; then
    source "$POST_GIT_SCRIPT_DIR/lib/status.sh"
fi

# Note: logging functions are provided by lib/logging.sh
# Note: status functions are provided by lib/status.sh

#===============================================================================
# VALIDATE AND CLEAN STAGED FILES
#
# Checks for suspicious files that should never be committed and removes them
# from staging. This is a safety net to prevent accidental commits of:
# - Literal ~ paths (tilde not expanded, creates directory named "~")
# - .kapsis/ internal files
# - Submodule references (mode 160000) that weren't intentional
#
# Returns: 0 if validation passed (or issues were auto-fixed), 1 if blocking issues
#===============================================================================
validate_staged_files() {
    local worktree_path="$1"

    cd "$worktree_path"

    local has_issues=0
    local suspicious_files=()

    # Check for literal ~ paths in staged files
    # These occur when tilde expansion fails inside container
    local tilde_files
    tilde_files=$(git diff --cached --name-only 2>/dev/null | grep "^~" || true)
    if [[ -n "$tilde_files" ]]; then
        log_warn "Found staged files with literal ~ path (should be ignored):"
        # Use process substitution to avoid subshell (array would be lost in pipe)
        while IFS= read -r f; do
            log_warn "  - $f"
            suspicious_files+=("$f")
        done <<< "$tilde_files"
        has_issues=1
    fi

    # Check for .kapsis/ internal files
    local kapsis_files
    kapsis_files=$(git diff --cached --name-only 2>/dev/null | grep "^\.kapsis/" || true)
    if [[ -n "$kapsis_files" ]]; then
        log_warn "Found staged .kapsis/ internal files (should be ignored):"
        while IFS= read -r f; do
            log_warn "  - $f"
            suspicious_files+=("$f")
        done <<< "$kapsis_files"
        has_issues=1
    fi

    # Check for submodule references (mode 160000)
    # These can happen when a directory with .git is accidentally staged
    # Pattern :000000 160000 catches NEW submodules being added
    local submodule_refs
    submodule_refs=$(git diff --cached --raw 2>/dev/null | grep "160000" || true)
    if [[ -n "$submodule_refs" ]]; then
        log_warn "Found new submodule references being added (potential accident):"
        while IFS= read -r line; do
            local path
            path=$(echo "$line" | awk '{print $NF}')
            log_warn "  - $path (submodule)"
            suspicious_files+=("$path")
        done <<< "$submodule_refs"
        has_issues=1
    fi

    # If issues found, unstage the suspicious files
    if [[ $has_issues -eq 1 ]]; then
        log_warn "Removing suspicious files from staging..."
        for file in "${suspicious_files[@]}"; do
            if [[ -n "$file" ]]; then
                git reset HEAD -- "$file" 2>/dev/null || true
                log_info "  Unstaged: $file"
            fi
        done

        # Also try to remove literal ~ directory if it exists
        if [[ -d "~" ]]; then
            log_warn "Removing literal ~ directory from worktree..."
            rm -rf "~" 2>/dev/null || true
        fi

        log_info "Suspicious files removed from staging. Continuing with clean files."
    fi

    return 0
}

#===============================================================================
# CHECK FOR CHANGES
#
# Returns 0 if there are uncommitted changes, 1 otherwise.
#===============================================================================
has_changes() {
    local worktree_path="$1"

    cd "$worktree_path"

    # Check for any changes (staged, unstaged, or untracked)
    if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
        return 1
    fi
    return 0
}

#===============================================================================
# GET KAPSIS VERSION
#
# Returns the Kapsis version from the version library or package.json
#===============================================================================
get_kapsis_version() {
    local version=""
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Try to get version from package.json
    if [[ -f "$script_dir/../package.json" ]]; then
        version=$(grep -o '"version": *"[^"]*"' "$script_dir/../package.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi

    # Fallback: try git tag
    if [[ -z "$version" ]] && command -v git &>/dev/null; then
        version=$(git -C "$script_dir/.." describe --tags --abbrev=0 2>/dev/null || echo "")
    fi

    echo "${version:-dev}"
}

#===============================================================================
# BUILD CO-AUTHOR TRAILERS
#
# Generates Co-authored-by trailers with full deduplication:
#   - Against git config user.email (avoid listing yourself as co-author)
#   - Against duplicate entries in the co_authors list
#   - Against co-authors already present in the commit message
# Arguments:
#   $1 - Pipe-separated list of co-authors (e.g., "Name1 <email1>|Name2 <email2>")
#   $2 - Worktree path (for git config lookup)
#   $3 - Commit message (optional, to check for existing co-authors)
# Returns: Newline-separated Co-authored-by trailers
#===============================================================================
build_coauthor_trailers() {
    local co_authors_list="$1"
    local worktree_path="$2"
    local commit_message="${3:-}"

    [[ -z "$co_authors_list" ]] && return 0

    cd "$worktree_path" || return 1

    # Get current git user email for deduplication
    local git_user_email
    git_user_email=$(git config user.email 2>/dev/null || echo "")

    local trailers=""
    local seen_emails=""  # Track emails we've already processed
    local IFS='|'
    for co_author in $co_authors_list; do
        [[ -z "$co_author" ]] && continue

        # Extract email from co-author string (format: "Name <email>")
        local email
        email=$(echo "$co_author" | grep -oE '<[^>]+>' | tr -d '<>')

        # Skip if no email found
        [[ -z "$email" ]] && continue

        # Skip if this is the same as the git config user (avoid listing yourself as co-author)
        if [[ "$email" == "$git_user_email" ]]; then
            log_debug "Skipping co-author (same as git user): $co_author"
            continue
        fi

        # Skip if we've already seen this email (duplicate in config)
        if [[ "$seen_emails" == *"|$email|"* ]]; then
            log_debug "Skipping duplicate co-author: $co_author"
            continue
        fi

        # Skip if this email is already in the commit message (user added manually in template)
        if [[ -n "$commit_message" && "$commit_message" == *"$email"* ]]; then
            log_debug "Skipping co-author (already in commit message): $co_author"
            continue
        fi

        # Track this email as seen
        seen_emails+="|$email|"

        trailers+="Co-authored-by: ${co_author}"$'\n'
    done

    # Remove trailing newline
    echo -n "${trailers%$'\n'}"
}

#===============================================================================
# COMMIT CHANGES
#
# Stages and commits all changes in the worktree.
#===============================================================================
commit_changes() {
    local worktree_path="$1"
    local commit_message="$2"
    local agent_id="${3:-unknown}"
    local co_authors="${4:-}"

    cd "$worktree_path"

    log_info "Staging changes..."
    git add -A

    # Validate staged files and remove suspicious ones
    # This catches literal ~ paths, .kapsis/ files, and accidental submodules
    validate_staged_files "$worktree_path"

    # Show what's being committed
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ CHANGES TO COMMIT                                                  │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    git status --short
    echo ""

    # Build co-author trailers (with full deduplication against git user, duplicates, and commit message)
    local coauthor_trailers=""
    if [[ -n "$co_authors" ]]; then
        coauthor_trailers=$(build_coauthor_trailers "$co_authors" "$worktree_path" "$commit_message")
    fi

    # Get Kapsis version
    local kapsis_version
    kapsis_version=$(get_kapsis_version)

    # Generate full commit message with metadata and co-authors
    local full_message
    full_message=$(cat << EOF
${commit_message}

Generated by Kapsis AI Agent Sandbox v${kapsis_version}
https://github.com/aviadshiber/kapsis
Agent ID: ${agent_id}
Worktree: $(basename "$worktree_path")
EOF
)

    # Append co-author trailers if present
    if [[ -n "$coauthor_trailers" ]]; then
        full_message+=$'\n\n'"${coauthor_trailers}"
    fi

    # Commit
    if git commit -m "$full_message"; then
        log_success "Changes committed"
        echo ""
        log_info "Commit details:"
        git log --oneline -1
        echo ""
        return 0
    else
        log_warn "Commit failed or nothing to commit"
        return 1
    fi
}

#===============================================================================
# VERIFY PUSH
#
# Verifies that the push actually succeeded by comparing local and remote HEAD.
# This addresses the issue where push may report success but commits aren't
# actually on the remote (network issues, partial failures, etc.).
#
# Returns: 0 if verified, 1 if verification failed
#===============================================================================
verify_push() {
    local worktree_path="$1"
    local remote="${2:-origin}"
    local branch="${3:-}"

    cd "$worktree_path"

    # Get current branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD)
    fi

    log_info "Verifying push to ${remote}/${branch}..."

    # Get local HEAD commit
    local local_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null)
    if [[ -z "$local_commit" ]]; then
        log_error "Could not determine local HEAD commit"
        status_set_push_info "failed" "" ""
        return 1
    fi
    log_debug "Local commit: $local_commit"

    # Fetch latest from remote to ensure we have current state
    if ! git fetch "$remote" "$branch" --quiet 2>/dev/null; then
        log_warn "Could not fetch from remote for verification"
        # Don't fail - the push might have worked even if fetch fails
        status_set_push_info "unverified" "$local_commit" ""
        return 0
    fi

    # Get remote HEAD commit after fetch
    local remote_commit
    remote_commit=$(git rev-parse "${remote}/${branch}" 2>/dev/null)
    log_debug "Remote commit: ${remote_commit:-unknown}"

    # Compare commits
    if [[ "$local_commit" == "$remote_commit" ]]; then
        log_success "Push verified: local and remote HEAD match"
        log_info "  Commit: ${local_commit:0:12}"
        status_set_push_info "success" "$local_commit" "$remote_commit"
        return 0
    else
        log_error "Push verification FAILED: commits do not match!"
        log_error "  Local:  $local_commit"
        log_error "  Remote: ${remote_commit:-not found}"
        status_set_push_info "failed" "$local_commit" "${remote_commit:-unknown}"
        return 1
    fi
}

#===============================================================================
# PUSH CHANGES
#
# Pushes the current branch to remote and verifies the push succeeded.
#===============================================================================
push_changes() {
    local worktree_path="$1"
    local remote="${2:-origin}"

    cd "$worktree_path"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ PUSHING TO REMOTE                                                  │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo "  Remote: $remote"
    echo "  Branch: $branch"
    echo ""

    # Capture local commit before push for verification
    local local_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null)

    if git push --set-upstream "$remote" "$branch"; then
        log_success "Push command completed"

        # Verify the push actually succeeded
        echo ""
        if verify_push "$worktree_path" "$remote" "$branch"; then
            # Generate PR URL only after verified push
            generate_pr_url "$worktree_path" "$branch"
            return 0
        else
            log_error "Push reported success but verification failed!"
            log_error "Commits may not have been pushed to remote."
            # Set fallback command for agent recovery
            status_set_push_fallback "$worktree_path" "$remote" "$branch"
            return 2  # Distinct exit code for verification failure
        fi
    else
        log_error "Push failed"
        status_set_push_info "failed" "$local_commit" ""
        # Set fallback command for agent recovery
        status_set_push_fallback "$worktree_path" "$remote" "$branch"
        return 1
    fi
}

#===============================================================================
# GENERATE PR URL
#
# Outputs a clickable URL to create a PR for the branch.
# Also sets the global PR_URL variable for status reporting.
#===============================================================================
# Global variable for PR URL (set by generate_pr_url, used by status reporting)
export PR_URL=""

generate_pr_url() {
    local worktree_path="$1"
    local branch="$2"

    cd "$worktree_path"

    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ -z "$remote_url" ]]; then
        return
    fi

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ CREATE PULL REQUEST                                                │"
    echo "└────────────────────────────────────────────────────────────────────┘"

    local pr_url=""
    if [[ "$remote_url" == *"bitbucket"* ]]; then
        # Bitbucket Cloud
        local repo_path
        repo_path=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//')
        pr_url="https://bitbucket.org/${repo_path}/pull-requests/new?source=${branch}"

    elif [[ "$remote_url" == ssh://* ]] || [[ "$remote_url" == https://*git* ]]; then
        # Generic Bitbucket Server / self-hosted git
        local base_url
        base_url=$(echo "$remote_url" | sed -E 's|^(https?://[^/]+).*|\1|' | sed -E 's|^ssh://([^@]+@)?([^:/]+).*|https://\2|')
        local repo_path
        repo_path=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//')
        pr_url="${base_url}/${repo_path}/pull-requests/new?source=${branch}"

    elif [[ "$remote_url" == *"github"* ]]; then
        # GitHub
        local repo_path
        repo_path=$(echo "$remote_url" | sed -E 's|.*github\.com[:/](.*)\.git|\1|' | sed 's/\.git$//')
        pr_url="https://github.com/${repo_path}/compare/${branch}?expand=1"

    elif [[ "$remote_url" == *"gitlab"* ]]; then
        # GitLab
        local repo_path
        repo_path=$(echo "$remote_url" | sed -E 's|.*gitlab\.com[:/](.*)\.git|\1|' | sed 's/\.git$//')
        pr_url="https://gitlab.com/${repo_path}/-/merge_requests/new?merge_request[source_branch]=${branch}"
    fi

    if [[ -n "$pr_url" ]]; then
        echo "  $pr_url"
        # Set global variable for status reporting
        PR_URL="$pr_url"
    else
        echo "  (Unable to generate PR URL for this remote)"
    fi

    echo ""
}

#===============================================================================
# SYNC INDEX
#
# Copies the updated index from worktree to sanitized git directory
# so container changes are properly tracked.
#===============================================================================
sync_index_from_container() {
    local worktree_path="$1"
    local sanitized_git="$2"

    if [[ -f "$sanitized_git/index" ]]; then
        # The container may have staged files - copy index back
        cd "$worktree_path"

        # Read the worktree's gitdir
        local gitdir_content
        gitdir_content=$(cat "$worktree_path/.git")
        local worktree_gitdir="${gitdir_content#gitdir: }"

        if [[ -f "$sanitized_git/index" ]]; then
            log_info "Syncing index from container..."
            cp "$sanitized_git/index" "$worktree_gitdir/index" 2>/dev/null || true
        fi
    fi
}

#===============================================================================
# DETECT GITHUB REPO
#
# Checks if remote URL is a GitHub repository
# Returns: 0 if GitHub, 1 otherwise
#===============================================================================
is_github_repo() {
    local worktree_path="$1"
    local remote="${2:-origin}"

    cd "$worktree_path" || return 1

    local remote_url
    remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")

    [[ "$remote_url" == *"github.com"* ]]
}

#===============================================================================
# CHECK IF USER HAS PUSH ACCESS
#
# Attempts a dry-run push to check access. Returns 0 if access, 1 otherwise.
#===============================================================================
has_push_access() {
    local worktree_path="$1"
    local remote="${2:-origin}"
    local branch="$3"

    cd "$worktree_path" || return 1

    # Try a dry-run push to check access
    if git push --dry-run "$remote" "$branch" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

#===============================================================================
# GENERATE FORK-BASED FALLBACK COMMAND
#
# Creates a fallback command that forks the repo and pushes to the fork.
# Uses GitHub CLI (gh) for forking.
#===============================================================================
generate_fork_fallback() {
    local worktree_path="$1"
    local branch="$2"
    local remote="${3:-origin}"

    cd "$worktree_path" || return 1

    local remote_url
    remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")

    # Only for GitHub repos
    if [[ "$remote_url" != *"github.com"* ]]; then
        return 1
    fi

    # Extract repo info (owner/repo) - validate format
    local repo_path
    repo_path=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//')

    # Validate repo_path format (should be owner/repo with safe characters)
    if [[ ! "$repo_path" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_warn "Invalid repository path format: $repo_path"
        return 1
    fi

    # Validate branch name (safe characters only)
    if [[ ! "$branch" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        log_warn "Invalid branch name format: $branch"
        return 1
    fi

    # Use single quotes to prevent shell injection when command is eval'd
    printf "cd '%s' && gh repo fork '%s' --remote --remote-name fork 2>/dev/null || true && git push -u fork '%s'" \
        "$worktree_path" "$repo_path" "$branch"
}

#===============================================================================
# GENERATE FORK PR URL
#
# Creates a PR URL for a fork-based contribution
#===============================================================================
generate_fork_pr_url() {
    local worktree_path="$1"
    local branch="$2"
    local remote="${3:-origin}"

    cd "$worktree_path" || return 1

    local remote_url
    remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")

    # Only for GitHub repos
    if [[ "$remote_url" != *"github.com"* ]]; then
        return 1
    fi

    # Extract upstream repo info
    local upstream_repo
    upstream_repo=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//')

    # Get current user (from gh or git config)
    local github_user=""
    if command -v gh &>/dev/null; then
        github_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
    fi

    if [[ -z "$github_user" ]]; then
        # Try to infer from fork remote if it exists
        github_user=$(git remote get-url fork 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+)/.*|\1|' || echo "YOUR_USERNAME")
    fi

    # Generate cross-fork PR URL
    echo "https://github.com/${upstream_repo}/compare/main...${github_user}:${branch}?expand=1"
}

#===============================================================================
# MAIN POST-CONTAINER WORKFLOW
#
# Orchestrates the full post-container git workflow:
# 1. Check for changes
# 2. Commit if changes exist
# 3. Push if requested (with fork fallback support)
#===============================================================================
post_container_git() {
    local worktree_path="$1"
    local branch="$2"
    local commit_message="${3:-feat: AI agent changes}"
    local remote="${4:-origin}"
    local no_push="${5:-false}"
    local agent_id="${6:-unknown}"
    local sanitized_git="${7:-}"
    local co_authors="${8:-}"
    local fork_enabled="${9:-false}"
    local fork_fallback="${10:-fork}"

    log_debug "post_container_git called with:"
    log_debug "  worktree_path=$worktree_path"
    log_debug "  branch=$branch"
    log_debug "  commit_message=$commit_message"
    log_debug "  remote=$remote"
    log_debug "  no_push=$no_push"
    log_debug "  agent_id=$agent_id"
    log_debug "  sanitized_git=$sanitized_git"
    log_debug "  co_authors=$co_authors"
    log_debug "  fork_enabled=$fork_enabled"
    log_debug "  fork_fallback=$fork_fallback"

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ POST-CONTAINER GIT OPERATIONS                                      │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo "  Worktree: $worktree_path"
    echo "  Branch:   $branch"
    echo ""

    # Sync index if sanitized git provided
    if [[ -n "$sanitized_git" && -d "$sanitized_git" ]]; then
        log_debug "Syncing index from sanitized git..."
        sync_index_from_container "$worktree_path" "$sanitized_git"
    fi

    # Check for changes
    log_debug "Checking for uncommitted changes..."
    if ! has_changes "$worktree_path"; then
        log_info "No changes to commit"
        return 0
    fi
    log_debug "Changes detected, proceeding with commit"

    # Update status: committing phase
    status_phase "committing" 92 "Staging and committing changes"

    # Commit changes
    log_debug "Committing changes..."
    if ! commit_changes "$worktree_path" "$commit_message" "$agent_id" "$co_authors"; then
        log_warn "Commit failed"
        return 1
    fi
    log_debug "Commit successful"

    # Push if not disabled
    if [[ "$no_push" != "true" ]]; then
        # Update status: pushing phase
        status_phase "pushing" 97 "Pushing to remote"

        log_debug "Pushing changes to remote..."
        local push_result
        push_changes "$worktree_path" "$remote"
        push_result=$?

        if [[ $push_result -eq 0 ]]; then
            log_debug "Push successful and verified"
        elif [[ $push_result -eq 2 ]]; then
            # Push command succeeded but verification failed
            log_error "Push verification failed! Commits may not be on remote."
            log_info "To check: cd $worktree_path && git fetch && git log --oneline HEAD ^origin/$branch"
            return 2
        else
            log_warn "Push failed. Changes are committed locally."

            # Check if fork workflow is enabled and this is a GitHub repo
            if [[ "$fork_fallback" == "fork" ]] && is_github_repo "$worktree_path" "$remote"; then
                log_info ""
                log_info "Fork workflow available for GitHub contribution:"

                local fork_cmd
                fork_cmd=$(generate_fork_fallback "$worktree_path" "$branch" "$remote")
                if [[ -n "$fork_cmd" ]]; then
                    echo ""
                    echo "┌────────────────────────────────────────────────────────────────────┐"
                    echo "│ FORK WORKFLOW FALLBACK                                             │"
                    echo "└────────────────────────────────────────────────────────────────────┘"
                    echo "KAPSIS_FORK_FALLBACK: $fork_cmd"
                    echo ""
                    echo "This command will:"
                    echo "  1. Fork the repository to your GitHub account"
                    echo "  2. Add the fork as a remote named 'fork'"
                    echo "  3. Push your branch to the fork"
                    echo ""

                    # Generate fork PR URL
                    local fork_pr_url
                    fork_pr_url=$(generate_fork_pr_url "$worktree_path" "$branch" "$remote")
                    if [[ -n "$fork_pr_url" ]]; then
                        echo "Then create a PR at:"
                        echo "  $fork_pr_url"
                        echo ""
                    fi
                fi
            else
                log_info "To push manually: cd $worktree_path && git push -u $remote $branch"
            fi
            return 1
        fi
    else
        log_info "Skipping push (--no-push specified)"
        log_info "To push: cd $worktree_path && git push -u $remote $branch"
        # Record that push was skipped with the local commit
        local local_commit
        local_commit=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")
        status_push_skipped "$local_commit"
    fi

    echo ""
    log_success "Post-container git operations complete"
    echo ""
    echo "To continue working on this branch:"
    echo "  cd $worktree_path"
    echo ""
    echo "Or re-run agent with same branch to continue:"
    echo "  ./launch-agent.sh <id> <project> --branch $branch"
    echo ""

    return 0
}

#===============================================================================
# MAIN (for standalone usage)
#===============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <worktree-path> <branch> [commit-message] [remote] [no-push] [agent-id]"
        echo ""
        echo "Arguments:"
        echo "  worktree-path   Path to the git worktree"
        echo "  branch          Branch name"
        echo "  commit-message  Commit message (default: 'feat: AI agent changes')"
        echo "  remote          Git remote (default: 'origin')"
        echo "  no-push         Set to 'true' to skip push (default: 'false')"
        echo "  agent-id        Agent identifier for commit metadata"
        echo ""
        echo "Example:"
        echo "  $0 ~/.kapsis/worktrees/myproject-1 feature/DEV-123 'fix: resolve auth bug'"
        exit 1
    fi

    post_container_git "$@"
fi
