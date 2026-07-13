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

# Valid values for KAPSIS_GIT_PROVIDER (explicit override — see below).
# Guarded against redeclaration: this file may be sourced more than once in
# the same shell (e.g. by multiple libs/tests that each source it), and a
# bare `readonly` would abort with "readonly variable" on the second source.
if [[ -z "${_KAPSIS_VALID_GIT_PROVIDERS:-}" ]]; then
    readonly _KAPSIS_VALID_GIT_PROVIDERS="github gitlab bitbucket bitbucket-server azure-devops"
fi

# Detect git provider from remote URL.
#
# Checks $KAPSIS_GIT_PROVIDER first (an explicit override — see
# scripts/launch-agent.sh, which populates it from the git.provider config
# key). This is required for self-hosted instances: public hosts
# (github.com, gitlab.com, bitbucket.org) have fixed, pattern-matchable
# hostnames, but a self-hosted server at an arbitrary custom domain (e.g.
# Bitbucket Server, Azure DevOps, self-hosted GitLab) gives no reliable
# hint from the URL alone. Auto-detection for the public hosts remains the
# default with zero configuration — the override is optional, not required.
#
# Usage: detect_git_provider "$remote_url"
# Returns: github|gitlab|bitbucket|bitbucket-server|azure-devops|unknown
detect_git_provider() {
    local url="$1"

    if [[ -n "${KAPSIS_GIT_PROVIDER:-}" ]]; then
        local provider
        for provider in $_KAPSIS_VALID_GIT_PROVIDERS; do
            if [[ "$KAPSIS_GIT_PROVIDER" == "$provider" ]]; then
                echo "$provider"
                return 0
            fi
        done
        # Invalid value — fall through to auto-detection rather than
        # silently misrouting PR-URL generation.
    fi

    if [[ "$url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$url" == *"gitlab.com"* ]]; then
        echo "gitlab"
    elif [[ "$url" == *"bitbucket.org"* ]]; then
        echo "bitbucket"
    elif [[ "$url" == *"bitbucket"* ]]; then
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

# Generate Azure DevOps PR-creation URL, normalizing SSH-style remotes.
#
# Azure DevOps PR-creation URLs always use the
# https://dev.azure.com/{org}/{project}/_git/{repo} shape, regardless of the
# remote's clone protocol. SSH-style remotes use a different path shape
# (v3/{org}/{project}/{repo}, no _git segment) that must be translated. Since
# extract_base_url/extract_repo_path don't fit Azure's 3-segment path shape,
# this is handled as a dedicated helper rather than the generic case branch.
#
# Usage: _generate_azure_devops_pr_url "$remote_url" "$branch"
# Returns: PR creation URL, or empty string if the remote shape is unrecognized
_generate_azure_devops_pr_url() {
    local remote_url="$1"
    local branch="$2"

    # HTTPS-style: https://dev.azure.com/org/project/_git/repo
    #          or: https://org@dev.azure.com/org/project/_git/repo
    # (the org@ userinfo prefix is Azure DevOps' actual default Clone-button
    # form for most users - tolerate and strip it)
    if [[ "$remote_url" =~ ^https://([^@/]+@)?dev\.azure\.com/(.+)$ ]]; then
        local az_path="${BASH_REMATCH[2]%.git}"

        # Require the {org}/{project}/_git/{repo} shape (4 segments, with a
        # literal _git as the 3rd) - anything else is not a well-formed
        # Azure DevOps HTTPS remote and must not be turned into a
        # plausible-looking-but-wrong URL. Mirrors the SSH branch's
        # segment-count validation below.
        if [[ "$az_path" =~ ^([^/]+)/([^/]+)/_git/([^/]+)$ ]]; then
            local https_org="${BASH_REMATCH[1]}"
            local https_project="${BASH_REMATCH[2]}"
            local https_repo="${BASH_REMATCH[3]}"
            echo "https://dev.azure.com/${https_org}/${https_project}/_git/${https_repo}/pullrequestcreate?sourceRef=${branch}"
            return 0
        fi

        echo ""
        return 0
    fi

    # SSH-style: git@ssh.dev.azure.com:v3/org/project/repo
    #        or: ssh://git@ssh.dev.azure.com/v3/org/project/repo
    local ssh_path=""
    if [[ "$remote_url" =~ ^git@ssh\.dev\.azure\.com:v3/(.+)$ ]]; then
        ssh_path="${BASH_REMATCH[1]}"
    elif [[ "$remote_url" =~ ^ssh://git@ssh\.dev\.azure\.com/v3/(.+)$ ]]; then
        ssh_path="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$ssh_path" ]]; then
        ssh_path="${ssh_path%.git}"

        # Require exactly 3 non-empty path segments (org/project/repo) -
        # anything shorter or longer is not a well-formed Azure DevOps SSH
        # remote and must not be turned into a plausible-looking-but-wrong URL.
        if [[ "$ssh_path" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
            local org="${BASH_REMATCH[1]}"
            local project="${BASH_REMATCH[2]}"
            local repo="${BASH_REMATCH[3]}"
            echo "https://dev.azure.com/${org}/${project}/_git/${repo}/pullrequestcreate?sourceRef=${branch}"
            return 0
        fi
    fi

    # Unrecognized Azure DevOps remote shape - return empty rather than a
    # broken URL.
    echo ""
}

# Generate PR/MR creation URL for any supported provider.
#
# Checks $KAPSIS_GIT_PR_URL_TEMPLATE first — a full escape hatch for any
# provider Kapsis doesn't have built-in URL-format knowledge for (Gitea,
# etc.). Supports {base_url}, {repo_path}, {branch} placeholders. Falls
# back to the built-in per-provider formats (which respect
# KAPSIS_GIT_PROVIDER via detect_git_provider) when unset.
#
# The returned value is validated to start with http:// or https:// —
# a malicious/malformed template (or an unrecognized remote shape) is
# rejected as an empty string rather than surfaced as a clickable link,
# since this value is stored in status.json and rendered by the dashboard.
#
# Usage: generate_pr_url "$remote_url" "$branch"
# Returns: PR creation URL or empty string if unsupported/invalid
generate_pr_url() {
    local remote_url="$1"
    local branch="$2"

    local repo_path base_url
    repo_path=$(extract_repo_path "$remote_url")
    base_url=$(extract_base_url "$remote_url")

    local result=""

    if [[ -n "${KAPSIS_GIT_PR_URL_TEMPLATE:-}" ]]; then
        local template="$KAPSIS_GIT_PR_URL_TEMPLATE"
        template="${template//\{base_url\}/$base_url}"
        template="${template//\{repo_path\}/$repo_path}"
        template="${template//\{branch\}/$branch}"
        result="$template"
    else
        local provider
        provider=$(detect_git_provider "$remote_url")

        case "$provider" in
            github)
                result="https://github.com/${repo_path}/compare/${branch}?expand=1"
                ;;
            gitlab)
                result="https://gitlab.com/${repo_path}/-/merge_requests/new?merge_request[source_branch]=${branch}"
                ;;
            bitbucket)
                result="https://bitbucket.org/${repo_path}/pull-requests/new?source=${branch}"
                ;;
            bitbucket-server)
                result="${base_url}/${repo_path}/pull-requests/new?source=${branch}"
                ;;
            azure-devops)
                result=$(_generate_azure_devops_pr_url "$remote_url" "$branch")
                ;;
            *)
                # Unknown provider - return empty
                result=""
                ;;
        esac
    fi

    # Safety net: only ever surface http(s) URLs (rejects javascript:, data:,
    # and other dangerous schemes a malicious pr_url_template could produce).
    if [[ -n "$result" && ! "$result" =~ ^https?:// ]]; then
        result=""
    fi

    echo "$result"
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
