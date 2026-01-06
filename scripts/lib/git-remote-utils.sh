#!/usr/bin/env bash
#===============================================================================
# Kapsis Git Remote Utilities Library
#
# Provides utility functions for working with git remotes, detecting providers,
# parsing repository URLs, and generating PR/MR URLs.
#
# This library consolidates duplicated git remote handling code from
# post-container-git.sh and entrypoint.sh.
#
# Usage:
#   source "$SCRIPT_DIR/lib/git-remote-utils.sh"
#   provider=$(detect_git_provider "$remote_url")
#   repo_path=$(parse_repo_path "$remote_url")
#   pr_url=$(generate_pr_url "$remote_url" "$branch")
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_GIT_REMOTE_UTILS_LOADED:-}" ]] && return 0
_KAPSIS_GIT_REMOTE_UTILS_LOADED=1

#===============================================================================
# GIT PROVIDER DETECTION
#===============================================================================

# Detect the git hosting provider from a remote URL
# Arguments:
#   $1 - Git remote URL (SSH or HTTPS)
# Returns:
#   "github", "gitlab", "bitbucket", or "unknown"
detect_git_provider() {
    local remote_url="$1"

    if [[ "$remote_url" == *"github.com"* ]] || [[ "$remote_url" == *"github"* ]]; then
        echo "github"
    elif [[ "$remote_url" == *"gitlab.com"* ]] || [[ "$remote_url" == *"gitlab"* ]]; then
        echo "gitlab"
    elif [[ "$remote_url" == *"bitbucket.org"* ]] || [[ "$remote_url" == *"bitbucket"* ]]; then
        echo "bitbucket"
    else
        echo "unknown"
    fi
}

# Check if a remote URL is a GitHub repository
# Arguments:
#   $1 - Git remote URL
# Returns:
#   0 if GitHub, 1 otherwise
is_github_repo() {
    local remote_url="$1"
    [[ "$remote_url" == *"github.com"* ]]
}

# Check if a remote URL is a GitLab repository
# Arguments:
#   $1 - Git remote URL
# Returns:
#   0 if GitLab, 1 otherwise
is_gitlab_repo() {
    local remote_url="$1"
    [[ "$remote_url" == *"gitlab.com"* ]] || [[ "$remote_url" == *"gitlab"* ]]
}

# Check if a remote URL is a Bitbucket repository
# Arguments:
#   $1 - Git remote URL
# Returns:
#   0 if Bitbucket, 1 otherwise
is_bitbucket_repo() {
    local remote_url="$1"
    [[ "$remote_url" == *"bitbucket"* ]]
}

#===============================================================================
# URL PARSING
#===============================================================================

# Parse repository path (owner/repo) from a git remote URL
# Handles SSH, HTTPS, and git:// URLs for all major providers
# Arguments:
#   $1 - Git remote URL
# Returns:
#   Repository path in "owner/repo" format
parse_repo_path() {
    local remote_url="$1"
    local provider
    provider=$(detect_git_provider "$remote_url")

    case "$provider" in
        github)
            # Handle: git@github.com:owner/repo.git, https://github.com/owner/repo.git
            echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//'
            ;;
        gitlab)
            # Handle: git@gitlab.com:owner/repo.git, https://gitlab.com/owner/repo.git
            echo "$remote_url" | sed -E 's|.*gitlab\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//'
            ;;
        bitbucket)
            # Handle: git@bitbucket.org:owner/repo.git, https://bitbucket.org/owner/repo.git
            echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//'
            ;;
        *)
            # Generic fallback: extract last two path components
            echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//'
            ;;
    esac
}

# Validate repository path format (owner/repo with safe characters)
# Arguments:
#   $1 - Repository path to validate
# Returns:
#   0 if valid, 1 if invalid
validate_repo_path() {
    local repo_path="$1"
    [[ "$repo_path" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]
}

# Validate branch name format (safe characters only)
# Arguments:
#   $1 - Branch name to validate
# Returns:
#   0 if valid, 1 if invalid
validate_branch_name() {
    local branch="$1"
    [[ "$branch" =~ ^[a-zA-Z0-9/_.-]+$ ]]
}

#===============================================================================
# PR/MR URL GENERATION
#===============================================================================

# Generate a PR/MR creation URL for a branch
# Arguments:
#   $1 - Git remote URL
#   $2 - Branch name
#   $3 - Base branch (optional, defaults to provider default)
# Returns:
#   PR/MR URL or empty string if unable to generate
generate_pr_url() {
    local remote_url="$1"
    local branch="$2"
    local base_branch="${3:-}"

    local provider
    provider=$(detect_git_provider "$remote_url")

    local repo_path
    repo_path=$(parse_repo_path "$remote_url")

    # Validate inputs
    if ! validate_repo_path "$repo_path"; then
        return 1
    fi

    case "$provider" in
        github)
            if [[ -n "$base_branch" ]]; then
                echo "https://github.com/${repo_path}/compare/${base_branch}...${branch}?expand=1"
            else
                echo "https://github.com/${repo_path}/compare/${branch}?expand=1"
            fi
            ;;
        gitlab)
            echo "https://gitlab.com/${repo_path}/-/merge_requests/new?merge_request[source_branch]=${branch}"
            ;;
        bitbucket)
            echo "https://bitbucket.org/${repo_path}/pull-requests/new?source=${branch}"
            ;;
        *)
            # Try generic Bitbucket Server format for SSH URLs
            if [[ "$remote_url" == ssh://* ]] || [[ "$remote_url" == https://*git* ]]; then
                local base_url
                base_url=$(echo "$remote_url" | sed -E 's|^(https?://[^/]+).*|\1|' | sed -E 's|^ssh://([^@]+@)?([^:/]+).*|https://\2|')
                echo "${base_url}/${repo_path}/pull-requests/new?source=${branch}"
            else
                return 1
            fi
            ;;
    esac
}

# Generate a fork-based PR URL (for contributing to upstream repos)
# Arguments:
#   $1 - Upstream remote URL
#   $2 - Branch name
#   $3 - Fork owner (your GitHub username)
#   $4 - Base branch (optional, defaults to "main")
# Returns:
#   Cross-fork PR URL
generate_fork_pr_url() {
    local upstream_url="$1"
    local branch="$2"
    local fork_owner="$3"
    local base_branch="${4:-main}"

    local provider
    provider=$(detect_git_provider "$upstream_url")

    if [[ "$provider" != "github" ]]; then
        # Fork workflow primarily supported on GitHub
        return 1
    fi

    local upstream_repo
    upstream_repo=$(parse_repo_path "$upstream_url")

    if [[ -z "$fork_owner" ]]; then
        fork_owner="YOUR_USERNAME"
    fi

    echo "https://github.com/${upstream_repo}/compare/${base_branch}...${fork_owner}:${branch}?expand=1"
}

# Get the display name for PR/MR based on provider
# Arguments:
#   $1 - Git provider ("github", "gitlab", "bitbucket")
# Returns:
#   "PR" or "MR" or "Pull Request"
get_pr_display_name() {
    local provider="$1"

    case "$provider" in
        gitlab)
            echo "MR"
            ;;
        *)
            echo "PR"
            ;;
    esac
}

#===============================================================================
# FORK WORKFLOW HELPERS
#===============================================================================

# Generate a fork fallback command for when direct push fails
# Arguments:
#   $1 - Worktree/repo path
#   $2 - Branch name
#   $3 - Remote name (default: origin)
# Returns:
#   Command string to fork and push
generate_fork_fallback_command() {
    local worktree_path="$1"
    local branch="$2"
    local remote="${3:-origin}"

    # Get remote URL
    local remote_url
    remote_url=$(git -C "$worktree_path" remote get-url "$remote" 2>/dev/null || echo "")

    if ! is_github_repo "$remote_url"; then
        return 1
    fi

    local repo_path
    repo_path=$(parse_repo_path "$remote_url")

    if ! validate_repo_path "$repo_path"; then
        return 1
    fi

    if ! validate_branch_name "$branch"; then
        return 1
    fi

    # Use single quotes to prevent shell injection when command is eval'd
    printf "cd '%s' && gh repo fork '%s' --remote --remote-name fork 2>/dev/null || true && git push -u fork '%s'" \
        "$worktree_path" "$repo_path" "$branch"
}

#===============================================================================
# REMOTE URL HELPERS
#===============================================================================

# Get the remote URL for a repository
# Arguments:
#   $1 - Repository path (optional, defaults to current directory)
#   $2 - Remote name (optional, defaults to "origin")
# Returns:
#   Remote URL or empty string
get_remote_url() {
    local repo_path="${1:-.}"
    local remote="${2:-origin}"

    git -C "$repo_path" remote get-url "$remote" 2>/dev/null || echo ""
}

# Check if a directory is a git repository
# Arguments:
#   $1 - Directory path
# Returns:
#   0 if git repo, 1 otherwise
is_git_repo() {
    local path="$1"
    git -C "$path" rev-parse --git-dir &>/dev/null
}
