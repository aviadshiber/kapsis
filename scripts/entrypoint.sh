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

# Source status reporting library if available
# In container, status files are written to /kapsis-status (mounted from host)
if [[ -f "$KAPSIS_HOME/lib/status.sh" ]]; then
    source "$KAPSIS_HOME/lib/status.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"
fi

#===============================================================================
# CREDENTIAL FILE INJECTION (Agent-Agnostic)
#
# Writes environment variables to files based on KAPSIS_CREDENTIAL_FILES.
# This is agent-agnostic - works for Claude, Codex, Aider, or any agent
# that needs file-based credentials.
#
# Format: VAR_NAME|file_path|mode (comma-separated for multiple)
# Example: CLAUDE_OAUTH|~/.claude/.credentials.json|0600,OPENAI_KEY|~/.config/openai/key|0600
#===============================================================================
inject_credential_files() {
    if [[ -z "${KAPSIS_CREDENTIAL_FILES:-}" ]]; then
        log_debug "No credential files to inject"
        return 0
    fi

    log_info "Injecting credentials to files..."

    # Split comma-separated list
    IFS=',' read -ra creds <<< "$KAPSIS_CREDENTIAL_FILES"

    for entry in "${creds[@]}"; do
        IFS='|' read -r var_name file_path file_mode <<< "$entry"
        [[ -z "$var_name" || -z "$file_path" ]] && continue

        # Get the value from the environment variable
        local value="${!var_name:-}"
        if [[ -z "$value" ]]; then
            log_debug "Skipping $var_name - not set"
            continue
        fi

        # Expand ~ in file path
        file_path="${file_path/#\~/$HOME}"

        # Create parent directory
        mkdir -p "$(dirname "$file_path")" 2>/dev/null || true

        # Write the credential to file
        echo "$value" > "$file_path"
        chmod "${file_mode:-0600}" "$file_path"
        log_debug "Injected $var_name to $file_path"

        # Unset the env var so it's not visible to child processes
        unset "$var_name"
    done

    log_success "Credential files injected"
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
                # Use "$src/." to copy CONTENTS, not the directory itself (avoids nested structure)
                log_warn "Overlay failed for ${relative_path}, falling back to copy"
                cp -r "$src/." "$dst/" 2>/dev/null || true
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

    # Configure git hooks (disable by default for container compatibility)
    configure_git_hooks

    log_info "  GIT_DIR: $GIT_DIR"
    log_info "  GIT_WORK_TREE: $GIT_WORK_TREE"

    # Read metadata if available
    if [[ -f "$GIT_DIR/kapsis-meta" ]]; then
        log_info "  Worktree metadata found"
    fi

    return 0
}

#===============================================================================
# GIT HOOKS CONFIGURATION
#
# Git hooks may reference interpreters/tools not available in the container,
# causing "cannot run X: No such file or directory" errors. By default, we
# disable hooks to prevent these errors. Users can enable hooks if their
# container image has the required tooling.
#===============================================================================
configure_git_hooks() {
    local git_dir="${GIT_DIR:-/upper/data/.git}"

    if [[ "${KAPSIS_ENABLE_HOOKS:-false}" == "true" ]]; then
        # User explicitly wants hooks enabled - assume they've configured
        # the container with necessary tools
        log_info "Git hooks enabled (KAPSIS_ENABLE_HOOKS=true)"
        return 0
    fi

    # Disable hooks by redirecting to empty directory
    # This prevents "cannot run" errors while preserving original hooks
    local empty_hooks_dir="$git_dir/hooks-disabled"
    mkdir -p "$empty_hooks_dir" 2>/dev/null || true

    # Use git config to redirect hooks path (safer than deleting hooks)
    if [[ -d "$git_dir" ]]; then
        git config --file "$git_dir/config" core.hooksPath "$empty_hooks_dir" 2>/dev/null || true
        log_warn "Git hooks disabled in sandbox (hooks may reference unavailable tools)"
        log_info "  To enable hooks: set KAPSIS_ENABLE_HOOKS=true"
        log_info "  Original hooks preserved in: $git_dir/hooks/"
    fi
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

    # Determine overlay directory layout
    # New layout: single /overlay volume with upper/ and work/ subdirectories
    # This ensures upperdir and workdir are on the same filesystem (required by overlayfs)
    # Legacy layout: separate /upper and /work volumes (deprecated due to EXDEV errors)
    local upper_dir work_dir
    if [[ -d "/overlay" ]]; then
        # New layout: single volume
        upper_dir="/overlay/upper"
        work_dir="/overlay/work"
    else
        # Legacy layout: separate volumes (may cause EXDEV errors on mkdir)
        upper_dir="/upper/data"
        work_dir="/work/data"
    fi

    # Create overlay directories
    mkdir -p "$upper_dir" "$work_dir" /workspace 2>/dev/null || true

    # Mount fuse-overlayfs
    # Note: noxattr is required on some systems (e.g., GitHub Actions) where copying
    # extended attributes during copy-up fails with "Operation not permitted" (EPERM)
    # when the container doesn't have capabilities to set certain xattrs
    if fuse-overlayfs -o "lowerdir=/lower,upperdir=$upper_dir,workdir=$work_dir,noxattr" /workspace 2>/dev/null; then
        log_success "fuse-overlayfs mounted successfully"
        log_info "  Lower (read-only): /lower"
        log_info "  Upper (writes):    $upper_dir"
        log_info "  Merged view:       /workspace"

        # Git workaround: Copy .git directory to upper layer to avoid cross-device link issues
        # Git creates lock files that require same-filesystem linking
        local git_upper="$upper_dir/.git"
        if [[ -d /lower/.git ]] && [[ ! -d "$git_upper" ]]; then
            log_info "Copying .git directory to upper layer for git compatibility..."
            # Use rsync-like copy that handles missing files gracefully
            cp -a /lower/.git "$git_upper" 2>&1 | grep -v "No such file" || true
            # Verify the copy worked
            if [[ -d "$git_upper/objects" ]]; then
                log_success ".git directory copied successfully"

                # Set GIT_DIR to point to the upper layer copy to avoid cross-device link issues
                export GIT_DIR="$git_upper"
                export GIT_WORK_TREE=/workspace
                export GIT_TEST_FSMONITOR=0
                log_info "Git configured: GIT_DIR=$git_upper GIT_WORK_TREE=/workspace"

                configure_git_hooks
            else
                log_warn "Failed to copy .git directory"
            fi
        elif [[ -d "$git_upper" ]]; then
            # .git already exists in upper (from previous run)
            export GIT_DIR="$git_upper"
            export GIT_WORK_TREE=/workspace
            export GIT_TEST_FSMONITOR=0
            log_info "Using existing .git in upper layer"

            configure_git_hooks
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

    # Set default paths for SDKMAN and NVM if not set
    SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
    NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

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

    # Decode DOCKER_ARTIFACTORY_TOKEN into username/password for Maven
    # Token format: base64(username:password)
    if [[ -n "${DOCKER_ARTIFACTORY_TOKEN:-}" ]] && [[ -z "${KAPSIS_MAVEN_USERNAME:-}" ]]; then
        local decoded
        decoded=$(echo "$DOCKER_ARTIFACTORY_TOKEN" | base64 -d 2>/dev/null || true)
        if [[ "$decoded" == *":"* ]]; then
            export KAPSIS_MAVEN_USERNAME="${decoded%%:*}"
            export KAPSIS_MAVEN_PASSWORD="${decoded#*:}"
            log_info "Artifactory credentials: decoded from DOCKER_ARTIFACTORY_TOKEN"
        fi
    fi

    # Pre-populate Maven local repo with GE extensions from image cache
    # This is needed because the .m2/repository is a named volume that shadows the image contents
    if [[ -d "$KAPSIS_HOME/m2-cache" ]]; then
        local user_m2="$HOME/.m2/repository"
        mkdir -p "$user_m2"
        # Only copy if GE extension not already present (avoid overwriting on restart)
        if [[ ! -f "$user_m2/com/gradle/gradle-enterprise-maven-extension/1.20/gradle-enterprise-maven-extension-1.20.jar" ]]; then
            cp -r "$KAPSIS_HOME/m2-cache/"* "$user_m2/" 2>/dev/null || true
            log_info "Gradle Enterprise extension: pre-populated from image cache"
        fi
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

    # Inject credentials to files (agent-agnostic)
    # Reads KAPSIS_CREDENTIAL_FILES env var set by launch-agent.sh
    inject_credential_files

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

    # Update status to running phase (container-side)
    # Initialize from environment variables passed by launch-agent.sh
    if [[ -n "${KAPSIS_STATUS_PROJECT:-}" && -n "${KAPSIS_STATUS_AGENT_ID:-}" ]]; then
        status_init \
            "${KAPSIS_STATUS_PROJECT}" \
            "${KAPSIS_STATUS_AGENT_ID}" \
            "${KAPSIS_STATUS_BRANCH:-}" \
            "${KAPSIS_SANDBOX_MODE:-overlay}" \
            ""
        status_phase "running" 25 "Agent starting execution"
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
