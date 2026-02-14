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
    # Fallback sanitize_secrets for when logging.sh is not available
    # Security: Mask sensitive environment variables in log output
    sanitize_secrets() {
        echo "$*" | sed -E 's/(-e [A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS|AUTH|BEARER|API_KEY|PRIVATE)[A-Za-z0-9_]*)=[^ ]*/\1=***MASKED***/gi'
    }
    log_debug() {
        if [[ -n "${KAPSIS_DEBUG:-}" ]]; then
            local sanitized
            sanitized=$(sanitize_secrets "$*")
            echo -e "\033[0;90m[DEBUG]\033[0m $sanitized"
        fi
    }
fi

# Source status reporting library if available
# In container, status files are written to /kapsis-status (mounted from host)
if [[ -f "$KAPSIS_HOME/lib/status.sh" ]]; then
    source "$KAPSIS_HOME/lib/status.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"
fi

# Source shared constants (provides CONTAINER_GIT_PATH, CONTAINER_OBJECTS_PATH, etc.)
if [[ -f "$KAPSIS_HOME/lib/constants.sh" ]]; then
    source "$KAPSIS_HOME/lib/constants.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/constants.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/constants.sh"
fi

# Source git remote utilities (provides generate_pr_url, detect_git_provider, etc.)
if [[ -f "$KAPSIS_HOME/lib/git-remote-utils.sh" ]]; then
    source "$KAPSIS_HOME/lib/git-remote-utils.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/git-remote-utils.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/git-remote-utils.sh"
fi

# Source atomic copy library (race-condition-safe file staging, fixes #151)
if [[ -f "$KAPSIS_HOME/lib/atomic-copy.sh" ]]; then
    source "$KAPSIS_HOME/lib/atomic-copy.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/atomic-copy.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/atomic-copy.sh"
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

        # Create parent directory with secure permissions
        mkdir -p "$(dirname "$file_path")" 2>/dev/null || true

        # Security: Set restrictive umask before file creation to prevent race condition
        # This ensures the file is never world-readable, even momentarily
        local old_umask
        old_umask=$(umask)
        umask 0077

        # Write the credential to file (protected by umask)
        if ! echo "$value" > "$file_path" 2>/dev/null; then
            umask "$old_umask"
            log_error "Failed to write credential to $file_path"
            continue
        fi

        # Restore original umask
        umask "$old_umask"

        # Explicitly set final permissions for clarity
        chmod "${file_mode:-0600}" "$file_path" 2>/dev/null || true
        log_debug "Injected $var_name to $file_path (mode: ${file_mode:-0600})"

        # Unset the env var so it's not visible to child processes
        unset "$var_name"
    done

    log_success "Credential files injected"
}

#===============================================================================
# SSH PERMISSION FIXUP (Issue #159)
#
# Safety net: after atomic-copy stages files, ensure SSH directories and keys
# have correct permissions. SSH refuses keys with overly permissive modes.
#===============================================================================
fix_ssh_permissions() {
    local ssh_dir="$1"

    if [[ ! -d "$ssh_dir" ]]; then
        return 0
    fi

    log_debug "Fixing SSH permissions: $ssh_dir"

    # Directory itself must be 0700
    chmod 700 "$ssh_dir" 2>/dev/null || true

    # Fix permissions on known SSH file patterns
    local file file_basename
    for file in "$ssh_dir"/*; do
        [[ -f "$file" ]] || continue
        file_basename=$(basename "$file")

        case "$file_basename" in
            # Public keys — slightly more permissive is OK
            id_*.pub|*.pub)
                chmod 644 "$file" 2>/dev/null || true
                ;;
            # Private keys (id_rsa, id_ed25519, id_ecdsa, etc.)
            id_*)
                chmod 600 "$file" 2>/dev/null || true
                ;;
            # Certificate and PEM key files
            *.pem|*.key)
                chmod 600 "$file" 2>/dev/null || true
                ;;
            # SSH config, authorized_keys, known_hosts
            config|authorized_keys|known_hosts)
                chmod 600 "$file" 2>/dev/null || true
                ;;
        esac
    done

    log_debug "SSH permissions fixed"
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
                # Fallback: atomic copy with validation (fixes race condition #151)
                log_warn "Overlay failed for ${relative_path}, falling back to atomic copy"
                atomic_copy_dir "$src" "$dst" || log_warn "Atomic copy validation failed for dir: ${relative_path}"
            fi
        else
            # File: atomic copy with validation (fixes race condition #151)
            if atomic_copy_file "$src" "$dst"; then
                log_debug "Copied file (atomic): ${relative_path}"
            else
                log_warn "Atomic copy validation failed for file: ${relative_path}"
            fi
        fi
    done

    # Fix SSH permissions if .ssh was staged (safety net, issue #159)
    if [[ -d "${HOME}/.ssh" ]]; then
        fix_ssh_permissions "${HOME}/.ssh"
    fi

    log_success "Staged configs ready (CoW where possible)"
}

#===============================================================================
# WORKTREE MODE SETUP
#
# In worktree mode, the host has already created:
# - /workspace (mounted worktree directory)
# - $CONTAINER_GIT_PATH (sanitized git at .git-safe, can't mount over .git file)
# - $CONTAINER_OBJECTS_PATH (shared objects, read-only)
#
# Since worktrees have a .git FILE (not directory), we mount sanitized git at
# .git-safe and set GIT_DIR to make git commands work.
#===============================================================================
setup_worktree_git() {
    log_debug "setup_worktree_git: Checking for worktree mode..."

    # Check if we're in worktree mode by looking for the kapsis-meta file
    # This file is created by prepare_sanitized_git and indicates we have
    # a mounted sanitized git directory
    if [[ ! -f "${CONTAINER_GIT_PATH}/kapsis-meta" ]]; then
        log_debug "setup_worktree_git: ${CONTAINER_GIT_PATH}/kapsis-meta not found, not in worktree mode"
        return 1
    fi

    log_info "Worktree mode: using sanitized .git (hooks isolated)"

    # Set GIT_DIR to the sanitized git location
    # This is required because worktrees have a .git FILE containing a host path,
    # which doesn't exist in the container. We mount sanitized git at .git-safe.
    export GIT_DIR="${CONTAINER_GIT_PATH}"
    log_debug "setup_worktree_git: GIT_DIR=${GIT_DIR}"

    # Disable fsmonitor for container compatibility
    export GIT_TEST_FSMONITOR=0

    # Read metadata if available
    local branch
    branch=$(grep "^BRANCH=" "${CONTAINER_GIT_PATH}/kapsis-meta" 2>/dev/null | cut -d= -f2)
    if [[ -n "$branch" ]]; then
        log_info "  Branch: $branch"
    fi

    return 0
}

#===============================================================================
# GIT HOOKS CONFIGURATION
#
# In a rootless isolated container, git hooks aren't a security concern - they
# can only affect the sandboxed environment. We allow hooks to run naturally;
# if they fail (e.g., referencing tools not in container), it's graceful degradation.
#===============================================================================
configure_git_hooks() {
    if [[ "${KAPSIS_DISABLE_HOOKS:-false}" == "true" ]]; then
        # User explicitly wants hooks disabled
        log_info "Git hooks disabled (KAPSIS_DISABLE_HOOKS=true)"
        git config --global core.hooksPath /dev/null 2>/dev/null || true
        return 0
    fi

    # Hooks run normally - sandbox isolation provides security
    log_info "Git hooks: using project hooks (sandbox isolated)"
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
    # Options:
    # - squash_to_uid/gid: Makes lower layer files appear owned by container user,
    #   enabling copy-up operations that would otherwise fail with EPERM when the
    #   lower layer has different ownership (common with host directory mounts)
    # - noxattr: Disables extended attributes to avoid permission issues
    # See: https://github.com/containers/fuse-overlayfs/issues/428
    local mount_uid mount_gid
    mount_uid=$(id -u)
    mount_gid=$(id -g)
    if fuse-overlayfs -o "lowerdir=/lower,upperdir=$upper_dir,workdir=$work_dir,squash_to_uid=$mount_uid,squash_to_gid=$mount_gid,noxattr" /workspace 2>/dev/null; then
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

    # Auto-switch Java version if configured via KAPSIS_JAVA_VERSION
    # This allows users to specify Java version in their Kapsis config:
    #   environment:
    #     set:
    #       KAPSIS_JAVA_VERSION: "8"
    if [[ -n "${KAPSIS_JAVA_VERSION:-}" ]]; then
        log_info "Switching to Java $KAPSIS_JAVA_VERSION (from KAPSIS_JAVA_VERSION)"
        if [[ -x "$KAPSIS_HOME/switch-java.sh" ]]; then
            source "$KAPSIS_HOME/switch-java.sh" "$KAPSIS_JAVA_VERSION"
        else
            log_warn "switch-java.sh not found at $KAPSIS_HOME/switch-java.sh"
        fi
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
    # Remote branch name defaults to local branch name when not specified
    local remote_branch="${KAPSIS_REMOTE_BRANCH:-$KAPSIS_BRANCH}"

    # Fetch latest refs
    git fetch "$remote" --prune 2>/dev/null || log_warn "Could not fetch from $remote"

    # Check if remote branch exists (use remote branch name for lookup)
    if git ls-remote --exit-code --heads "$remote" "$remote_branch" >/dev/null 2>&1; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ CONTINUING FROM EXISTING REMOTE BRANCH                        │"
        echo "│ Local Branch:  $KAPSIS_BRANCH"
        if [[ "$remote_branch" != "$KAPSIS_BRANCH" ]]; then
        echo "│ Remote Branch: $remote_branch"
        fi
        echo "│ Remote: $remote"
        echo "└────────────────────────────────────────────────────────────────┘"

        # Checkout local branch tracking the remote branch
        git checkout -b "$KAPSIS_BRANCH" "${remote}/${remote_branch}" 2>/dev/null || \
            git checkout "$KAPSIS_BRANCH"

        # Ensure we're up to date
        git pull "$remote" "$remote_branch" --ff-only 2>/dev/null || true

        echo ""
        log_info "Recent commits on this branch:"
        git log --oneline -5
        echo ""
    else
        # Fix #116: Use KAPSIS_BASE_BRANCH if specified, otherwise current HEAD
        local base_ref="${KAPSIS_BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ CREATING NEW BRANCH                                            │"
        echo "│ Local Branch:  $KAPSIS_BRANCH"
        if [[ "$remote_branch" != "$KAPSIS_BRANCH" ]]; then
        echo "│ Remote Branch: $remote_branch"
        fi
        echo "│ Base: $base_ref"
        echo "└────────────────────────────────────────────────────────────────┘"

        # Create new branch from specified base or current HEAD
        if [[ -n "${KAPSIS_BASE_BRANCH:-}" ]]; then
            # Ensure we have the base ref
            git fetch "$remote" "$KAPSIS_BASE_BRANCH" 2>/dev/null || true
            git fetch "$remote" "refs/tags/$KAPSIS_BASE_BRANCH:refs/tags/$KAPSIS_BASE_BRANCH" 2>/dev/null || true

            if git rev-parse --verify "$KAPSIS_BASE_BRANCH" >/dev/null 2>&1; then
                git checkout -b "$KAPSIS_BRANCH" "$KAPSIS_BASE_BRANCH"
            else
                log_warn "Base ref '$KAPSIS_BASE_BRANCH' not found, using current HEAD"
                git checkout -b "$KAPSIS_BRANCH"
            fi
        else
            git checkout -b "$KAPSIS_BRANCH"
        fi
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

    local has_uncommitted=false
    local has_unpushed=false

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]; then
        has_uncommitted=true
    fi

    # Check for unpushed commits (compare with remote tracking branch)
    local remote="${KAPSIS_GIT_REMOTE:-origin}"
    # Remote branch name defaults to local branch name when not specified
    local remote_branch="${KAPSIS_REMOTE_BRANCH:-$KAPSIS_BRANCH}"
    if git rev-parse --verify "${remote}/${remote_branch}" >/dev/null 2>&1; then
        # Remote branch exists - check if we're ahead
        local ahead
        ahead=$(git rev-list --count "${remote}/${remote_branch}..HEAD" 2>/dev/null || echo "0")
        if [[ "$ahead" -gt 0 ]]; then
            has_unpushed=true
        fi
    else
        # Remote branch doesn't exist - any local commits are unpushed
        local commits
        commits=$(git rev-list --count HEAD 2>/dev/null || echo "0")
        if [[ "$commits" -gt 0 ]]; then
            has_unpushed=true
        fi
    fi

    # If nothing to commit and nothing to push, exit early
    if [[ "$has_uncommitted" == "false" && "$has_unpushed" == "false" ]]; then
        echo ""
        log_info "No changes to commit or push"
        return
    fi

    # Commit uncommitted changes (if any)
    if [[ "$has_uncommitted" == "true" ]]; then
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
        }
    fi

    # Push if enabled via --push flag (KAPSIS_DO_PUSH=true)
    # This runs regardless of whether we committed above - agent may have committed itself
    if [[ "${KAPSIS_DO_PUSH:-false}" == "true" ]]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ PUSHING TO REMOTE                                              │"
        echo "└────────────────────────────────────────────────────────────────┘"

        local remote="${KAPSIS_GIT_REMOTE:-origin}"

        # Capture local commit before push for verification
        local local_commit
        local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")

        # Use refspec to push local branch to (potentially different) remote branch
        git push --set-upstream "$remote" "${KAPSIS_BRANCH}:${remote_branch}" || {
            log_warn "Push failed. Changes are committed locally."
            if type status_set_push_info &>/dev/null; then
                status_set_push_info "failed" "$local_commit" ""
            fi
            return
        }

        # Verify push succeeded by comparing local and remote HEAD
        echo ""
        log_info "Verifying push to ${remote}/${remote_branch}..."

        # Fetch latest from remote to ensure we have current state
        git fetch "$remote" "$remote_branch" --quiet 2>/dev/null || true

        # Get remote HEAD commit after fetch
        local remote_commit
        remote_commit=$(git rev-parse "${remote}/${remote_branch}" 2>/dev/null || echo "")

        # Compare commits
        if [[ "$local_commit" == "$remote_commit" ]]; then
            log_success "Push verified: local and remote HEAD match"
            log_info "  Commit: ${local_commit:0:12}"
            if type status_set_push_info &>/dev/null; then
                status_set_push_info "success" "$local_commit" "$remote_commit"
            fi
        elif [[ -z "$remote_commit" ]]; then
            log_warn "Could not verify push - fetch may have failed"
            log_info "  Local commit: ${local_commit:0:12}"
            if type status_set_push_info &>/dev/null; then
                status_set_push_info "unverified" "$local_commit" ""
            fi
        else
            log_error "Push verification FAILED: commits do not match!"
            log_error "  Local:  $local_commit"
            log_error "  Remote: $remote_commit"
            if type status_set_push_info &>/dev/null; then
                status_set_push_info "failed" "$local_commit" "$remote_commit"
            fi
            log_error "Commits may not have been pushed to remote."
            return
        fi

        # Generate PR URL using git-remote-utils library
        local remote_url pr_url pr_term
        remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")

        echo ""
        if [[ -n "$remote_url" ]]; then
            pr_url=$(generate_pr_url "$remote_url" "$remote_branch")
            pr_term=$(get_pr_term "$remote_url")
            if [[ -n "$pr_url" ]]; then
                log_success "Create/View ${pr_term}: ${pr_url}"
            fi
        fi

        echo ""
        log_success "Changes pushed and verified successfully"
        echo ""
        echo "To continue after PR review, re-run with same branch:"
        echo "  ./launch-agent.sh <id> <project> --branch ${KAPSIS_BRANCH} --spec ./updated-spec.md"
    else
        echo ""
        log_success "Changes committed locally (use --push to enable auto-push)"
        echo "To push later: git push ${KAPSIS_GIT_REMOTE:-origin} ${KAPSIS_BRANCH}:${remote_branch}"
        # Record that push was skipped with the local commit
        local local_commit
        local_commit=$(git rev-parse HEAD 2>/dev/null || echo "")
        if type status_push_skipped &>/dev/null; then
            status_push_skipped "$local_commit"
        fi
    fi
}

#===============================================================================
# STATUS TRACKING SETUP
#
# Sets up agent-specific status tracking mechanisms:
# - For Claude Code, Codex CLI, Gemini CLI: Install hooks
# - For Aider and others: Start background progress monitor
#===============================================================================

# Load agent types library if available
AGENT_TYPES_LIB="$KAPSIS_HOME/lib/agent-types.sh"
if [[ -f "$AGENT_TYPES_LIB" ]]; then
    # shellcheck source=lib/agent-types.sh
    source "$AGENT_TYPES_LIB"
fi

setup_status_tracking() {
    local agent_type="${KAPSIS_AGENT_TYPE:-unknown}"

    # Normalize agent type if library available
    if type normalize_agent_type &>/dev/null; then
        agent_type=$(normalize_agent_type "$agent_type")
    fi

    log_info "Setting up status tracking for agent: $agent_type"

    # Agent hook lookup: maps normalized agent type to display name
    # Format: <agent-type>|<display-name> for agents with hook support
    local hook_agents="claude-cli|Claude Code
codex-cli|Codex CLI
gemini-cli|Gemini CLI"

    # Python agents that use status.py directly (no hooks needed)
    local python_agents="python claude-api"

    # Check if this agent supports hooks
    local hook_entry display_name
    hook_entry=$(echo "$hook_agents" | grep "^${agent_type}|" || true)

    if [[ -n "$hook_entry" ]]; then
        # Agent supports hooks - install them
        display_name="${hook_entry#*|}"
        install_agent_hooks "$agent_type" "$display_name"
    elif [[ " $python_agents " == *" $agent_type "* ]]; then
        # Python agent - status.py library available
        log_info "Python agent - status.py library available for direct integration"
    else
        # Fallback to progress monitor for unsupported agents
        log_info "Using progress monitor fallback for agent: $agent_type"
        start_progress_monitor
        inject_progress_instructions
    fi
}

#===============================================================================
# AGENT HOOK INSTALLATION
#
# Installs Kapsis status tracking hooks for supported agents.
# Uses inject-status-hooks.sh which handles:
#   - Claude Code: JSON merge into ~/.claude/settings.local.json
#   - Codex CLI: YAML merge into ~/.codex/config.yaml
#   - Gemini CLI: Shell scripts in ~/.gemini/hooks/
#
# All injection is merge-based to preserve user's existing configuration.
# Runs inside container with CoW, so host config is never modified.
#===============================================================================

# Common hook installation function
# Usage: install_agent_hooks <agent-type> <display-name>
install_agent_hooks() {
    local agent_type="$1"
    local display_name="${2:-$agent_type}"

    log_info "Installing ${display_name} status hooks..."

    local inject_script="$KAPSIS_HOME/lib/inject-status-hooks.sh"

    if [[ -x "$inject_script" ]]; then
        if "$inject_script" "$agent_type"; then
            return 0
        else
            log_warn "${display_name} hook injection failed"
            return 1
        fi
    else
        log_warn "Hook injection script not found: $inject_script"
        return 1
    fi
}

# Note: Agent-specific wrapper functions (setup_claude_hooks, etc.) have been
# removed in favor of the data-driven lookup in setup_status_tracking().
# Add new agents by updating the hook_agents variable there.

# Start background progress monitor for agents without hook support
start_progress_monitor() {
    local monitor_script="$KAPSIS_HOME/lib/progress-monitor.sh"

    if [[ ! -x "$monitor_script" ]]; then
        log_warn "Progress monitor script not found: $monitor_script"
        return 0
    fi

    log_info "Starting background progress monitor..."

    # Start monitor in background
    "$monitor_script" &
    PROGRESS_MONITOR_PID=$!

    # Register cleanup trap (single quotes to defer expansion until trap execution)
    trap 'kill $PROGRESS_MONITOR_PID 2>/dev/null || true' EXIT

    log_debug "Progress monitor started (PID: $PROGRESS_MONITOR_PID)"
}

# Inject progress reporting instructions into task spec
inject_progress_instructions() {
    local task_spec="/task-spec.md"
    local instructions="$KAPSIS_HOME/lib/progress-instructions.md"

    if [[ ! -f "$task_spec" ]]; then
        log_debug "No task spec to inject into"
        return 0
    fi

    if [[ ! -f "$instructions" ]]; then
        log_debug "Progress instructions template not found"
        return 0
    fi

    log_info "Injecting progress reporting instructions..."

    # Create workspace directory for progress file
    # Must succeed for injection to work
    if ! mkdir -p "/workspace/.kapsis" 2>/dev/null; then
        log_warn "Could not create /workspace/.kapsis - skipping progress injection"
        return 0
    fi

    # Append instructions to task spec (copy to writable location first)
    local injected_spec="/workspace/.kapsis/task-spec-with-progress.md"
    {
        cat "$task_spec"
        echo ""
        echo ""
        cat "$instructions"
    } > "$injected_spec"

    # Export path to injected spec
    export KAPSIS_INJECTED_TASK_SPEC="$injected_spec"

    log_debug "Injected task spec: $injected_spec"
}

#===============================================================================
# DNS FILTERING SETUP
#
# When KAPSIS_NETWORK_MODE=filtered, starts dnsmasq with the allowlist
# passed via KAPSIS_DNS_ALLOWLIST environment variable.
#===============================================================================
setup_dns_filtering() {
    local network_mode="${KAPSIS_NETWORK_MODE:-$KAPSIS_DEFAULT_NETWORK_MODE}"

    if [[ "$network_mode" != "filtered" ]]; then
        log_debug "DNS filtering not enabled (network mode: $network_mode)"
        return 0
    fi

    log_info "Setting up DNS-based network filtering..."

    # Source the DNS filter library
    local dns_filter_lib="$KAPSIS_HOME/lib/dns-filter.sh"
    if [[ ! -f "$dns_filter_lib" ]]; then
        log_error "DNS filter library not found: $dns_filter_lib"
        log_error "Falling back to network=none for security"
        # Instead of leaving network open, we should warn but can't change network mode at runtime
        # The filtering won't work, but network is still open (configured at container start)
        return 1
    fi

    # shellcheck source=lib/dns-filter.sh
    source "$dns_filter_lib"

    # Initialize and start DNS filtering
    # The allowlist is passed via KAPSIS_DNS_ALLOWLIST environment variable
    if dns_filter_init; then
        log_success "DNS filtering active"

        # Register cleanup trap
        trap 'dns_filter_cleanup' EXIT

        # Show what's allowed
        if [[ -n "${KAPSIS_DNS_ALLOWLIST:-}" ]]; then
            local domain_count
            domain_count=$(echo "$KAPSIS_DNS_ALLOWLIST" | tr ',' '\n' | wc -l | tr -d ' ')
            log_info "Allowed domains: $domain_count"
            log_debug "Domains: ${KAPSIS_DNS_ALLOWLIST:0:100}..."
        else
            log_warn "No domains in allowlist - all DNS queries will be blocked!"
        fi

        return 0
    else
        log_error "Failed to initialize DNS filtering"
        return 1
    fi
}

#===============================================================================
# DNS FILTERING WITH FAIL-SAFE
# Abort container if DNS filtering is required but fails to initialize
#
# Security model:
# - If KAPSIS_NETWORK_MODE is explicitly set → enforce that mode
# - If using default (filtered) and can't filter → abort (fail-safe)
# - Exception: CI environments (CI=true) auto-fallback to open
#===============================================================================

# Check if DNS filtering can run in this environment
# Returns: 0 if environment supports DNS filtering, 1 otherwise
can_run_dns_filtering() {
    # Check if dnsmasq is available
    if ! command -v dnsmasq &>/dev/null; then
        log_debug "dnsmasq not installed - DNS filtering unavailable"
        return 1
    fi

    # If host already pre-mounted resolv.conf (e.g., launch-agent with DNS pinning),
    # DNS is pre-configured and we don't need write access to resolv.conf
    if [[ "${KAPSIS_RESOLV_CONF_MOUNTED:-false}" == "true" ]]; then
        log_debug "Host pre-mounted resolv.conf - DNS filtering pre-configured"
        return 0
    fi

    # Check if we can write to resolv.conf
    if [[ ! -w /etc/resolv.conf ]] && [[ ! -w /etc ]]; then
        log_debug "Cannot modify /etc/resolv.conf - DNS filtering unavailable"
        return 1
    fi

    return 0
}

init_dns_filtering_or_fail() {
    local network_mode="${KAPSIS_NETWORK_MODE:-$KAPSIS_DEFAULT_NETWORK_MODE}"
    local explicitly_set="${KAPSIS_NETWORK_MODE:-}"

    # Only enforce fail-safe for filtered mode
    if [[ "$network_mode" != "filtered" ]]; then
        log_debug "DNS fail-safe not required (network mode: $network_mode)"
        return 0
    fi

    # Check if environment supports DNS filtering before attempting
    if ! can_run_dns_filtering; then
        # CI environments auto-fallback to open (avoid breaking CI pipelines)
        if [[ "${CI:-}" == "true" ]] && [[ -z "$explicitly_set" ]]; then
            log_warn "CI environment detected - DNS filtering unavailable"
            log_warn "Falling back to unrestricted network access"
            export KAPSIS_NETWORK_MODE="open"
            return 0
        fi

        # Non-CI or explicit mode: fail-safe
        log_error "=========================================="
        log_error "SECURITY: DNS filtering not supported in this environment"
        log_error "=========================================="
        log_error "Filtered network mode requires working DNS filtering, but:"
        log_error "  - dnsmasq may not be installed"
        log_error "  - resolv.conf may not be writable"
        log_error "  - Container may lack required capabilities"
        log_error ""
        log_error "Options:"
        log_error "  --network-mode=none   (complete network isolation)"
        log_error "  --network-mode=open   (unrestricted access)"
        log_error "=========================================="
        exit 1
    fi

    # Environment supports filtering, attempt to set it up
    if ! setup_dns_filtering; then
        # CI environments auto-fallback to open
        if [[ "${CI:-}" == "true" ]] && [[ -z "$explicitly_set" ]]; then
            log_warn "CI environment detected - DNS filtering failed"
            log_warn "Falling back to unrestricted network access"
            export KAPSIS_NETWORK_MODE="open"
            return 0
        fi

        log_error "=========================================="
        log_error "SECURITY: DNS filtering failed to initialize"
        log_error "=========================================="
        log_error "Filtered network mode requires working DNS filtering."
        log_error "Aborting to prevent unfiltered network access."
        log_error ""
        log_error "Options:"
        log_error "  --network-mode=none   (complete network isolation)"
        log_error "  --network-mode=open   (unrestricted access)"
        log_error "  Fix the DNS configuration and retry"
        log_error "=========================================="
        exit 1
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

    # Show network mode
    local network_mode="${KAPSIS_NETWORK_MODE:-$KAPSIS_DEFAULT_NETWORK_MODE}"
    case "$network_mode" in
        none)     echo "Network:     isolated (no access)" ;;
        filtered) echo "Network:     filtered (DNS allowlist)" ;;
        open)     echo "Network:     unrestricted" ;;
    esac

    echo ""
    echo "Maven settings: $KAPSIS_HOME/maven/settings.xml (isolation enabled)"
    if [[ "${KAPSIS_WORKTREE_MODE:-}" == "true" ]]; then
        local push_status="disabled"
        [[ "${KAPSIS_DO_PUSH:-}" == "true" ]] && push_status="ENABLED"
        echo "Git:         using sanitized .git-safe (hooks isolated, push ${push_status})"
    fi
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

    # Whitelist Claude agent config (hooks and MCP servers) based on YAML config
    # Must happen after CoW (files writable) and before hook injection (settings.local.json)
    local filter_lib="${KAPSIS_HOME:-/opt/kapsis}/lib/filter-agent-config.sh"
    if [[ -f "$filter_lib" ]]; then
        source "$filter_lib"
        filter_claude_agent_config
    fi

    # Inject credentials to files (agent-agnostic)
    # Reads KAPSIS_CREDENTIAL_FILES env var set by launch-agent.sh
    inject_credential_files

    # Set up DNS filtering if in filtered network mode
    # Must happen early so all subsequent network operations go through the filter
    init_dns_filtering_or_fail

    # Protect DNS configuration files from agent modification
    # Must happen after DNS filtering is set up, but before agent starts
    if [[ "${KAPSIS_DNS_PIN_PROTECT_FILES:-false}" == "true" ]]; then
        # Source dns-filter.sh if not already sourced (for protect_dns_files function)
        if ! type protect_dns_files &>/dev/null; then
            source "$KAPSIS_HOME/lib/dns-filter.sh"
        fi
        protect_dns_files
    fi

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

        # Set up agent-specific status tracking (hooks or fallback monitor)
        setup_status_tracking
    fi

    # Start DNS watchdog (restarts dnsmasq if killed by agent)
    # Must happen after DNS setup and protection, before exec into agent
    if [[ "${KAPSIS_NETWORK_MODE:-}" == "filtered" ]]; then
        if type start_dns_watchdog &>/dev/null; then
            start_dns_watchdog
        fi
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
