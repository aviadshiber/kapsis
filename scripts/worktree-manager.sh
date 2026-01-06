#!/usr/bin/env bash
#===============================================================================
# Kapsis - Git Worktree Manager
#
# Manages git worktrees for agent sandboxes with security isolation.
# Creates worktrees on host and prepares sanitized git environments for
# container mounting.
#
# Security Model:
# - Worktrees created on HOST (trusted environment)
# - Containers receive sanitized git view (restricted)
# - Empty hooks directory prevents hook-based attacks
# - Objects mounted read-only prevents corruption
# - Per-agent config prevents tampering
#===============================================================================

set -euo pipefail

# Script directory
WORKTREE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging library (only if not already loaded)
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$WORKTREE_SCRIPT_DIR/lib/logging.sh"
    log_init "worktree-manager"
fi

#===============================================================================
# CONFIGURATION
#===============================================================================
KAPSIS_WORKTREE_BASE="${KAPSIS_WORKTREE_BASE:-$HOME/.kapsis/worktrees}"
KAPSIS_SANITIZED_GIT_BASE="${KAPSIS_SANITIZED_GIT_BASE:-$HOME/.kapsis/sanitized-git}"

# Source shared constants (provides CONTAINER_GIT_PATH, CONTAINER_OBJECTS_PATH, etc.)
source "$WORKTREE_SCRIPT_DIR/lib/constants.sh"

# Note: logging functions are provided by lib/logging.sh

#===============================================================================
# GIT COMMAND HELPER
#
# Runs a git command, captures output, logs it, and returns exit code.
# Prevents git output from polluting stdout while preserving it in logs.
#
# Usage: run_git <command> [args...]
# Returns: exit code of git command
#===============================================================================
run_git() {
    local git_output
    local git_exit_code

    # Capture both stdout and stderr
    git_output=$("$@" 2>&1) && git_exit_code=0 || git_exit_code=$?

    # Log the output (goes to log file, not stdout)
    if [[ -n "$git_output" ]]; then
        log_debug "git command: $*"
        log_debug "git output: $git_output"
    fi

    # Log failure if non-zero exit
    if [[ $git_exit_code -ne 0 ]]; then
        log_debug "git command failed with exit code: $git_exit_code"
    fi

    return $git_exit_code
}

#===============================================================================
# ENSURE GIT EXCLUDES
#
# Adds protective patterns to $GIT_DIR/info/exclude to prevent accidental
# commits of Kapsis internal files and paths with literal ~ characters.
#
# IMPORTANT: This uses Git's info/exclude mechanism instead of .gitignore.
# The info/exclude file is local-only and NEVER committed, making Kapsis's
# protective patterns completely transparent to the user's repository.
#
# This addresses issue #89 where .gitignore modifications were appearing
# in user PRs, violating the principle of transparent sandbox operations.
#
# Patterns added:
# - .kapsis/           : Internal Kapsis spec/task files
# - ~                  : Literal tilde directory (failed expansion)
# - ~/                 : Literal tilde directory with trailing slash
# - .claude/           : Claude Code config files
# - .codex/            : Codex CLI config files
# - .aider/            : Aider config files
#===============================================================================
ensure_git_excludes() {
    local worktree_path="$1"

    # Determine the git directory for this worktree
    local git_dir=""
    if [[ -f "$worktree_path/.git" ]]; then
        # Worktree mode: .git is a file pointing to the actual git dir
        local gitdir_content
        gitdir_content=$(cat "$worktree_path/.git")
        git_dir="${gitdir_content#gitdir: }"
    elif [[ -d "$worktree_path/.git" ]]; then
        # Regular repo or overlay mode
        git_dir="$worktree_path/.git"
    else
        log_warn "Cannot determine git directory for: $worktree_path"
        return 1
    fi

    local exclude_path="$git_dir/info/exclude"

    # Ensure info directory exists
    mkdir -p "$git_dir/info"

    # Marker comment to identify Kapsis-added patterns
    local marker="# Kapsis protective patterns"

    # Check if patterns are already present (idempotency check)
    if [[ -f "$exclude_path" ]] && grep -qF "$marker" "$exclude_path" 2>/dev/null; then
        log_debug "Protective exclude patterns already present in info/exclude"
        return 0
    fi

    # Build patterns from constants (defined in constants.sh)
    local patterns
    patterns=$(printf '\n%s\n\n%s' "$KAPSIS_GIT_EXCLUDE_HEADER" "$KAPSIS_GIT_EXCLUDE_PATTERNS")

    # Append to existing info/exclude or create new
    if [[ -f "$exclude_path" ]]; then
        log_debug "Appending protective patterns to existing info/exclude"
        printf '%s\n' "$patterns" >> "$exclude_path"
    else
        log_debug "Creating info/exclude with protective patterns"
        printf '%s\n' "$patterns" > "$exclude_path"
    fi

    log_debug "Protective patterns written to $exclude_path"
}

#===============================================================================
# CREATE WORKTREE
#
# Creates a git worktree for an agent on the host filesystem.
# Returns the path to the created worktree.
#===============================================================================
create_worktree() {
    local project_path="$1"
    local agent_id="$2"
    local branch="$3"

    log_debug "create_worktree called with:"
    log_debug "  project_path=$project_path"
    log_debug "  agent_id=$agent_id"
    log_debug "  branch=$branch"

    # Validate inputs
    if [[ ! -d "$project_path/.git" ]]; then
        log_error "Project is not a git repository: $project_path"
        return 1
    fi

    local project_name
    project_name=$(basename "$project_path")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"
    log_debug "Computed worktree_path=$worktree_path"

    # Create base directory
    mkdir -p "$KAPSIS_WORKTREE_BASE"
    log_debug "Ensured worktree base dir exists: $KAPSIS_WORKTREE_BASE"

    # Navigate to project
    cd "$project_path"

    # Check if worktree already exists
    log_debug "Checking if worktree already exists..."
    if git worktree list | grep -q "$worktree_path"; then
        log_info "Reusing existing worktree: $worktree_path"
        log_debug "Worktree found in: $(git worktree list | grep "$worktree_path")"

        # Ensure we're on the right branch
        cd "$worktree_path"
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        log_debug "Current branch in worktree: $current_branch"

        if [[ "$current_branch" != "$branch" ]]; then
            log_info "Switching worktree from $current_branch to $branch"
            run_git git checkout "$branch" || run_git git checkout -b "$branch"
            log_debug "Branch switch completed"
        fi
    else
        log_info "Creating worktree for branch: $branch"

        # Fetch to ensure we have latest refs
        log_debug "Fetching from origin to get latest refs..."
        git fetch origin --prune 2>/dev/null || true

        # Check if branch is already checked out in main working directory
        local main_branch
        main_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$main_branch" == "$branch" ]]; then
            log_error "Branch '$branch' is currently checked out in the main repository"
            log_error "Worktrees cannot share a branch with the main working directory"
            log_error ""
            log_error "To fix this, either:"
            log_error "  1. Switch the main repo to a different branch first:"
            log_error "     cd $project_path && git checkout main"
            log_error "  2. Or use a different branch name for the worktree"
            return 1
        fi

        # Check if branch exists remotely
        log_debug "Checking if branch exists remotely..."
        if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
            # Branch exists remotely - track it
            log_info "Tracking existing remote branch: origin/$branch"
            log_debug "Running: git worktree add $worktree_path -b $branch origin/$branch"
            run_git git worktree add "$worktree_path" -b "$branch" "origin/$branch" ||
                run_git git worktree add "$worktree_path" "$branch" || true
        elif git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            # Branch exists locally
            log_info "Using existing local branch: $branch"
            log_debug "Running: git worktree add $worktree_path $branch"
            run_git git worktree add "$worktree_path" "$branch" || true
        else
            # Create new branch from current HEAD
            log_info "Creating new branch: $branch"
            log_debug "Running: git worktree add $worktree_path -b $branch"
            run_git git worktree add "$worktree_path" -b "$branch" || true
        fi
        log_debug "Worktree creation attempt completed"
    fi

    # Verify worktree was actually created
    if [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree directory was not created: $worktree_path"
        log_error "This can happen when:"
        log_error "  1. The branch is already checked out elsewhere (including main repo)"
        log_error "  2. There's a git lock file preventing operations"
        log_error "  3. Insufficient disk space or permissions"
        log_error ""
        log_error "Check 'git worktree list' in $project_path for existing worktrees"
        return 1
    fi

    if [[ ! -f "$worktree_path/.git" ]]; then
        log_error "Worktree directory exists but .git file is missing: $worktree_path"
        log_error "The worktree may be corrupted. Try running:"
        log_error "  cd $project_path && git worktree prune && git worktree remove $worktree_path --force"
        return 1
    fi

    # Ensure worktree is writable by container user (fixes UID mapping in rootless podman)
    # This is necessary because git worktree creates files with the host user's umask,
    # which may not be writable when mounted into a container with different UID mapping
    # Security: Use u+rwX,g+rX instead of a+rwX to avoid world-writable files
    # With --userns=keep-id, the container user maps to the host user
    chmod -R u+rwX,g+rX "$worktree_path" 2>/dev/null || true

    # Add protective exclude patterns to $GIT_DIR/info/exclude to prevent
    # accidental commits of:
    # - .kapsis/ directory (internal spec/task files)
    # - Literal ~ paths (tilde not expanded, creates directory named "~")
    # - Claude/Codex/Aider config files that shouldn't be committed
    # Using info/exclude instead of .gitignore keeps these patterns local-only
    # and completely transparent to the user (never committed) - fixes issue #89
    ensure_git_excludes "$worktree_path"

    log_success "Worktree ready: $worktree_path"
    echo "$worktree_path"
}

#===============================================================================
# PREPARE SANITIZED GIT
#
# Creates a sanitized .git directory for container mounting.
# This prevents hook-based attacks and config tampering while still
# allowing git operations in the container.
#
# Security measures:
# - Empty hooks directory (prevents execution of malicious hooks)
# - Minimal config (no credential helpers, fixed identity)
# - Read-only objects link (prevents object corruption)
# - Isolated refs (agent only sees its own branch)
#===============================================================================
prepare_sanitized_git() {
    local worktree_path="$1"
    local agent_id="$2"
    local project_path="$3"

    log_debug "prepare_sanitized_git called with:"
    log_debug "  worktree_path=$worktree_path"
    log_debug "  agent_id=$agent_id"
    log_debug "  project_path=$project_path"

    local sanitized_dir="${KAPSIS_SANITIZED_GIT_BASE}/${agent_id}"
    log_debug "sanitized_dir=$sanitized_dir"

    # Clean up any existing sanitized git
    log_debug "Cleaning up existing sanitized git directory..."
    rm -rf "$sanitized_dir"
    mkdir -p "$sanitized_dir"

    # Read the gitdir pointer from worktree's .git file
    local gitdir_content
    gitdir_content=$(cat "$worktree_path/.git")
    local worktree_gitdir="${gitdir_content#gitdir: }"
    log_debug "worktree_gitdir=$worktree_gitdir"

    # Find the parent .git directory (for shared objects)
    local parent_git="${project_path}/.git"
    log_debug "parent_git=$parent_git"

    log_info "Creating sanitized git environment"
    log_info "  Worktree gitdir: $worktree_gitdir"
    log_info "  Parent .git: $parent_git"

    # Create directory structure
    log_debug "Creating sanitized directory structure..."
    mkdir -p "$sanitized_dir/refs/heads"
    mkdir -p "$sanitized_dir/refs/remotes/origin"
    mkdir -p "$sanitized_dir/hooks"  # Empty! Critical for security
    mkdir -p "$sanitized_dir/info"   # For exclude patterns (issue #89)
    log_debug "Created refs/heads, refs/remotes/origin, hooks, and info directories"

    # Copy HEAD (current branch pointer)
    if [[ -f "$worktree_gitdir/HEAD" ]]; then
        cp "$worktree_gitdir/HEAD" "$sanitized_dir/HEAD"
    else
        echo "ref: refs/heads/main" > "$sanitized_dir/HEAD"
    fi

    # Copy only the agent's branch ref
    local current_branch
    current_branch=$(cd "$worktree_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    # Create parent directory for branch ref (needed for branches like feature/foo)
    mkdir -p "$sanitized_dir/refs/heads/$(dirname "$current_branch")" 2>/dev/null || true

    if [[ -f "$worktree_gitdir/refs/heads/$current_branch" ]]; then
        cp "$worktree_gitdir/refs/heads/$current_branch" "$sanitized_dir/refs/heads/$current_branch"
    elif [[ -f "$parent_git/refs/heads/$current_branch" ]]; then
        cp "$parent_git/refs/heads/$current_branch" "$sanitized_dir/refs/heads/$current_branch"
    fi

    # Copy packed-refs if exists (for refs stored in packed format)
    if [[ -f "$parent_git/packed-refs" ]]; then
        # Filter to only include the agent's branch and essential refs
        grep -E "^[0-9a-f]+ refs/(heads/$current_branch|tags/)" "$parent_git/packed-refs" > "$sanitized_dir/packed-refs" 2>/dev/null || true
    fi

    # Create index file link (needed for staging)
    if [[ -f "$worktree_gitdir/index" ]]; then
        cp "$worktree_gitdir/index" "$sanitized_dir/index"
    fi

    # Create minimal safe config
    create_safe_git_config "$sanitized_dir/config" "$worktree_path" "$agent_id"

    # Create objects symlink pointing to container mount path
    # The sanitized git will be mounted at $CONTAINER_GIT_PATH
    # and objects will be mounted at $CONTAINER_OBJECTS_PATH
    # This symlink allows git to find objects when running inside the container
    ln -sf "$CONTAINER_OBJECTS_PATH" "$sanitized_dir/objects"
    log_debug "Created objects symlink -> $CONTAINER_OBJECTS_PATH"

    # Create info/exclude with protective patterns (issue #89)
    # This ensures the container's git operations respect our exclude patterns
    # even though we're using a sanitized git directory
    # Patterns are defined in constants.sh for single source of truth
    printf '%s\n\n%s\n' "$KAPSIS_GIT_EXCLUDE_HEADER" "$KAPSIS_GIT_EXCLUDE_PATTERNS" > "$sanitized_dir/info/exclude"
    log_debug "Created info/exclude with protective patterns"

    # Create a marker file with paths for container setup
    cat > "$sanitized_dir/kapsis-meta" << EOF
# Kapsis Sanitized Git Metadata
WORKTREE_PATH=$worktree_path
PROJECT_PATH=$project_path
PARENT_GIT=$parent_git
AGENT_ID=$agent_id
BRANCH=$current_branch
EOF

    log_success "Sanitized git ready: $sanitized_dir"
    log_info "  Hooks directory: EMPTY (security)"
    log_info "  Config: minimal (no credentials)"
    log_info "  Excludes: info/exclude with protective patterns"
    log_info "  Branch: $current_branch"

    echo "$sanitized_dir"
}

#===============================================================================
# CREATE SAFE GIT CONFIG
#
# Creates a minimal git config without dangerous settings.
# No credential helpers, hooks, or other attack vectors.
#===============================================================================
create_safe_git_config() {
    local config_path="$1"
    local worktree_path="$2"
    local agent_id="$3"

    # Get remote URL from original repo (for pushing)
    local remote_url=""
    if cd "$worktree_path" 2>/dev/null; then
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    fi

    cat > "$config_path" << EOF
[core]
    repositoryformatversion = 0
    filemode = true
    bare = false
    # No fsmonitor, no hooks path, no credential helper
[user]
    name = Kapsis Agent $agent_id
    email = kapsis-agent-${agent_id}@localhost
[init]
    defaultBranch = main
[receive]
    denyCurrentBranch = updateInstead
EOF

    # Add remote if available (allows push via host post-processing)
    if [[ -n "$remote_url" ]]; then
        cat >> "$config_path" << EOF
[remote "origin"]
    url = $remote_url
    fetch = +refs/heads/*:refs/remotes/origin/*
EOF
    fi

    # Disable dangerous features
    cat >> "$config_path" << EOF
[transfer]
    fsckObjects = true
[fetch]
    fsckObjects = true
[receive]
    fsckObjects = true
[safe]
    directory = /workspace
EOF
}

#===============================================================================
# GET OBJECTS PATH
#
# Returns the path to the shared objects directory.
# This should be mounted read-only in the container.
#===============================================================================
get_objects_path() {
    local project_path="$1"
    echo "${project_path}/.git/objects"
}

#===============================================================================
# CLEANUP WORKTREE
#
# Removes a worktree and its associated sanitized git directory.
#===============================================================================
cleanup_worktree() {
    local project_path="$1"
    local agent_id="$2"

    local project_name
    project_name=$(basename "$project_path")
    local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"
    local sanitized_dir="${KAPSIS_SANITIZED_GIT_BASE}/${agent_id}"

    log_info "Cleaning up worktree for agent: $agent_id"

    # Remove worktree via git
    if [[ -d "$worktree_path" ]]; then
        cd "$project_path"
        git worktree remove "$worktree_path" --force 2>/dev/null || {
            log_warn "git worktree remove failed, forcing cleanup"
            rm -rf "$worktree_path"
            # Clean up the worktree reference
            rm -rf "$project_path/.git/worktrees/${project_name}-${agent_id}" 2>/dev/null || true
        }
        log_info "Removed worktree: $worktree_path"
    fi

    # Remove sanitized git directory
    if [[ -d "$sanitized_dir" ]]; then
        rm -rf "$sanitized_dir"
        log_info "Removed sanitized git: $sanitized_dir"
    fi

    log_success "Cleanup complete for agent: $agent_id"
}

#===============================================================================
# LIST WORKTREES
#
# Lists all Kapsis worktrees for a project.
#===============================================================================
list_worktrees() {
    local project_path="$1"

    if [[ ! -d "$project_path/.git" ]]; then
        log_error "Not a git repository: $project_path"
        return 1
    fi

    cd "$project_path"

    echo ""
    echo "Kapsis Worktrees for: $(basename "$project_path")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    git worktree list | while read -r line; do
        if [[ "$line" == *"$KAPSIS_WORKTREE_BASE"* ]]; then
            echo "  $line"
        fi
    done

    echo ""
}

#===============================================================================
# PRUNE STALE WORKTREES
#
# Removes worktrees that no longer have valid working directories.
#===============================================================================
prune_worktrees() {
    local project_path="$1"

    if [[ ! -d "$project_path/.git" ]]; then
        log_error "Not a git repository: $project_path"
        return 1
    fi

    cd "$project_path"

    log_info "Pruning stale worktrees..."
    git worktree prune --verbose

    # Also cleanup orphaned sanitized git directories
    if [[ -d "$KAPSIS_SANITIZED_GIT_BASE" ]]; then
        for dir in "$KAPSIS_SANITIZED_GIT_BASE"/*/; do
            [[ -d "$dir" ]] || continue
            local agent_id
            agent_id=$(basename "$dir")
            local project_name
            project_name=$(basename "$project_path")
            local worktree_path="${KAPSIS_WORKTREE_BASE}/${project_name}-${agent_id}"

            if [[ ! -d "$worktree_path" ]]; then
                log_info "Removing orphaned sanitized git: $dir"
                rm -rf "$dir"
            fi
        done
    fi

    log_success "Prune complete"
}

#===============================================================================
# MAIN (for standalone testing)
#===============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        create)
            create_worktree "${2:-.}" "${3:-test-agent}" "${4:-feature/test}"
            ;;
        sanitize)
            prepare_sanitized_git "${2:-.}" "${3:-test-agent}" "${4:-.}"
            ;;
        cleanup)
            cleanup_worktree "${2:-.}" "${3:-test-agent}"
            ;;
        list)
            list_worktrees "${2:-.}"
            ;;
        prune)
            prune_worktrees "${2:-.}"
            ;;
        *)
            echo "Usage: $0 {create|sanitize|cleanup|list|prune} [args...]"
            echo ""
            echo "Commands:"
            echo "  create <project> <agent-id> <branch>  Create worktree"
            echo "  sanitize <worktree> <agent-id> <project>  Create sanitized git"
            echo "  cleanup <project> <agent-id>          Remove worktree"
            echo "  list <project>                        List worktrees"
            echo "  prune <project>                       Remove stale worktrees"
            exit 1
            ;;
    esac
fi
