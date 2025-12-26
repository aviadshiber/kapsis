#!/usr/bin/env bash
#===============================================================================
# Kapsis - Launch Agent Script
#
# Launches an AI coding agent in a hermetically isolated Podman container
# with Copy-on-Write filesystem, isolated Maven repository, and optional
# git branch workflow.
#
# Usage:
#   ./launch-agent.sh <agent-id> <project-path> [options]
#
# Options:
#   --agent <name>        Agent shortcut: claude, codex, aider, interactive
#   --config <file>       Config file (overrides --agent)
#   --task <description>  Inline task description
#   --spec <file>         Task specification file (markdown)
#   --branch <name>       Git branch to work on (creates or continues)
#   --auto-branch         Auto-generate branch name
#   --no-push             Commit but don't push
#   --interactive         Force interactive shell mode
#   --dry-run             Show what would be executed without running
#   --worktree-mode       Force worktree mode (git worktrees, simpler cleanup)
#   --overlay-mode        Force overlay mode (fuse-overlayfs, legacy)
#
# Examples:
#   ./launch-agent.sh 1 ~/project --agent claude --task "fix failing tests"
#   ./launch-agent.sh 1 ~/project --agent codex --spec ./specs/feature.md
#   ./launch-agent.sh 1 ~/project --agent aider --branch feature/DEV-123 --spec ./task.md
#===============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"
log_init "launch-agent"

# Source status reporting library
source "$SCRIPT_DIR/lib/status.sh"

# Bash 3.2 compatible uppercase conversion
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

#===============================================================================
# DEFAULT VALUES
#===============================================================================
AGENT_NAME=""
CONFIG_FILE=""
TASK_INLINE=""
SPEC_FILE=""
BRANCH=""
AUTO_BRANCH=false
NO_PUSH=false
INTERACTIVE=false
DRY_RUN=false
# Use KAPSIS_IMAGE env var if set (for CI), otherwise default
IMAGE_NAME="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"
SANDBOX_MODE=""  # auto-detect, worktree, or overlay
WORKTREE_PATH=""
SANITIZED_GIT_PATH=""

# Source shared constants
source "$SCRIPT_DIR/lib/constants.sh"

#===============================================================================
# COLORS AND OUTPUT (colors used for banner only)
#===============================================================================
CYAN='\033[0;36m'
NC='\033[0m' # No Color
# Note: logging functions are provided by lib/logging.sh

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                         KAPSIS SANDBOX                            ║"
    echo "║           Hermetically Isolated AI Agent Environment              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#===============================================================================
# SECRET STORE HELPERS (macOS Keychain, Linux secret-tool)
#===============================================================================

# Detect the current OS for secret store selection
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

# Query system secret store for a credential
# Usage: query_secret_store "service" ["account"]
# Returns: credential on stdout, exit 1 if not found
# Supports: macOS Keychain, Linux secret-tool
query_secret_store() {
    local service="$1"
    local account="${2:-}"
    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            # macOS Keychain via security command
            if [[ -n "$account" ]]; then
                security find-generic-password -s "$service" -a "$account" -w 2>/dev/null
            else
                security find-generic-password -s "$service" -w 2>/dev/null
            fi
            ;;
        linux)
            # Linux secret-tool (GNOME Keyring / KDE Wallet)
            if ! command -v secret-tool &>/dev/null; then
                log_warn "secret-tool not found - install libsecret-tools"
                return 1
            fi
            if [[ -n "$account" ]]; then
                secret-tool lookup service "$service" account "$account" 2>/dev/null
            else
                secret-tool lookup service "$service" 2>/dev/null
            fi
            ;;
        *)
            log_warn "Unsupported OS for secret store: $os"
            return 1
            ;;
    esac
}

#===============================================================================
# USAGE
#===============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") <agent-id> <project-path> [options]

Launch an AI coding agent in an isolated Podman container.

Arguments:
  agent-id        Unique identifier for this agent instance (e.g., 1, 2, agent-a)
  project-path    Path to the project directory to work on

Options:
  --agent <name>        Agent to use: claude, codex, aider, interactive
                        (shortcut for --config configs/<name>.yaml)
  --config <file>       Config file (overrides --agent)
  --task <description>  Inline task description (for simple tasks)
  --spec <file>         Task specification file (for complex tasks)
  --branch <name>       Git branch to work on (creates new or continues existing)
  --auto-branch         Auto-generate branch name from task/spec
  --no-push             Create branch and commit, but don't push
  --interactive         Force interactive shell mode (ignores agent.command)
  --dry-run             Show what would be executed without running
  --image <name>        Container image to use (e.g., kapsis-claude-cli:latest)
  --worktree-mode       Force worktree mode (requires git repo + branch)
  --overlay-mode        Force overlay mode (fuse-overlayfs, legacy)
  -h, --help            Show this help message

Available Agents:
  claude                Claude Code (requires ANTHROPIC_API_KEY)
  codex                 OpenAI Codex CLI (requires OPENAI_API_KEY)
  aider                 Aider (requires OPENAI_API_KEY or ANTHROPIC_API_KEY)
  interactive           Interactive bash shell (no AI)

Task Input (one required unless --interactive):
  --task "description"  Inline task for simple requests
  --spec ./spec.md      File with detailed specification

Examples:
  # Simple task
  $(basename "$0") 1 ~/project --task "fix failing tests in UserService"

  # Complex task with spec file
  $(basename "$0") 1 ~/project --spec ./specs/user-preferences.md

  # With git branch workflow (creates or continues)
  $(basename "$0") 1 ~/project --branch feature/DEV-123 --spec ./task.md

  # Multiple agents in parallel
  $(basename "$0") 1 ~/project --branch feature/DEV-123-api --spec ./api.md &
  $(basename "$0") 2 ~/project --branch feature/DEV-123-ui --spec ./ui.md &
  wait

  # Interactive exploration
  $(basename "$0") 1 ~/project --interactive --branch experiment/explore

EOF
    exit 1
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================
parse_args() {
    if [[ $# -lt 2 ]]; then
        usage
    fi

    AGENT_ID="$1"
    PROJECT_PATH="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent)
                AGENT_NAME="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --task)
                TASK_INLINE="$2"
                shift 2
                ;;
            --spec)
                SPEC_FILE="$2"
                shift 2
                ;;
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            --auto-branch)
                AUTO_BRANCH=true
                shift
                ;;
            --no-push)
                NO_PUSH=true
                shift
                ;;
            --interactive)
                INTERACTIVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            --worktree-mode)
                SANDBOX_MODE="worktree"
                shift
                ;;
            --overlay-mode)
                SANDBOX_MODE="overlay"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

#===============================================================================
# VALIDATION
#===============================================================================
validate_inputs() {
    log_debug "Validating inputs..."
    log_debug "  AGENT_ID=$AGENT_ID"
    log_debug "  PROJECT_PATH=$PROJECT_PATH"
    log_debug "  AGENT_NAME=$AGENT_NAME"
    log_debug "  BRANCH=$BRANCH"

    # Validate project path
    PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || {
        log_error "Project path does not exist: $PROJECT_PATH"
        exit 1
    }
    log_debug "Resolved PROJECT_PATH=$PROJECT_PATH"

    # Validate task input
    if [[ -z "$TASK_INLINE" && -z "$SPEC_FILE" && "$INTERACTIVE" != "true" ]]; then
        log_error "Task input required: use --task, --spec, or --interactive"
        usage
    fi

    # Validate spec file exists
    if [[ -n "$SPEC_FILE" && ! -f "$SPEC_FILE" ]]; then
        log_error "Spec file not found: $SPEC_FILE"
        exit 1
    fi

    # Validate git branch requirements
    if [[ -n "$BRANCH" || "$AUTO_BRANCH" == "true" ]]; then
        if [[ ! -d "$PROJECT_PATH/.git" ]]; then
            log_error "Git branch workflow requires project to be a git repository"
            exit 1
        fi
    fi

    # Check Podman is available (skip in dry-run mode)
    if [[ "$DRY_RUN" != "true" ]]; then
        log_debug "Checking Podman availability..."
        if ! command -v podman &> /dev/null; then
            log_error "Podman is not installed or not in PATH"
            exit 1
        fi
        log_debug "Podman found at: $(command -v podman)"

        # Check Podman machine is running (macOS only)
        if [[ "$(uname)" == "Darwin" ]]; then
            log_debug "Checking Podman machine status..."
            if ! podman machine inspect podman-machine-default &>/dev/null || \
               [[ "$(podman machine inspect podman-machine-default --format '{{.State}}')" != "running" ]]; then
                log_warn "Podman machine is not running. Attempting to start..."
                podman machine start podman-machine-default || {
                    log_error "Failed to start Podman machine. Please run: podman machine start"
                    exit 1
                }
                log_success "Podman machine started"
            else
                log_debug "Podman machine is running"
            fi
        fi
    else
        log_debug "Skipping Podman checks (dry-run mode)"
    fi
    log_debug "Input validation completed successfully"
}

#===============================================================================
# CONFIG RESOLUTION
#===============================================================================
resolve_config() {
    log_debug "Resolving configuration..."

    # --config takes precedence
    if [[ -n "$CONFIG_FILE" ]]; then
        log_debug "Using explicit config file: $CONFIG_FILE"
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        # Extract agent name from config filename
        if [[ -z "$AGENT_NAME" ]]; then
            AGENT_NAME=$(basename "$CONFIG_FILE" .yaml)
            log_debug "Extracted agent name from config: $AGENT_NAME"
        fi
        return
    fi

    # --agent shortcut: look for configs/<agent>.yaml
    if [[ -n "$AGENT_NAME" ]]; then
        local agent_config="$KAPSIS_ROOT/configs/${AGENT_NAME}.yaml"
        if [[ -f "$agent_config" ]]; then
            CONFIG_FILE="$agent_config"
            log_info "Using agent: ${AGENT_NAME}"
            return
        else
            log_error "Unknown agent: $AGENT_NAME"
            log_error "Available agents: claude, codex, aider, interactive"
            log_error "Or use --config for custom config file"
            exit 1
        fi
    fi

    # Resolution order (when no --agent or --config specified)
    local config_locations=(
        "./agent-sandbox.yaml"
        "./.kapsis/config.yaml"
        "$PROJECT_PATH/agent-sandbox.yaml"
        "$PROJECT_PATH/.kapsis/config.yaml"
        "$HOME/.config/kapsis/default.yaml"
        "$KAPSIS_ROOT/configs/claude.yaml"
    )

    for loc in "${config_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            CONFIG_FILE="$loc"
            # Extract agent name from config path
            if [[ -z "$AGENT_NAME" ]]; then
                AGENT_NAME=$(basename "$CONFIG_FILE" .yaml)
            fi
            log_info "Using agent: ${AGENT_NAME} (${CONFIG_FILE})"
            return
        fi
    done

    log_error "No config file found."
    log_error "Use --agent <name> or --config <file>"
    log_error "Available agents: claude, codex, aider, interactive"
    exit 1
}

#===============================================================================
# CONFIG PARSING (Simple YAML parsing with yq or fallback)
#===============================================================================
parse_config() {
    log_debug "Parsing config file: $CONFIG_FILE"

    # Check if yq is available
    if command -v yq &> /dev/null; then
        log_debug "Using yq for config parsing"
        AGENT_COMMAND=$(yq -r '.agent.command // "bash"' "$CONFIG_FILE")
        export AGENT_WORKDIR
        AGENT_WORKDIR=$(yq -r '.agent.workdir // "/workspace"' "$CONFIG_FILE")
        RESOURCE_MEMORY=$(yq -r '.resources.memory // "8g"' "$CONFIG_FILE")
        RESOURCE_CPUS=$(yq -r '.resources.cpus // "4"' "$CONFIG_FILE")
        SANDBOX_UPPER_BASE=$(yq -r '.sandbox.upper_dir_base // "~/.ai-sandboxes"' "$CONFIG_FILE")
        # Only override image if not set via --image flag
        if [[ "$IMAGE_NAME" == "kapsis-sandbox:latest" ]]; then
            IMAGE_NAME=$(yq -r '.image.name // "kapsis-sandbox"' "$CONFIG_FILE"):$(yq -r '.image.tag // "latest"' "$CONFIG_FILE")
        fi
        GIT_REMOTE=$(yq -r '.git.auto_push.remote // "origin"' "$CONFIG_FILE")
        GIT_COMMIT_MSG=$(yq -r '.git.auto_push.commit_message // "feat: AI agent changes"' "$CONFIG_FILE")

        # Parse filesystem includes
        FILESYSTEM_INCLUDES=$(yq -r '.filesystem.include[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment passthrough
        ENV_PASSTHROUGH=$(yq -r '.environment.passthrough[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment set
        ENV_SET=$(yq -r '.environment.set // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")

        # Parse keychain mappings for secret store lookups
        # Output format: VAR_NAME|service|account|inject_to_file|mode per line
        # inject_to_file: optional file path to write the secret to (agent-agnostic)
        # mode: optional file permissions (default 0600)
        ENV_KEYCHAIN=$(yq '.environment.keychain // {} | to_entries | .[] | .key + "|" + .value.service + "|" + (.value.account // "") + "|" + (.value.inject_to_file // "") + "|" + (.value.mode // "0600")' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse SSH host verification list
        SSH_VERIFY_HOSTS=$(yq -r '.ssh.verify_hosts[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        log_warn "yq not found. Using default config values."
        AGENT_COMMAND="bash"
        export AGENT_WORKDIR="/workspace"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        SANDBOX_UPPER_BASE="$HOME/.ai-sandboxes"
        GIT_REMOTE="origin"
        GIT_COMMIT_MSG="feat: AI agent changes"
        FILESYSTEM_INCLUDES=""
        ENV_PASSTHROUGH="ANTHROPIC_API_KEY"
        ENV_SET="{}"
        ENV_KEYCHAIN=""
        SSH_VERIFY_HOSTS=""
    fi

    # Expand ~ in paths
    SANDBOX_UPPER_BASE="${SANDBOX_UPPER_BASE/#\~/$HOME}"

    log_debug "Config parsed successfully:"
    log_debug "  AGENT_COMMAND=$AGENT_COMMAND"
    log_debug "  RESOURCE_MEMORY=$RESOURCE_MEMORY"
    log_debug "  RESOURCE_CPUS=$RESOURCE_CPUS"
    log_debug "  IMAGE_NAME=$IMAGE_NAME"
}

#===============================================================================
# SANDBOX MODE DETECTION
#===============================================================================
detect_sandbox_mode() {
    # If mode explicitly set, use it
    if [[ -n "$SANDBOX_MODE" ]]; then
        log_info "Sandbox mode: $SANDBOX_MODE (explicit)"
        return
    fi

    # Auto-detect: use worktree if git repo + branch specified
    if [[ -n "$BRANCH" ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
        SANDBOX_MODE="worktree"
        log_info "Sandbox mode: worktree (auto-detected: git repo + branch)"
    else
        SANDBOX_MODE="overlay"
        log_info "Sandbox mode: overlay (auto-detected: no branch or not git repo)"
    fi
}

#===============================================================================
# SANDBOX SETUP (dispatches to mode-specific setup)
#===============================================================================
setup_sandbox() {
    detect_sandbox_mode

    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        setup_worktree_sandbox
    else
        setup_overlay_sandbox
    fi
}

#===============================================================================
# WORKTREE SANDBOX SETUP
#===============================================================================
setup_worktree_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    SANDBOX_ID="${project_name}-${AGENT_ID}"

    log_info "Setting up worktree sandbox: $SANDBOX_ID"

    # Source the worktree manager
    source "$SCRIPT_DIR/worktree-manager.sh"

    # Create worktree on host
    WORKTREE_PATH=$(create_worktree "$PROJECT_PATH" "$AGENT_ID" "$BRANCH")

    # Prepare sanitized git for container
    SANITIZED_GIT_PATH=$(prepare_sanitized_git "$WORKTREE_PATH" "$AGENT_ID" "$PROJECT_PATH")

    # Get objects path for read-only mount
    OBJECTS_PATH=$(get_objects_path "$PROJECT_PATH")

    log_info "  Worktree: $WORKTREE_PATH"
    log_info "  Sanitized git: $SANITIZED_GIT_PATH"
    log_info "  Objects: $OBJECTS_PATH (read-only)"
}

#===============================================================================
# OVERLAY SANDBOX SETUP (legacy)
#===============================================================================
setup_overlay_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    SANDBOX_ID="${project_name}-${AGENT_ID}"
    SANDBOX_DIR="${SANDBOX_UPPER_BASE}/${SANDBOX_ID}"
    UPPER_DIR="${SANDBOX_DIR}/upper"
    WORK_DIR="${SANDBOX_DIR}/work"

    log_info "Setting up overlay sandbox: $SANDBOX_ID"

    mkdir -p "$UPPER_DIR" "$WORK_DIR"

    log_info "  Upper directory: $UPPER_DIR"
    log_info "  Work directory: $WORK_DIR"
}

#===============================================================================
# VOLUME MOUNTS GENERATION (dispatches to mode-specific)
#===============================================================================
generate_volume_mounts() {
    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        generate_volume_mounts_worktree
    else
        generate_volume_mounts_overlay
    fi
}

#===============================================================================
# WORKTREE VOLUME MOUNTS
#===============================================================================
generate_volume_mounts_worktree() {
    VOLUME_MOUNTS=()

    # Mount worktree directly (no overlay needed!)
    VOLUME_MOUNTS+=("-v" "${WORKTREE_PATH}:/workspace")

    # Status reporting directory (shared between host and container)
    local status_dir="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"
    mkdir -p "$status_dir" 2>/dev/null || true
    VOLUME_MOUNTS+=("-v" "${status_dir}:/kapsis-status")

    # Mount sanitized git at $CONTAINER_GIT_PATH, replacing the worktree's .git file
    # This makes git work without needing GIT_DIR environment variable
    VOLUME_MOUNTS+=("-v" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro")

    # Mount objects directory read-only
    VOLUME_MOUNTS+=("-v" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro")

    # Maven repository (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-m2:/home/developer/.m2/repository")

    # Gradle cache (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-gradle:/home/developer/.gradle")

    # GE workspace (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-ge:/home/developer/.m2/.gradle-enterprise")

    # Spec file (if provided)
    if [[ -n "$SPEC_FILE" ]]; then
        SPEC_FILE_ABS="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
        VOLUME_MOUNTS+=("-v" "${SPEC_FILE_ABS}:/task-spec.md:ro")
    fi

    # Filesystem whitelist from config
    generate_filesystem_includes

    # SSH known_hosts for verified git remotes
    generate_ssh_known_hosts
    if [[ -n "$SSH_KNOWN_HOSTS_FILE" ]]; then
        VOLUME_MOUNTS+=("-v" "${SSH_KNOWN_HOSTS_FILE}:/etc/ssh/ssh_known_hosts:ro")
    fi
}

#===============================================================================
# OVERLAY VOLUME MOUNTS (legacy)
#===============================================================================
generate_volume_mounts_overlay() {
    VOLUME_MOUNTS=()

    # Project with CoW overlay
    VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")

    # Status reporting directory (shared between host and container)
    local status_dir="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"
    mkdir -p "$status_dir" 2>/dev/null || true
    VOLUME_MOUNTS+=("-v" "${status_dir}:/kapsis-status")

    # Maven repository (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-m2:/home/developer/.m2/repository")

    # Gradle cache (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-gradle:/home/developer/.gradle")

    # GE workspace (isolated per agent)
    VOLUME_MOUNTS+=("-v" "kapsis-${AGENT_ID}-ge:/home/developer/.m2/.gradle-enterprise")

    # Spec file (if provided)
    if [[ -n "$SPEC_FILE" ]]; then
        SPEC_FILE_ABS="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
        VOLUME_MOUNTS+=("-v" "${SPEC_FILE_ABS}:/task-spec.md:ro")
    fi

    # Filesystem whitelist from config
    generate_filesystem_includes

    # SSH known_hosts for verified git remotes
    generate_ssh_known_hosts
    if [[ -n "$SSH_KNOWN_HOSTS_FILE" ]]; then
        VOLUME_MOUNTS+=("-v" "${SSH_KNOWN_HOSTS_FILE}:/etc/ssh/ssh_known_hosts:ro")
    fi
}

#===============================================================================
# FILESYSTEM INCLUDES (common to both modes)
#===============================================================================
# Uses staging-and-copy pattern for home directory files:
# 1. Mount host files to /kapsis-staging/<name> (read-only)
# 2. Entrypoint copies to container $HOME (writable)
# This avoids overlay permission issues with restrictive host directories.
#===============================================================================
STAGED_CONFIGS=""  # Comma-separated list of relative paths staged for copying

generate_filesystem_includes() {
    local staging_dir="/kapsis-staging"
    STAGED_CONFIGS=""

    if [[ -n "$FILESYSTEM_INCLUDES" ]]; then
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            expanded_path="${path/#\~/$HOME}"

            if [[ ! -e "$expanded_path" ]]; then
                log_debug "Skipping non-existent path: ${expanded_path}"
                continue
            fi

            # Home directory paths: use staging-and-copy pattern
            if [[ "$path" == "~"* ]] || [[ "$expanded_path" == "$HOME"* ]]; then
                # Extract relative path (e.g., .claude, .gitconfig)
                relative_path="${expanded_path#$HOME/}"
                staging_path="${staging_dir}/${relative_path}"

                # Mount to staging directory (read-only)
                VOLUME_MOUNTS+=("-v" "${expanded_path}:${staging_path}:ro")
                log_debug "Staged for copy: ${expanded_path} -> ${staging_path}"

                # Track for entrypoint to copy
                if [[ -n "$STAGED_CONFIGS" ]]; then
                    STAGED_CONFIGS="${STAGED_CONFIGS},${relative_path}"
                else
                    STAGED_CONFIGS="${relative_path}"
                fi
            else
                # Non-home absolute paths: mount directly (read-only)
                VOLUME_MOUNTS+=("-v" "${expanded_path}:${expanded_path}:ro")
                log_debug "Direct mount (ro): ${expanded_path}"
            fi
        done <<< "$FILESYSTEM_INCLUDES"
    fi

    # Export staged configs for entrypoint
    if [[ -n "$STAGED_CONFIGS" ]]; then
        log_debug "Staged configs for copy: ${STAGED_CONFIGS}"
    fi
}

#===============================================================================
# SSH KNOWN_HOSTS GENERATION
# Generates verified known_hosts for container SSH operations (git push, etc.)
#===============================================================================
SSH_KNOWN_HOSTS_FILE=""  # Path to generated known_hosts file

generate_ssh_known_hosts() {
    SSH_KNOWN_HOSTS_FILE=""

    # Skip if no hosts to verify
    if [[ -z "$SSH_VERIFY_HOSTS" ]]; then
        log_debug "No SSH hosts to verify (ssh.verify_hosts not configured)"
        return 0
    fi

    local ssh_keychain_script="$SCRIPT_DIR/lib/ssh-keychain.sh"
    if [[ ! -x "$ssh_keychain_script" ]]; then
        log_warn "SSH keychain script not found: $ssh_keychain_script"
        log_warn "SSH host verification skipped - container will use host's known_hosts"
        return 0
    fi

    # Create temp file for known_hosts
    local known_hosts_file
    known_hosts_file=$(mktemp -t kapsis-known-hosts.XXXXXX)

    log_info "Generating verified SSH known_hosts..."

    # Process each host
    local failed_hosts=()
    while IFS= read -r host; do
        [[ -z "$host" ]] && continue

        log_debug "Verifying SSH host key: $host"
        if "$ssh_keychain_script" generate "$known_hosts_file" "$host" 2>/dev/null; then
            log_debug "  ✓ $host verified"
        else
            log_warn "  ✗ $host verification failed (run: ssh-keychain.sh add-host $host)"
            failed_hosts+=("$host")
        fi
    done <<< "$SSH_VERIFY_HOSTS"

    # Check if any hosts were verified
    if [[ -s "$known_hosts_file" ]]; then
        SSH_KNOWN_HOSTS_FILE="$known_hosts_file"
        local host_count
        host_count=$(wc -l < "$known_hosts_file" | tr -d ' ')
        log_success "SSH known_hosts ready ($host_count keys verified)"
    else
        rm -f "$known_hosts_file"
        log_warn "No SSH hosts could be verified"
    fi

    # Report failed hosts
    if [[ ${#failed_hosts[@]} -gt 0 ]]; then
        log_warn "Failed hosts (git push may fail):"
        for host in "${failed_hosts[@]}"; do
            log_warn "  - $host (run: ./scripts/lib/ssh-keychain.sh add-host $host)"
        done
    fi
}

#===============================================================================
# ENVIRONMENT VARIABLES GENERATION
#===============================================================================
generate_env_vars() {
    ENV_VARS=()

    # Pass through environment variables
    if [[ -n "$ENV_PASSTHROUGH" ]]; then
        while IFS= read -r var; do
            [[ -z "$var" ]] && continue
            if [[ -n "${!var:-}" ]]; then
                ENV_VARS+=("-e" "${var}=${!var}")
            fi
        done <<< "$ENV_PASSTHROUGH"
    fi

    # Process keychain-backed environment variables
    # Track credentials that need file injection (agent-agnostic)
    local CREDENTIAL_FILES=""

    if [[ -n "$ENV_KEYCHAIN" ]]; then
        log_info "Resolving secrets from system keychain..."
        while IFS='|' read -r var_name service account inject_to_file file_mode; do
            [[ -z "$var_name" || -z "$service" ]] && continue

            # Expand variables in account (e.g., ${USER})
            # Security: Use parameter expansion instead of eval to prevent injection
            if [[ -n "$account" ]]; then
                # Safe variable substitution without eval
                account="${account//\$\{USER\}/${USER}}"
                account="${account//\$USER/${USER}}"
                account="${account//\$\{HOME\}/${HOME}}"
                account="${account//\$HOME/${HOME}}"
                account="${account//\$\{LOGNAME\}/${LOGNAME:-$USER}}"
                account="${account//\$LOGNAME/${LOGNAME:-$USER}}"
            fi

            # Skip if already set via passthrough
            local already_set=false
            if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
                for existing in "${ENV_VARS[@]}"; do
                    if [[ "$existing" == "${var_name}="* ]]; then
                        already_set=true
                        break
                    fi
                done
            fi

            if [[ "$already_set" == "true" ]]; then
                log_debug "Skipping $var_name - already set via passthrough"
                continue
            fi

            # Query secret store (keychain/secret-tool)
            local value
            if value=$(query_secret_store "$service" "$account"); then
                ENV_VARS+=("-e" "${var_name}=${value}")
                log_success "Loaded $var_name from secret store (service: $service)"

                # Track file injection if specified (agent-agnostic credential injection)
                if [[ -n "$inject_to_file" ]]; then
                    # Format: VAR_NAME|file_path|mode (comma-separated list)
                    if [[ -n "$CREDENTIAL_FILES" ]]; then
                        CREDENTIAL_FILES="${CREDENTIAL_FILES},${var_name}|${inject_to_file}|${file_mode:-0600}"
                    else
                        CREDENTIAL_FILES="${var_name}|${inject_to_file}|${file_mode:-0600}"
                    fi
                    log_debug "Will inject $var_name to file: $inject_to_file"
                fi
            else
                log_warn "Secret not found: $service (for $var_name)"
            fi
        done <<< "$ENV_KEYCHAIN"
    fi

    # Pass credential file injection metadata to entrypoint (agent-agnostic)
    if [[ -n "$CREDENTIAL_FILES" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CREDENTIAL_FILES=${CREDENTIAL_FILES}")
    fi

    # Set explicit environment variables
    ENV_VARS+=("-e" "KAPSIS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_SANDBOX_MODE=${SANDBOX_MODE}")

    # Status reporting environment variables (for container to update status)
    ENV_VARS+=("-e" "KAPSIS_STATUS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_STATUS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_STATUS_BRANCH=${BRANCH:-}")

    # Mode-specific variables
    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        ENV_VARS+=("-e" "KAPSIS_WORKTREE_MODE=true")
    else
        ENV_VARS+=("-e" "KAPSIS_SANDBOX_DIR=${SANDBOX_DIR}")
    fi

    if [[ -n "$BRANCH" ]]; then
        ENV_VARS+=("-e" "KAPSIS_BRANCH=${BRANCH}")
        ENV_VARS+=("-e" "KAPSIS_GIT_REMOTE=${GIT_REMOTE}")
        ENV_VARS+=("-e" "KAPSIS_NO_PUSH=${NO_PUSH}")
    fi

    if [[ -n "$TASK_INLINE" ]]; then
        ENV_VARS+=("-e" "KAPSIS_TASK=${TASK_INLINE}")
    fi

    # Pass staged configs for entrypoint to copy to $HOME
    if [[ -n "$STAGED_CONFIGS" ]]; then
        ENV_VARS+=("-e" "KAPSIS_STAGED_CONFIGS=${STAGED_CONFIGS}")
    fi

    # Process explicit set environment variables from config
    if [[ -n "$ENV_SET" ]] && [[ "$ENV_SET" != "{}" ]]; then
        log_debug "Processing environment.set variables..."
        # Parse set variables as key=value pairs (yq props format: "KEY = value")
        local set_vars
        set_vars=$(yq -o=props '.environment.set' "$CONFIG_FILE" 2>/dev/null | grep -v '^#' || echo "")
        if [[ -n "$set_vars" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                # Parse "KEY = value" format
                # Security: Use sed for whitespace trimming instead of xargs (safer with special chars)
                local key value
                key=$(echo "$line" | cut -d'=' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                if [[ -n "$key" ]]; then
                    ENV_VARS+=("-e" "${key}=${value}")
                fi
            done <<< "$set_vars"
        fi
    fi
}

#===============================================================================
# AUTO BRANCH NAME GENERATION
#===============================================================================
generate_branch_name() {
    if [[ "$AUTO_BRANCH" != "true" ]]; then
        return
    fi

    local prefix="ai-agent"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local task_slug=""

    if [[ -n "$SPEC_FILE" ]]; then
        task_slug=$(basename "$SPEC_FILE" .md | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | head -c 30)
    elif [[ -n "$TASK_INLINE" ]]; then
        task_slug=$(echo "$TASK_INLINE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 30)
    fi

    BRANCH="${prefix}/${task_slug:-task}-${timestamp}"
    log_info "Auto-generated branch: $BRANCH"
}

#===============================================================================
# BUILD CONTAINER COMMAND
#===============================================================================
build_container_command() {
    CONTAINER_CMD=(
        "podman" "run"
        "--rm"
        "-it"
        "--name" "kapsis-${AGENT_ID}"
        "--hostname" "kapsis-${AGENT_ID}"
        "--userns=keep-id"
        "--memory=${RESOURCE_MEMORY}"
        "--cpus=${RESOURCE_CPUS}"
        "--security-opt" "label=disable"
    )

    # Add volume mounts
    CONTAINER_CMD+=("${VOLUME_MOUNTS[@]}")

    # Add inline task spec mount if needed (must be before image name)
    if [[ -n "$TASK_INLINE" ]] && [[ "$INTERACTIVE" != "true" ]]; then
        INLINE_SPEC_FILE=$(mktemp)
        echo "$TASK_INLINE" > "$INLINE_SPEC_FILE"
        CONTAINER_CMD+=("-v" "${INLINE_SPEC_FILE}:/task-spec.md:ro")
    fi

    # Add environment variables
    CONTAINER_CMD+=("${ENV_VARS[@]}")

    # Add image
    CONTAINER_CMD+=("$IMAGE_NAME")

    # Add agent command
    if [[ "$INTERACTIVE" == "true" ]]; then
        CONTAINER_CMD+=("bash")
    elif [[ -n "$AGENT_COMMAND" ]] && [[ "$AGENT_COMMAND" != "bash" ]]; then
        # Pass agent command to container (use bash -c for complex commands)
        CONTAINER_CMD+=("bash" "-c" "$AGENT_COMMAND")
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================
main() {
    log_timer_start "total"
    log_section "Starting Kapsis Agent Launch"

    print_banner

    log_debug "Parsing command line arguments..."
    parse_args "$@"

    log_timer_start "validation"
    validate_inputs
    log_timer_end "validation"

    # Initialize status reporting (after we have PROJECT_PATH and AGENT_ID)
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    status_init "$project_name" "$AGENT_ID" "$BRANCH" "" ""
    status_phase "initializing" 5 "Inputs validated"

    log_timer_start "config"
    resolve_config
    parse_config
    log_timer_end "config"
    status_phase "initializing" 10 "Configuration loaded"

    generate_branch_name

    # Run pre-flight validation for worktree mode (skip in dry-run)
    if [[ -n "$BRANCH" ]] && [[ "$SANDBOX_MODE" != "overlay" ]] && [[ "$DRY_RUN" != "true" ]]; then
        log_timer_start "preflight"
        source "$SCRIPT_DIR/preflight-check.sh"
        if ! preflight_check "$PROJECT_PATH" "$BRANCH" "$SPEC_FILE" "$IMAGE_NAME" "$AGENT_ID"; then
            status_complete 1 "Pre-flight check failed"
            exit 1
        fi
        log_timer_end "preflight"
        status_phase "initializing" 15 "Pre-flight check passed"
    fi

    log_timer_start "sandbox_setup"
    setup_sandbox
    log_timer_end "sandbox_setup"

    # Update status with sandbox mode and worktree path now that we know them
    status_init "$project_name" "$AGENT_ID" "$BRANCH" "$SANDBOX_MODE" "${WORKTREE_PATH:-}"
    status_phase "preparing" 18 "Sandbox ready"

    generate_volume_mounts
    generate_env_vars
    build_container_command
    status_phase "preparing" 20 "Container configured"

    echo ""
    log_info "Agent Configuration:"
    echo "  Agent:         $(to_upper "$AGENT_NAME") (${CONFIG_FILE})"
    echo "  Instance ID:   $AGENT_ID"
    echo "  Project:       $PROJECT_PATH"
    echo "  Image:         $IMAGE_NAME"
    echo "  Resources:     ${RESOURCE_MEMORY} RAM, ${RESOURCE_CPUS} CPUs"
    echo "  Sandbox Mode:  $SANDBOX_MODE"
    [[ -n "$BRANCH" ]] && echo "  Branch:        $BRANCH"
    [[ "$SANDBOX_MODE" == "worktree" ]] && echo "  Worktree:      $WORKTREE_PATH"
    [[ -n "$SPEC_FILE" ]] && echo "  Spec File:     $SPEC_FILE"
    [[ -n "$TASK_INLINE" ]] && echo "  Task:          ${TASK_INLINE:0:50}..."
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN - Command that would be executed:"
        echo ""
        # Sanitize sensitive env vars in output (mask API keys and tokens)
        local sanitized_cmd="${CONTAINER_CMD[*]}"
        # Mask any -e VAR=value where VAR contains KEY, TOKEN, SECRET, PASSWORD, CREDENTIALS
        # Pattern includes alphanumeric + underscore for var names like CONTEXT7_API_KEY
        sanitized_cmd=$(echo "$sanitized_cmd" | sed -E 's/(-e [A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS)[A-Za-z0-9_]*)=[^ ]*/\1=***MASKED***/gi')
        echo "$sanitized_cmd"
        echo ""
        exit 0
    fi

    echo "┌────────────────────────────────────────────────────────────────────┐"
    printf "│ LAUNCHING %-56s │\n" "$(to_upper "$AGENT_NAME")"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    log_info "Starting container..."
    log_debug "Container command: ${CONTAINER_CMD[*]}"
    log_timer_start "container"
    status_phase "starting" 22 "Launching container"

    # Run the container
    "${CONTAINER_CMD[@]}"
    EXIT_CODE=$?

    log_timer_end "container"
    log_info "Container exited with code: $EXIT_CODE"
    status_phase "running" 90 "Agent completed (exit code: $EXIT_CODE)"

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ AGENT EXITED                                                       │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Handle post-container operations based on sandbox mode
    log_debug "Running post-container operations (mode: $SANDBOX_MODE)"
    log_timer_start "post_container"
    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        post_container_worktree
    else
        post_container_overlay
    fi
    log_timer_end "post_container"

    log_timer_end "total"
    log_finalize $EXIT_CODE

    # Final status update
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        status_complete 0 "" "${PR_URL:-}"
    else
        status_complete "$EXIT_CODE" "Agent exited with error code $EXIT_CODE"
    fi

    exit $EXIT_CODE
}

#===============================================================================
# POST-CONTAINER: WORKTREE MODE
#===============================================================================
# PR_URL is set by post_container_git and used for status reporting
PR_URL=""

post_container_worktree() {
    log_debug "Processing worktree post-container operations..."
    log_debug "  WORKTREE_PATH=$WORKTREE_PATH"

    # Show changes summary
    cd "$WORKTREE_PATH"
    local changes
    changes=$(git status --porcelain 2>/dev/null || echo "")
    log_debug "Git changes detected: $(echo "$changes" | wc -l | tr -d ' ') files"

    if [[ -n "$changes" ]]; then
        local changes_count
        changes_count=$(echo "$changes" | wc -l | tr -d ' ')
        log_success "Agent made $changes_count file change(s)"
        echo ""
        echo "Changed files:"
        echo "$changes" | head -20 | sed 's/^/  /'
        echo ""

        # Run post-container git operations on HOST
        source "$SCRIPT_DIR/post-container-git.sh"
        # post_container_git sets PR_URL global variable
        post_container_git \
            "$WORKTREE_PATH" \
            "$BRANCH" \
            "$GIT_COMMIT_MSG" \
            "$GIT_REMOTE" \
            "$NO_PUSH" \
            "$AGENT_ID" \
            "$SANITIZED_GIT_PATH"
    else
        log_info "No file changes detected"
    fi

    echo ""
    echo "Worktree location: $WORKTREE_PATH"
    echo ""
    echo "To continue working:"
    echo "  cd $WORKTREE_PATH"
    echo ""
    echo "To cleanup worktree:"
    echo "  cd $PROJECT_PATH && git worktree remove $WORKTREE_PATH"
}

#===============================================================================
# POST-CONTAINER: OVERLAY MODE (legacy)
#===============================================================================
post_container_overlay() {
    log_debug "Processing overlay post-container operations..."
    log_debug "  UPPER_DIR=$UPPER_DIR"

    # Show changes summary
    if [[ -d "$UPPER_DIR" ]]; then
        local changes_count
        changes_count=$(find "$UPPER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$changes_count" -gt 0 ]]; then
            log_success "Agent made $changes_count file change(s)"
            echo ""
            echo "Changed files:"
            # Cross-platform: use parameter expansion to strip prefix (safer than sed with special chars)
            find "$UPPER_DIR" -type f 2>/dev/null | while IFS= read -r file; do
                echo "  ${file#${UPPER_DIR}/}"
            done | head -20
            echo ""
            echo "Upper directory: $UPPER_DIR"
            echo ""

            if [[ -z "$BRANCH" ]]; then
                echo "To merge changes manually:"
                echo "  rsync -av ${UPPER_DIR}/ ${PROJECT_PATH}/"
                echo ""
                echo "To discard changes:"
                echo "  rm -rf ${SANDBOX_DIR}"
            fi
        else
            log_info "No file changes detected"
        fi
    fi
}

# Run main
main "$@"
