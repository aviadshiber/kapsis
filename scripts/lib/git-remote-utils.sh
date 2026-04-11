#!/usr/bin/env bash
#===============================================================================
# Kapsis Git Remote Utilities
#
# Provides utility functions for working with git remote URLs across different
# providers (GitHub, GitLab, Bitbucket, Bitbucket Server).
#
# Functions:
#   detect_git_provider   - Detect provider from URL (github|gitlab|bitbucket|...)
#   extract_repo_path     - Extract owner/repo from any URL format
#   extract_repo_owner    - Extract just the owner/username
#   extract_base_url      - Extract protocol://domain from URL
#   validate_repo_path    - Security validation for repo paths
#   is_github_repo        - Check if worktree remote is GitHub
#   generate_pr_url       - Generate PR/MR creation URL for any provider
#===============================================================================

# Detect git provider from remote URL
# Usage: detect_git_provider "$remote_url"
# Returns: github|gitlab|bitbucket|bitbucket-server|unknown
detect_git_provider() {
    local url="$1"

    if [[ "$url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$url" == *"gitlab.com"* ]]; then
        echo "gitlab"
    elif [[ "$url" == *"bitbucket.org"* ]]; then
        echo "bitbucket"
    elif [[ "$url" == *"bitbucket"* ]] || [[ "$url" == *"git.taboolasyndication.com"* ]]; then
        # Bitbucket Server / self-hosted (includes Taboola's instance)
        echo "bitbucket-server"
    else
        echo "unknown"
    fi
}

# Extract owner/repo path from git URL
# Handles: git@host:owner/repo.git, https://host/owner/repo.git, ssh://...
# Usage: extract_repo_path "$remote_url"
# Returns: owner/repo (without .git suffix)
extract_repo_path() {
    local url="$1"

    # Remove .git suffix and extract owner/repo
    echo "$url" | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' | sed 's/\.git$//'
}

# Extract just the owner/username from git URL
# Usage: extract_repo_owner "$remote_url"
# Returns: owner
extract_repo_owner() {
    local url="$1"

    echo "$url" | sed -E 's|.*[:/]([^/]+)/[^/]+.*|\1|'
}

# Extract base URL (protocol://domain) from any git URL format
# Usage: extract_base_url "$remote_url"
# Returns: https://domain
extract_base_url() {
    local url="$1"

    if [[ "$url" == https://* ]]; then
        echo "$url" | sed -E 's|^(https?://[^/]+).*|\1|'
    elif [[ "$url" == ssh://* ]]; then
        echo "$url" | sed -E 's|^ssh://([^@]+@)?([^:/]+).*|https://\2|'
    elif [[ "$url" == git@* ]]; then
        echo "$url" | sed -E 's|^git@([^:]+):.*|https://\1|'
    else
        # Fallback: try to extract domain
        echo "$url" | sed -E 's|.*://([^/]+).*|https://\1|'
    fi
}

# Validate repo path format (security check)
# Prevents path traversal and injection attacks
# Usage: validate_repo_path "$path" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_repo_path() {
    local path="$1"

    # Must be alphanumeric with dots, underscores, hyphens, and single slash
    [[ "$path" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]
}

# Check if repository remote is GitHub
# Usage: is_github_repo "$worktree_path" [remote]
# Returns: 0 if GitHub, 1 otherwise
is_github_repo() {
    local worktree_path="$1"
    local remote="${2:-origin}"

    local url
    url=$(cd "$worktree_path" && git remote get-url "$remote" 2>/dev/null) || return 1

    [[ "$url" == *"github.com"* ]]
}

# Generate PR/MR creation URL for any supported provider
# Usage: generate_pr_url "$remote_url" "$branch"
# Returns: PR creation URL or empty string if unsupported
generate_pr_url() {
    local remote_url="$1"
    local branch="$2"

    local provider repo_path base_url

    provider=$(detect_git_provider "$remote_url")
    repo_path=$(extract_repo_path "$remote_url")

    case "$provider" in
        github)
            echo "https://github.com/${repo_path}/compare/${branch}?expand=1"
            ;;
        gitlab)
            echo "https://gitlab.com/${repo_path}/-/merge_requests/new?merge_request[source_branch]=${branch}"
            ;;
        bitbucket)
            echo "https://bitbucket.org/${repo_path}/pull-requests/new?source=${branch}"
            ;;
        bitbucket-server)
            base_url=$(extract_base_url "$remote_url")
            echo "${base_url}/${repo_path}/pull-requests/new?source=${branch}"
            ;;
        *)
            # Unknown provider - return empty
            echo ""
            ;;
    esac
}

# Get PR terminology for provider (PR vs MR)
# Usage: get_pr_term "$remote_url"
# Returns: "PR" or "MR"
get_pr_term() {
    local remote_url="$1"
    local provider

    provider=$(detect_git_provider "$remote_url")

    case "$provider" in
        gitlab)
            echo "MR"
            ;;
        *)
            echo "PR"
            ;;
    esac
}
