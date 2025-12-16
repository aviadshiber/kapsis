#!/usr/bin/env bash
#===============================================================================
# Kapsis Container Entrypoint
#
# Initializes the container environment before running the agent:
# 1. Sources SDKMAN and NVM
# 2. Initializes git branch (if KAPSIS_BRANCH is set)
# 3. Applies Maven settings override
# 4. Runs the agent command or specified command
#===============================================================================

set -euo pipefail

KAPSIS_HOME="${KAPSIS_HOME:-/opt/kapsis}"

# Source logging library
# In container: /opt/kapsis/lib/logging.sh
# On host (for testing): ./lib/logging.sh
# Define colors (used by both logging library and print_welcome banner)
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ -f "$KAPSIS_HOME/lib/logging.sh" ]]; then
    # Configure logging for container environment
    export KAPSIS_LOG_DIR="/tmp/kapsis-logs"
    export KAPSIS_LOG_MAX_SIZE_MB=5
    export KAPSIS_LOG_MAX_FILES=3
    source "$KAPSIS_HOME/lib/logging.sh"
    log_init "entrypoint"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
    log_init "entrypoint"
else
    # Fallback logging functions if library not available
    log_info() { echo -e "${CYAN}[KAPSIS]${NC} $*"; }
    log_success() { echo -e "${GREEN}[KAPSIS]${NC} $*"; }
    log_warn() { echo -e "${YELLOW}[KAPSIS]${NC} $*"; }
    log_error() { echo -e "\033[0;31m[KAPSIS]\033[0m $*" >&2; }
    log_debug() { [[ -n "${KAPSIS_DEBUG:-}" ]] && echo -e "\033[0;90m[DEBUG]\033[0m $*"; }
fi

#===============================================================================
# CLAUDE OAUTH INJECTION
#
# If CLAUDE_OAUTH_CREDENTIALS is set (from host keychain), store it in the
# container's secret store so Claude Code can authenticate.
#===============================================================================
inject_claude_oauth() {
    if [[ -z "${CLAUDE_OAUTH_CREDENTIALS:-}" ]]; then
        log_debug "No Claude OAuth credentials to inject"
        return 0
    fi

    log_info "Injecting Claude OAuth credentials..."

    # On Linux, Claude Code uses secret-tool (GNOME Keyring)
    if command -v secret-tool &>/dev/null; then
        # Store in GNOME Keyring / KDE Wallet
        echo -n "$CLAUDE_OAUTH_CREDENTIALS" | secret-tool store --label="Claude Code Credentials" \
            service "Claude Code-credentials" 2>/dev/null && {
            log_debug "OAuth stored in secret-tool"
            return 0
        }
    fi

    # Fallback: write to file-based credential store
    # Claude Code stores OAuth in ~/.claude/.credentials.json
    local cred_file="${HOME}/.claude/.credentials.json"
    mkdir -p "${HOME}/.claude" 2>/dev/null || true
    echo "$CLAUDE_OAUTH_CREDENTIALS" > "$cred_file"
    chmod 600 "$cred_file"
    log_debug "OAuth stored in $cred_file"

    # Unset the env var so it's not visible to child processes
    unset CLAUDE_OAUTH_CREDENTIALS
}

#===============================================================================
# STAGED CONFIG OVERLAY
#
# Host config files are mounted to /kapsis-staging/ (read-only).
# We create a fuse-overlayfs mount to make them writable via CoW:
# - Lower layer: /kapsis-staging/<path> (host files, read-only)
# - Upper layer: /kapsis-upper/<path> (container writes)
# - Merged view: $HOME/<path> (transparent CoW)
#
# This preserves true Copy-on-Write: reads from host, writes isolated.
#===============================================================================
setup_staged_config_overlays() {
    local staging_dir="/kapsis-staging"
    local upper_base="/kapsis-upper"
    local work_base="/kapsis-work"

    if [[ -z "${KAPSIS_STAGED_CONFIGS:-}" ]]; then
        log_debug "No staged configs to overlay"
        return 0
    fi

    log_info "Setting up CoW overlays for staged configs..."

    # Create base directories for upper and work layers
    mkdir -p "$upper_base" "$work_base" 2>/dev/null || true

    # Split comma-separated list
    IFS=',' read -ra configs <<< "$KAPSIS_STAGED_CONFIGS"

    for relative_path in "${configs[@]}"; do
        local src="${staging_dir}/${relative_path}"
        local dst="${HOME}/${relative_path}"
        local upper="${upper_base}/${relative_path}"
        local work="${work_base}/${relative_path}"

        if [[ ! -e "$src" ]]; then
            log_debug "Staged config not found: $src"
            continue
        fi

        # Create directories
        mkdir -p "$upper" "$work" "$(dirname "$dst")" 2>/dev/null || true

        if [[ -d "$src" ]]; then
            # Directory: create overlay mount
            mkdir -p "$dst" 2>/dev/null || true

            if fuse-overlayfs -o "lowerdir=${src},upperdir=${upper},workdir=${work}" "$dst" 2>/dev/null; then
                log_debug "CoW overlay: ${relative_path}"
            else
                # Fallback: copy if overlay fails
                log_warn "Overlay failed for ${relative_path}, falling back to copy"
                cp -r "$src" "$dst" 2>/dev/null || true
                chmod -R u+w "$dst" 2>/dev/null || true
            fi
        else
            # File: copy (no overlay for individual files)
            cp "$src" "$dst" 2>/dev/null || true
            chmod u+w "$dst" 2>/dev/null || true
            log_debug "Copied file: ${relative_path}"
        fi
    done

    log_success "Staged configs ready (CoW where possible)"
}

#===============================================================================
# WORKTREE MODE SETUP
#
# In worktree mode, the host has already created:
# - /workspace (mounted worktree directory)
# - /workspace/.git-safe (sanitized git directory, read-only)
# - /workspace/.git-objects (shared objects, read-only)
#
# We set up git to use the sanitized environment.
#===============================================================================
setup_worktree_git() {
    log_debug "setup_worktree_git: Checking for worktree mode..."

    # Check if we're in worktree mode
    if [[ ! -d "/workspace/.git-safe" ]]; then
        log_debug "setup_worktree_git: /workspace/.git-safe not found, not in worktree mode"
        return 1
    fi

    log_info "Worktree mode: Setting up sanitized git environment"
    log_debug "Found .git-safe directory"

    # Point git to sanitized directory
    export GIT_DIR=/workspace/.git-safe
    export GIT_WORK_TREE=/workspace
    export GIT_TEST_FSMONITOR=0
    log_debug "Set GIT_DIR=$GIT_DIR, GIT_WORK_TREE=$GIT_WORK_TREE"

    # Link objects if mount exists
    if [[ -d "/workspace/.git-objects" ]]; then
        # Create symlink from sanitized git to mounted objects
        ln -sf /workspace/.git-objects "$GIT_DIR/objects" 2>/dev/null || true
        log_info "  Objects: linked to /workspace/.git-objects"
    fi

    # Verify security: hooks directory must be empty
    local hooks_count
    hooks_count=$(find "$GIT_DIR/hooks" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$hooks_count" -gt 0 ]]; then
        log_warn "WARNING: Hooks directory is not empty ($hooks_count files) - clearing for security"
        rm -rf "$GIT_DIR/hooks"/*
    fi

    log_info "  GIT_DIR: $GIT_DIR"
    log_info "  GIT_WORK_TREE: $GIT_WORK_TREE"

    # Read metadata if available
    if [[ -f "$GIT_DIR/kapsis-meta" ]]; then
        log_info "  Worktree metadata found"
    fi

    return 0
}

#===============================================================================
# FUSE-OVERLAYFS SETUP (for macOS true CoW support, legacy mode)
#===============================================================================
setup_fuse_overlay() {
    if [[ "${KAPSIS_USE_FUSE_OVERLAY:-false}" != "true" ]]; then
        return
    fi

    log_info "Setting up fuse-overlayfs for true Copy-on-Write..."

    # Verify required mounts exist
    if [[ ! -d "/lower" ]]; then
        log_warn "KAPSIS_USE_FUSE_OVERLAY=true but /lower not mounted. Skipping overlay setup."
        return
    fi

    # Create overlay directories
    mkdir -p /upper/data /work/data /workspace 2>/dev/null || true

    # Mount fuse-overlayfs
    if fuse-overlayfs -o lowerdir=/lower,upperdir=/upper/data,workdir=/work/data /workspace 2>/dev/null; then
        log_success "fuse-overlayfs mounted successfully"
        log_info "  Lower (read-only): /lower"
        log_info "  Upper (writes):    /upper/data"
        log_info "  Merged view:       /workspace"

        # Git workaround: Copy .git directory to upper layer to avoid cross-device link issues
        # Git creates lock files that require same-filesystem linking
        if [[ -d /lower/.git ]] && [[ ! -d /upper/data/.git ]]; then
            log_info "Copying .git directory to upper layer for git compatibility..."
            # Use rsync-like copy that handles missing files gracefully
            cp -a /lower/.git /upper/data/.git 2>&1 | grep -v "No such file" || true
            # Verify the copy worked
            if [[ -d /upper/data/.git/objects ]]; then
                log_success ".git directory copied successfully"
                # Set GIT_DIR to point to the upper layer copy to avoid cross-device link issues
                export GIT_DIR=/upper/data/.git
                export GIT_WORK_TREE=/workspace
                export GIT_TEST_FSMONITOR=0
                log_info "Git configured: GIT_DIR=/upper/data/.git GIT_WORK_TREE=/workspace"
            else
                log_warn "Failed to copy .git directory"
            fi
        elif [[ -d /upper/data/.git ]]; then
            # .git already exists in upper (from previous run)
            export GIT_DIR=/upper/data/.git
            export GIT_WORK_TREE=/workspace
            export GIT_TEST_FSMONITOR=0
            log_info "Using existing .git in upper layer"
        fi
    else
        log_warn "fuse-overlayfs mount failed. Falling back to /lower as workspace."
        # Create symlink as fallback
        rm -rf /workspace 2>/dev/null || true
        ln -s /lower /workspace 2>/dev/null || true
    fi
}

#===============================================================================
# ENVIRONMENT SETUP
#===============================================================================
setup_environment() {
    log_info "Initializing environment..."

    # Source SDKMAN (disable strict mode temporarily for external scripts)
    if [[ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
        set +u
        source "$SDKMAN_DIR/bin/sdkman-init.sh"
        set -u
    fi

    # Source NVM (disable strict mode temporarily for external scripts)
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        set +u
        source "$NVM_DIR/nvm.sh"
        set -u
    fi

    # Apply isolated Maven settings
    if [[ -f "$KAPSIS_HOME/maven/settings.xml" ]]; then
        export MAVEN_ARGS="${MAVEN_ARGS:-} -s $KAPSIS_HOME/maven/settings.xml"
        log_info "Maven settings: $KAPSIS_HOME/maven/settings.xml"
    fi

    # Show Java version
    log_info "Java: $(java -version 2>&1 | head -1)"
    log_info "Maven: $(mvn -version 2>&1 | head -1)"
}

#===============================================================================
# GIT BRANCH INITIALIZATION
#===============================================================================
init_git_branch() {
    if [[ -z "${KAPSIS_BRANCH:-}" ]]; then
        return
    fi

    log_info "Initializing git branch: $KAPSIS_BRANCH"

    cd /workspace

    local remote="${KAPSIS_GIT_REMOTE:-origin}"

    # Fetch latest refs
    git fetch "$remote" --prune 2>/dev/null || log_warn "Could not fetch from $remote"

    # Check if remote branch exists
    if git ls-remote --exit-code --heads "$remote" "$KAPSIS_BRANCH" >/dev/null 2>&1; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ CONTINUING FROM EXISTING REMOTE BRANCH                        │"
        echo "│ Branch: $KAPSIS_BRANCH"
        echo "│ Remote: $remote"
        echo "└────────────────────────────────────────────────────────────────┘"

        # Checkout tracking the remote branch
        git checkout -b "$KAPSIS_BRANCH" "${remote}/${KAPSIS_BRANCH}" 2>/dev/null || \
            git checkout "$KAPSIS_BRANCH"

        # Ensure we're up to date
        git pull "$remote" "$KAPSIS_BRANCH" --ff-only 2>/dev/null || true

        echo ""
        log_info "Recent commits on this branch:"
        git log --oneline -5
        echo ""
    else
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ CREATING NEW BRANCH                                            │"
        echo "│ Branch: $KAPSIS_BRANCH"
        echo "│ Base: $(git rev-parse --abbrev-ref HEAD)"
        echo "└────────────────────────────────────────────────────────────────┘"

        # Create new branch from current HEAD
        git checkout -b "$KAPSIS_BRANCH"
        echo ""
    fi

    log_success "Ready to work on branch: $KAPSIS_BRANCH"
}

#===============================================================================
# POST-EXIT GIT OPERATIONS (called via trap)
#===============================================================================
post_exit_git() {
    if [[ -z "${KAPSIS_BRANCH:-}" ]]; then
        return
    fi

    cd /workspace

    # Check for changes
    if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
        echo ""
        log_info "No changes to commit"
        return
    fi

    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ COMMITTING CHANGES                                             │"
    echo "└────────────────────────────────────────────────────────────────┘"

    # Stage all changes
    git add -A

    # Show what's being committed
    git status --short
    echo ""

    # Generate commit message
    local task_summary="${KAPSIS_TASK:-AI agent changes}"
    task_summary="${task_summary:0:72}"  # Truncate

    local commit_msg="feat: ${task_summary}

Generated by Kapsis AI Agent Sandbox
Agent ID: ${KAPSIS_AGENT_ID:-unknown}
Branch: ${KAPSIS_BRANCH}"

    # Commit
    git commit -m "$commit_msg" || {
        log_warn "Nothing to commit or commit failed"
        return
    }

    # Push (unless KAPSIS_NO_PUSH is true)
    if [[ "${KAPSIS_NO_PUSH:-false}" != "true" ]]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ PUSHING TO REMOTE                                              │"
        echo "└────────────────────────────────────────────────────────────────┘"

        local remote="${KAPSIS_GIT_REMOTE:-origin}"
        git push --set-upstream "$remote" "$KAPSIS_BRANCH" || {
            log_warn "Push failed. Changes are committed locally."
            return
        }

        # Generate PR URL
        local remote_url
        remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")

        echo ""
        if [[ "$remote_url" == *"bitbucket"* ]]; then
            local repo_path
            repo_path=$(echo "$remote_url" | sed -E 's/.*[:/]([^/]+\/[^/]+)(\.git)?$/\1/' | sed 's/\.git$//')
            log_success "Create/View PR: https://bitbucket.org/${repo_path}/pull-requests/new?source=${KAPSIS_BRANCH}"
        elif [[ "$remote_url" == *"github"* ]]; then
            local repo_path
            repo_path=$(echo "$remote_url" | sed -E 's/.*github.com[:/](.*)\.git/\1/' | sed 's/\.git$//')
            log_success "Create/View PR: https://github.com/${repo_path}/compare/${KAPSIS_BRANCH}?expand=1"
        elif [[ "$remote_url" == *"gitlab"* ]]; then
            local repo_path
            repo_path=$(echo "$remote_url" | sed -E 's/.*gitlab.com[:/](.*)\.git/\1/' | sed 's/\.git$//')
            log_success "Create/View MR: https://gitlab.com/${repo_path}/-/merge_requests/new?merge_request[source_branch]=${KAPSIS_BRANCH}"
        fi

        echo ""
        log_success "Changes pushed successfully"
        echo ""
        echo "To continue after PR review, re-run with same branch:"
        echo "  ./launch-agent.sh <id> <project> --branch ${KAPSIS_BRANCH} --spec ./updated-spec.md"
    else
        echo ""
        log_success "Changes committed locally (--no-push)"
        echo "To push later: git push ${KAPSIS_GIT_REMOTE:-origin} ${KAPSIS_BRANCH}"
    fi
}

#===============================================================================
# PRINT WELCOME BANNER
#===============================================================================
print_welcome() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    KAPSIS SANDBOX READY                           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Agent ID:    ${KAPSIS_AGENT_ID:-unknown}"
    echo "Project:     ${KAPSIS_PROJECT:-unknown}"
    echo "Sandbox:     ${KAPSIS_SANDBOX_MODE:-overlay}"
    echo "Workspace:   /workspace"
    [[ -n "${KAPSIS_BRANCH:-}" ]] && echo "Branch:      ${KAPSIS_BRANCH}"
    [[ -f "/task-spec.md" ]] && echo "Spec File:   /task-spec.md"
    echo ""
    echo "Maven settings: $KAPSIS_HOME/maven/settings.xml (isolation enabled)"
    [[ "${KAPSIS_WORKTREE_MODE:-}" == "true" ]] && echo "Git:         using sanitized .git-safe (hooks disabled)"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    log_section "Kapsis Container Entrypoint Starting"
    log_debug "KAPSIS_HOME=$KAPSIS_HOME"
    log_debug "KAPSIS_AGENT_ID=${KAPSIS_AGENT_ID:-unset}"
    log_debug "KAPSIS_PROJECT=${KAPSIS_PROJECT:-unset}"
    log_debug "KAPSIS_BRANCH=${KAPSIS_BRANCH:-unset}"
    log_debug "KAPSIS_SANDBOX_MODE=${KAPSIS_SANDBOX_MODE:-unset}"

    # Detect and set up sandbox mode
    local sandbox_mode="${KAPSIS_SANDBOX_MODE:-overlay}"
    log_debug "Detected sandbox_mode=$sandbox_mode"

    # Set up CoW overlays for staged configs from /kapsis-staging/
    # This must happen before setup_environment so agent configs are available
    setup_staged_config_overlays

    # Inject OAuth credentials from host keychain if available
    inject_claude_oauth

    if [[ "$sandbox_mode" == "worktree" ]] || setup_worktree_git; then
        # Worktree mode: git is already set up by host
        log_info "Sandbox mode: worktree"
        log_debug "Setting up worktree mode environment"

        log_timer_start "environment_setup"
        setup_environment
        log_timer_end "environment_setup"

        # Skip init_git_branch - worktree already on correct branch
        print_welcome

        # Skip post-exit git trap - host handles commit/push
        log_debug "Post-exit git operations will be handled by host"

    else
        # Legacy overlay mode
        log_info "Sandbox mode: overlay"
        log_debug "Setting up overlay mode environment"

        # Set up fuse-overlayfs if on macOS
        log_timer_start "fuse_overlay_setup"
        setup_fuse_overlay
        log_timer_end "fuse_overlay_setup"

        log_timer_start "environment_setup"
        setup_environment
        log_timer_end "environment_setup"

        init_git_branch
        print_welcome

        # Set trap for post-exit git operations (overlay mode only)
        trap post_exit_git EXIT
        log_debug "Registered post_exit_git trap for EXIT signal"
    fi

    # Execute command
    log_debug "About to execute command: $*"
    if [[ $# -eq 0 ]]; then
        log_info "No command specified, launching interactive bash"
        exec bash
    else
        log_info "Executing command: $1"
        exec "$@"
    fi
}

main "$@"
