#!/usr/bin/env bash
#===============================================================================
# Kapsis - Launch Agent Script
#
# Launches an AI coding agent in a hermetically isolated Podman container
# with Copy-on-Write filesystem, isolated Maven repository, and optional
# git branch workflow.
#
# Usage:
#   ./launch-agent.sh <project-path> [options]
#
# Options:
#   --agent <name>        Agent shortcut: claude, codex, aider, interactive
#   --config <file>       Config file (overrides --agent)
#   --task <description>  Inline task description
#   --spec <file>         Task specification file (markdown)
#   --branch <name>       Git branch to work on (creates or continues)
#   --auto-branch         Auto-generate branch name
#   --push                Push changes to remote after commit
#   --interactive         Force interactive shell mode
#   --dry-run             Show what would be executed without running
#   --worktree-mode       Force worktree mode (git worktrees, simpler cleanup)
#   --overlay-mode        Force overlay mode (fuse-overlayfs, legacy)
#   --network-mode <mode> Network isolation: none, filtered (default), open
#   --security-profile <profile> Security: minimal, standard (default), strict, paranoid
#
# Examples:
#   ./launch-agent.sh ~/project --agent claude --task "fix failing tests"
#   ./launch-agent.sh ~/project --agent codex --spec ./specs/feature.md
#   ./launch-agent.sh ~/project --agent aider --branch feature/DEV-123 --spec ./task.md
#===============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Debug: Log critical paths early (before logging is initialized, write to stderr)
[[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] SCRIPT_DIR=$SCRIPT_DIR" >&2
[[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] KAPSIS_ROOT=$KAPSIS_ROOT" >&2

# Pre-set log level to WARN when in a TTY for cleaner progress display
# This must happen BEFORE sourcing logging.sh
# Warnings and errors will be shown; progress display handles status updates
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${KAPSIS_DEBUG:-}" ]]; then
    export KAPSIS_LOG_LEVEL="${KAPSIS_LOG_LEVEL:-WARN}"
fi

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"
log_init "launch-agent"

# Source status reporting library
source "$SCRIPT_DIR/lib/status.sh"

# Source progress display library
source "$SCRIPT_DIR/lib/progress-display.sh"

# Bash 3.2 compatible uppercase conversion
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Generate 6-character lowercase UUID for agent identification
generate_agent_id() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-6
    elif [[ -r /dev/urandom ]] && command -v xxd &>/dev/null; then
        head -c 3 /dev/urandom | xxd -p
    elif [[ -r /dev/urandom ]]; then
        # Fallback: use od instead of xxd
        head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-6
    else
        printf '%x' "$(( $(date +%s)$$ ))" | cut -c1-6
    fi
}

#===============================================================================
# DEFAULT VALUES
#===============================================================================
AGENT_NAME=""
CONFIG_FILE=""
TASK_INLINE=""
SPEC_FILE=""
BRANCH=""
REMOTE_BRANCH=""  # Remote branch name (when different from local branch)
BASE_BRANCH=""  # Fix #116: Base branch/tag for new feature branches
AUTO_BRANCH=false
DO_PUSH=false
RESUME_MODE=false      # Fix #1: Auto-resume existing worktree
FORCE_CLEAN=false      # Fix #1: Force remove existing worktree
INTERACTIVE=false
DRY_RUN=false
# Use KAPSIS_IMAGE env var if set (for CI), otherwise default
IMAGE_NAME="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"
SANDBOX_MODE=""  # auto-detect, worktree, or overlay
WORKTREE_PATH=""
SANITIZED_GIT_PATH=""
AGENT_ID_AUTO_GENERATED=false  # Track if ID was auto-generated
# Source shared constants (must come before using KAPSIS_DEFAULT_NETWORK_MODE)
source "$SCRIPT_DIR/lib/constants.sh"

# Source security library (provides generate_security_args, validate_security_config, etc.)
source "$SCRIPT_DIR/lib/security.sh"

# Source cross-platform compatibility helpers (provides expand_path_vars, resolve_domain_ips, etc.)
source "$SCRIPT_DIR/lib/compat.sh"

# Source DNS pinning library (provides resolve_allowlist_domains, generate_add_host_args, etc.)
source "$SCRIPT_DIR/lib/dns-pin.sh"

# Source extracted SOLID-compliant libraries
source "$SCRIPT_DIR/lib/config-resolver.sh"
source "$SCRIPT_DIR/lib/env-builder.sh"
source "$SCRIPT_DIR/lib/volume-mounts.sh"

# Network isolation mode: none (isolated), filtered (DNS allowlist - default), open (unrestricted)
NETWORK_MODE="${KAPSIS_NETWORK_MODE:-$KAPSIS_DEFAULT_NETWORK_MODE}"
CLI_NETWORK_MODE=""  # Track if CLI explicitly set network mode

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
# DRY-RUN AWARE HELPERS
#===============================================================================

# Create directory unless in dry-run mode
# Usage: ensure_dir <path>
ensure_dir() {
    local path="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "[DRY-RUN] Would create directory: $path"
    else
        mkdir -p "$path" 2>/dev/null || true
    fi
}

#===============================================================================
# COMMIT MESSAGE TEMPLATE SUBSTITUTION
#===============================================================================
# Substitutes placeholders in commit message templates
# Available placeholders: {task}, {agent}, {agent_id}, {branch}, {timestamp}
substitute_commit_placeholders() {
    local template="$1"

    # Extract task from inline task or spec filename
    local task="${TASK_INLINE:-}"
    if [[ -z "$task" && -n "${SPEC_FILE:-}" ]]; then
        task="$(basename "$SPEC_FILE" .md)"
    fi
    task="${task:-changes}"

    # Perform substitutions
    local result="$template"
    result="${result//\{task\}/$task}"
    result="${result//\{agent\}/${AGENT_NAME:-agent}}"
    result="${result//\{agent_id\}/${AGENT_ID:-unknown}}"
    result="${result//\{branch\}/${BRANCH:-HEAD}}"
    result="${result//\{timestamp\}/$(date +%Y-%m-%d_%H%M%S)}"

    echo "$result"
}

#===============================================================================
# SECRET STORE HELPERS (macOS Keychain, Linux secret-tool)
#===============================================================================
# Functions: detect_os, query_secret_store, query_secret_store_with_fallbacks
# Now in lib/secret-store.sh for reuse across scripts
source "$SCRIPT_DIR/lib/secret-store.sh"

#===============================================================================
# USAGE
#===============================================================================
# Usage: usage [exit_code]
# Displays help text and exits with the given code (default: 0 for help, 1 for errors)
usage() {
    local exit_code="${1:-0}"
    local cmd_name="${KAPSIS_CMD_NAME:-$(basename "$0")}"
    cat << EOF
Usage: $cmd_name <project-path> [options]
       $cmd_name --version
       $cmd_name --check-upgrade
       $cmd_name --upgrade [VERSION] [--dry-run]
       $cmd_name --downgrade [VERSION] [--dry-run]

Launch an AI coding agent in an isolated Podman container.

Global Options (no project path required):
  --version, -V         Display current Kapsis version and installation info
  --check-upgrade       Check if a newer version is available
  --upgrade [VERSION]   Upgrade to latest or specified version
  --downgrade [VERSION] Downgrade to previous or specified version
  --dry-run             Preview upgrade/downgrade commands without executing

Arguments:
  project-path    Path to the project directory to work on

Options:
  --agent <name>        Agent to use: claude, codex, aider, interactive
                        (shortcut for --config configs/<name>.yaml)
  --agent-id <id>       Specify agent ID (for continuing sessions); auto-generated if omitted
  --config <file>       Config file (overrides --agent)
  --task <description>  Inline task description (for simple tasks)
  --spec <file>         Task specification file (for complex tasks)
  --branch <name>       Git branch to work on (creates new or continues existing)
  --remote-branch <name>
                        Remote branch name when different from local branch
  --base-branch <ref>   Base branch/tag for new branches (e.g., main, stable/trunk)
  --auto-branch         Auto-generate branch name from task/spec
  --push                Push changes to remote after commit (default: off)
  --no-push             [DEPRECATED] Push is now off by default, use --push to enable
  --interactive         Force interactive shell mode (ignores agent.command)
  --dry-run             Show what would be executed without running
  --image <name>        Container image to use (e.g., kapsis-claude-cli:latest)
  --worktree-mode       Force worktree mode (requires git repo + branch)
  --overlay-mode        Force overlay mode (fuse-overlayfs, legacy)
  --network-mode <mode> Network isolation: none (isolated),
                        filtered (default, DNS allowlist), open (unrestricted)
  --security-profile <profile>
                        Security hardening: minimal, standard (default), strict, paranoid
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
  # Simple task (agent ID auto-generated)
  $cmd_name ~/project --task "fix failing tests in UserService"

  # Complex task with spec file
  $cmd_name ~/project --spec ./specs/user-preferences.md

  # With git branch workflow (creates or continues)
  $cmd_name ~/project --branch feature/DEV-123 --spec ./task.md

  # Create branch from specific base (e.g., stable/trunk tag)
  $cmd_name ~/project --branch feature/DEV-123 --base-branch stable/trunk --spec ./task.md

  # Push local branch to a different remote branch name
  $cmd_name ~/project --branch my-work --remote-branch claude/my-work-abc --push --spec ./task.md

  # Continue a previous session (use same agent ID)
  $cmd_name ~/project --agent-id a3f2b1 --branch feature/DEV-123 --task "continue"

  # Multiple agents in parallel (each gets unique auto-ID)
  $cmd_name ~/project --branch feature/DEV-123-api --spec ./api.md &
  $cmd_name ~/project --branch feature/DEV-123-ui --spec ./ui.md &
  wait

  # Interactive exploration
  $cmd_name ~/project --interactive --branch experiment/explore

EOF
    exit "$exit_code"
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

# Parse version arguments for upgrade/downgrade commands
# Sets: VERSION_ARG, DRY_RUN_ARG
# Arguments: remaining args after the main flag
parse_version_args() {
    VERSION_ARG=""
    DRY_RUN_ARG=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN_ARG=true
                shift
                ;;
            v*|[0-9]*)
                VERSION_ARG="$1"
                shift
                ;;
            *)
                break
                ;;
        esac
    done
}

# Handle global version management flags
# These flags don't require a project path and exit immediately
handle_global_flags() {
    case "${1:-}" in
        --version|-V)
            source "$SCRIPT_DIR/lib/version.sh"
            print_version
            exit 0
            ;;
        --check-upgrade)
            source "$SCRIPT_DIR/lib/version.sh"
            check_upgrade_available
            exit $?
            ;;
        --upgrade)
            source "$SCRIPT_DIR/lib/version.sh"
            shift
            parse_version_args "$@"
            perform_upgrade "$VERSION_ARG" "$DRY_RUN_ARG"
            exit $?
            ;;
        --downgrade)
            source "$SCRIPT_DIR/lib/version.sh"
            shift
            parse_version_args "$@"
            perform_downgrade "$VERSION_ARG" "$DRY_RUN_ARG"
            exit $?
            ;;
    esac
}

parse_args() {
    # Handle global flags first (version management - no project path required)
    handle_global_flags "$@"

    # No arguments is an error (exit 1 with usage)
    if [[ $# -eq 0 ]]; then
        usage 1
    fi

    # Handle help flags (exit 0 for explicit help request)
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        usage 0
    fi

    # First argument is always the project path
    PROJECT_PATH="$1"
    AGENT_ID=""  # Will be auto-generated if not specified via --agent-id
    shift 1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent)
                AGENT_NAME="$2"
                shift 2
                ;;
            --agent-id)
                AGENT_ID="$2"
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
            --remote-branch)
                REMOTE_BRANCH="$2"
                shift 2
                ;;
            --base-branch)
                # Fix #116: Specify base branch/tag for new feature branches
                BASE_BRANCH="$2"
                shift 2
                ;;
            --auto-branch)
                AUTO_BRANCH=true
                shift
                ;;
            --push)
                DO_PUSH=true
                shift
                ;;
            --no-push)
                # Deprecated: push is now off by default
                log_warn "--no-push is deprecated: push is now OFF by default. Remove this flag."
                DO_PUSH=false
                shift
                ;;
            --resume)
                # Resume existing worktree for branch (Fix #1)
                RESUME_MODE=true
                shift
                ;;
            --force-clean)
                # Force clean start, remove existing worktree (Fix #1)
                FORCE_CLEAN=true
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
            --network-mode)
                NETWORK_MODE="$2"
                CLI_NETWORK_MODE="$2"  # Track that CLI explicitly set this
                shift 2
                ;;
            --security-profile)
                export KAPSIS_SECURITY_PROFILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage 1
                ;;
        esac
    done

    # Auto-generate agent ID if not provided
    if [[ -z "$AGENT_ID" ]]; then
        AGENT_ID=$(generate_agent_id)
        AGENT_ID_AUTO_GENERATED=true
    fi

    # Validate agent ID format before using it for log file paths
    # (must happen before log_reinit_with_agent_id to avoid path traversal in filenames)
    if [[ ! "$AGENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid agent ID format: $AGENT_ID (must match [a-zA-Z0-9_-]+)"
        exit 1
    fi

    # Reinitialize logging with agent-specific log file
    # This prevents log interleaving when running parallel agents
    log_reinit_with_agent_id "$AGENT_ID"
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
    log_debug "  REMOTE_BRANCH=$REMOTE_BRANCH"

    # Validate project path
    PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || {
        log_error "Project path does not exist: $PROJECT_PATH"
        exit 1
    }
    log_debug "Resolved PROJECT_PATH=$PROJECT_PATH"

    # Validate agent ID format
    if [[ ! "$AGENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid agent ID format: $AGENT_ID (must match [a-zA-Z0-9_-]+)"
        exit 1
    fi

    # Validate network mode
    if [[ ! "$NETWORK_MODE" =~ ^(none|filtered|open)$ ]]; then
        log_error "Invalid network mode: $NETWORK_MODE (must be: none, filtered, open)"
        exit 1
    fi

    # Validate task input
    if [[ -z "$TASK_INLINE" && -z "$SPEC_FILE" && "$INTERACTIVE" != "true" ]]; then
        log_error "Task input required: use --task, --spec, or --interactive"
        usage 1
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

# Validate config file is from a trusted location
# Security: Config files can contain commands (agent.command) that will be executed
# Only allow configs from:
#   - Kapsis installation: $KAPSIS_ROOT/configs/
#   - User config: $HOME/.config/kapsis/ or $HOME/.kapsis/
#   - Project-local: $PROJECT_PATH/.kapsis/ or $PROJECT_PATH/agent-sandbox.yaml
#   - Current directory: ./agent-sandbox.yaml or ./.kapsis/
#
# Set KAPSIS_TRUST_ALL_CONFIGS=1 to bypass this check (for testing only)
validate_config_security() {
    local config_path="$1"

    # Allow bypass for testing scenarios
    if [[ "${KAPSIS_TRUST_ALL_CONFIGS:-}" == "1" ]]; then
        log_warn "Security: Config trust validation bypassed (KAPSIS_TRUST_ALL_CONFIGS=1)"
        return 0
    fi

    # Resolve to absolute path
    local abs_path
    abs_path=$(cd "$(dirname "$config_path")" 2>/dev/null && pwd)/$(basename "$config_path")

    log_debug "Validating config security: $abs_path"

    # Define trusted directories (resolved to absolute paths)
    local trusted_dirs=()

    # Kapsis installation configs
    trusted_dirs+=("$KAPSIS_ROOT/configs")

    # User config directories
    trusted_dirs+=("$HOME/.config/kapsis")
    trusted_dirs+=("$HOME/.kapsis")

    # Project-local configs (if PROJECT_PATH is set)
    if [[ -n "${PROJECT_PATH:-}" ]]; then
        local abs_project
        abs_project=$(cd "$PROJECT_PATH" 2>/dev/null && pwd) || true
        if [[ -n "$abs_project" ]]; then
            trusted_dirs+=("$abs_project/.kapsis")
            trusted_dirs+=("$abs_project")  # For agent-sandbox.yaml in project root
        fi
    fi

    # Current directory configs
    local abs_cwd
    abs_cwd=$(pwd)
    trusted_dirs+=("$abs_cwd/.kapsis")
    trusted_dirs+=("$abs_cwd")  # For ./agent-sandbox.yaml

    # Check if config is in a trusted directory
    local config_dir
    config_dir=$(dirname "$abs_path")
    local is_trusted=false

    for trusted in "${trusted_dirs[@]}"; do
        # Normalize trusted path
        local abs_trusted
        abs_trusted=$(cd "$trusted" 2>/dev/null && pwd) || continue

        # Check if config_dir starts with trusted directory
        if [[ "$config_dir" == "$abs_trusted" || "$config_dir" == "$abs_trusted"/* ]]; then
            is_trusted=true
            break
        fi
    done

    if [[ "$is_trusted" != "true" ]]; then
        log_error "Security: Config file is not in a trusted location"
        log_error "  Config path: $abs_path"
        log_error "  Trusted locations:"
        log_error "    - \$KAPSIS_ROOT/configs/ ($KAPSIS_ROOT/configs)"
        log_error "    - \$HOME/.config/kapsis/"
        log_error "    - \$HOME/.kapsis/"
        log_error "    - \$PROJECT_PATH/.kapsis/"
        log_error "    - Current directory (./.kapsis/ or ./agent-sandbox.yaml)"
        exit 1
    fi

    # Security: Warn about world-writable config files
    # World-writable config = potential privilege escalation via command injection
    if [[ -f "$abs_path" ]]; then
        local perms
        if [[ "$(uname)" == "Darwin" ]]; then
            perms=$(stat -f "%Lp" "$abs_path" 2>/dev/null) || perms=""
        else
            perms=$(stat -c "%a" "$abs_path" 2>/dev/null) || perms=""
        fi

        # Check if world-writable (last digit includes 2 or greater for write)
        if [[ -n "$perms" && "${perms: -1}" =~ [2367] ]]; then
            log_warn "Security: Config file is world-writable: $abs_path"
            log_warn "  This is a security risk. Run: chmod o-w '$abs_path'"
        fi
    fi

    # Validate filename doesn't contain suspicious characters
    local filename
    filename=$(basename "$abs_path")
    if [[ ! "$filename" =~ ^[a-zA-Z0-9._-]+\.yaml$ ]]; then
        log_error "Security: Config filename contains suspicious characters: $filename"
        log_error "  Only alphanumeric, dots, dashes, and underscores allowed"
        exit 1
    fi

    log_debug "Config security validation passed: $abs_path"
    return 0
}

resolve_config() {
    log_debug "Resolving configuration..."
    resolve_agent_config "$CONFIG_FILE" "$AGENT_NAME" "$PROJECT_PATH" "$KAPSIS_ROOT" CONFIG_FILE AGENT_NAME
}

#===============================================================================
# CONFIG PARSING (YAML parsing with yq - required dependency)
#===============================================================================
parse_config() {
    log_debug "Parsing config file: $CONFIG_FILE"

    if ! command -v yq &> /dev/null; then
        log_error "yq is required but not installed."
        log_error "Install yq: brew install yq (macOS) or sudo snap install yq (Linux)"
        log_error "Or run: ./setup.sh --install"
        exit 1
    fi

    log_debug "Using yq for config parsing"
    _parse_core_config
    _parse_git_config
    _parse_env_and_fs_config
    _parse_network_config
    _parse_security_config

    # Expand environment variables in paths (fixes #104)
    SANDBOX_UPPER_BASE=$(expand_path_vars "$SANDBOX_UPPER_BASE")

    log_debug "Config parsed successfully:"
    log_debug "  AGENT_COMMAND=$AGENT_COMMAND"
    log_debug "  RESOURCE_MEMORY=$RESOURCE_MEMORY"
    log_debug "  RESOURCE_CPUS=$RESOURCE_CPUS"
    log_debug "  IMAGE_NAME=$IMAGE_NAME"
}

# Parse agent, resource, sandbox, and image settings
# Writes globals: AGENT_COMMAND, AGENT_WORKDIR, INJECT_GIST, RESOURCE_MEMORY,
#   RESOURCE_CPUS, SANDBOX_UPPER_BASE, IMAGE_NAME
_parse_core_config() {
    AGENT_COMMAND=$(yq -r '.agent.command // "bash"' "$CONFIG_FILE")
    export AGENT_WORKDIR
    AGENT_WORKDIR=$(yq -r '.agent.workdir // "/workspace"' "$CONFIG_FILE")
    # Used by env-builder.sh:_env_add_kapsis_core()
    # shellcheck disable=SC2034
    INJECT_GIST=$(yq -r '.agent.inject_gist // "false"' "$CONFIG_FILE")
    RESOURCE_MEMORY=$(yq -r '.resources.memory // "8g"' "$CONFIG_FILE")
    RESOURCE_CPUS=$(yq -r '.resources.cpus // "4"' "$CONFIG_FILE")
    SANDBOX_UPPER_BASE=$(yq -r '.sandbox.upper_dir_base // "~/.ai-sandboxes"' "$CONFIG_FILE")
    # Only override image if not set via --image flag
    if [[ "$IMAGE_NAME" == "kapsis-sandbox:latest" ]]; then
        IMAGE_NAME=$(yq -r '.image.name // "kapsis-sandbox"' "$CONFIG_FILE"):$(yq -r '.image.tag // "latest"' "$CONFIG_FILE")
    fi
}

# Parse git workflow settings (remote, commit message, co-authors, fork)
# Writes globals: GIT_REMOTE, GIT_COMMIT_MSG, GIT_CO_AUTHORS, GIT_FORK_ENABLED, GIT_FORK_FALLBACK
_parse_git_config() {
    GIT_REMOTE=$(yq -r '.git.auto_push.remote // "origin"' "$CONFIG_FILE")
    GIT_COMMIT_MSG=$(yq -r '.git.auto_push.commit_message // "feat: AI agent changes"' "$CONFIG_FILE")
    GIT_CO_AUTHORS=$(yq -r '.git.co_authors[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || echo "")
    GIT_FORK_ENABLED=$(yq -r '.git.fork_workflow.enabled // "false"' "$CONFIG_FILE")
    GIT_FORK_FALLBACK=$(yq -r '.git.fork_workflow.fallback // "fork"' "$CONFIG_FILE")
}

# Parse environment, filesystem, SSH, and Claude-specific config
# Writes globals consumed by sourced libraries (env-builder.sh, volume-mounts.sh):
#   FILESYSTEM_INCLUDES, ENV_PASSTHROUGH, ENV_SET, GLOBAL_INJECT_TO,
#   ENV_KEYCHAIN, SSH_VERIFY_HOSTS, CLAUDE_HOOKS_INCLUDE, CLAUDE_MCP_INCLUDE
# shellcheck disable=SC2034
_parse_env_and_fs_config() {
    FILESYSTEM_INCLUDES=$(yq -r '.filesystem.include[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    ENV_PASSTHROUGH=$(yq -r '.environment.passthrough[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    ENV_SET=$(yq -r '.environment.set // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")

    # Global inject_to default (secret_store is preferred/default)
    GLOBAL_INJECT_TO=$(yq -r '.environment.inject_to // "secret_store"' "$CONFIG_FILE" 2>/dev/null || echo "secret_store")

    # Keychain mappings for secret store lookups
    # Output format: VAR_NAME|service|account|inject_to_file|mode|inject_to per line
    # KAPSIS_INJECT_DEFAULT is read by yq via strenv()
    # KAPSIS_YQ_KEYCHAIN_EXPR is defined in scripts/lib/constants.sh
    ENV_KEYCHAIN=$(KAPSIS_INJECT_DEFAULT="$GLOBAL_INJECT_TO" yq "$KAPSIS_YQ_KEYCHAIN_EXPR" "$CONFIG_FILE" 2>/dev/null || echo "")

    SSH_VERIFY_HOSTS=$(yq -r '.ssh.verify_hosts[]' "$CONFIG_FILE" 2>/dev/null || echo "")

    # Claude agent config whitelisting (include-only)
    CLAUDE_HOOKS_INCLUDE=$(yq -r '.claude.hooks.include // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
    CLAUDE_MCP_INCLUDE=$(yq -r '.claude.mcp_servers.include // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
}

# Parse network mode, DNS allowlist, DNS servers, and DNS pinning settings
# Reads globals: CLI_NETWORK_MODE
# Writes globals: NETWORK_MODE, NETWORK_ALLOWLIST_DOMAINS, NETWORK_DNS_SERVERS,
#   NETWORK_LOG_DNS, NETWORK_DNS_PIN_ENABLED, NETWORK_DNS_PIN_FALLBACK,
#   NETWORK_DNS_PIN_TIMEOUT, NETWORK_DNS_PIN_PROTECT
_parse_network_config() {
    # Network mode from config (CLI flag takes precedence)
    if [[ -z "$CLI_NETWORK_MODE" ]]; then
        local config_network_mode
        config_network_mode=$(yq -r '.network.mode // ""' "$CONFIG_FILE")
        if [[ "$config_network_mode" =~ ^(none|filtered|open)$ ]]; then
            NETWORK_MODE="$config_network_mode"
            log_debug "Network mode from config: $config_network_mode"
        fi
    else
        log_debug "Network mode from CLI: $CLI_NETWORK_MODE (overrides config)"
    fi

    # DNS allowlist: extract all domains into comma-separated list
    NETWORK_ALLOWLIST_DOMAINS=$(yq eval '
        [
            ((.network.allowlist.hosts // [])[] // ""),
            ((.network.allowlist.registries // [])[] // ""),
            ((.network.allowlist.containers // [])[] // ""),
            ((.network.allowlist.ai // [])[] // ""),
            ((.network.allowlist.custom // [])[] // "")
        ] | map(select(. != "")) | unique | join(",")
    ' "$CONFIG_FILE" 2>/dev/null || echo "")

    NETWORK_DNS_SERVERS=$(yq eval '.network.dns_servers // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
    NETWORK_LOG_DNS=$(yq eval '.network.log_dns_queries // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")

    # DNS pinning settings
    NETWORK_DNS_PIN_ENABLED=$(yq eval '.network.dns_pinning.enabled // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
    NETWORK_DNS_PIN_FALLBACK=$(yq eval '.network.dns_pinning.fallback // "dynamic"' "$CONFIG_FILE" 2>/dev/null || echo "dynamic")
    NETWORK_DNS_PIN_TIMEOUT=$(yq eval '.network.dns_pinning.resolve_timeout // "5"' "$CONFIG_FILE" 2>/dev/null || echo "5")
    NETWORK_DNS_PIN_PROTECT=$(yq eval '.network.dns_pinning.protect_dns_files // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
}

# Parse security capabilities, profile, and individual settings
# Writes globals: KAPSIS_CAPS_ADD, KAPSIS_SECURITY_PROFILE, KAPSIS_PIDS_LIMIT, etc.
_parse_security_config() {
    # Capabilities from config (merged with env var)
    local config_caps_add
    config_caps_add=$(yq eval '.security.capabilities.add // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$config_caps_add" ]]; then
        if [[ -n "${KAPSIS_CAPS_ADD:-}" ]]; then
            KAPSIS_CAPS_ADD="${KAPSIS_CAPS_ADD},${config_caps_add}"
        else
            KAPSIS_CAPS_ADD="$config_caps_add"
        fi
        export KAPSIS_CAPS_ADD
    fi

    # Security profile (lower priority than env vars and CLI)
    local cfg_security_profile
    cfg_security_profile=$(yq -r '.security.profile // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$cfg_security_profile" ]] && [[ -z "${KAPSIS_SECURITY_PROFILE:-}" ]]; then
        export KAPSIS_SECURITY_PROFILE="$cfg_security_profile"
        log_debug "Security profile from config: $cfg_security_profile"
    fi

    # Individual security settings (can override profile defaults)
    # Use if-then-fi instead of && chains to avoid set -e failures
    local cfg_val
    cfg_val=$(yq -r '.security.process.pids_limit // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$cfg_val" ]] && [[ -z "${KAPSIS_PIDS_LIMIT:-}" ]]; then export KAPSIS_PIDS_LIMIT="$cfg_val"; fi

    cfg_val=$(yq -r '.security.seccomp.enabled // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_SECCOMP_ENABLED:-}" ]]; then export KAPSIS_SECCOMP_ENABLED="true"; fi

    cfg_val=$(yq -r '.security.filesystem.noexec_tmp // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_NOEXEC_TMP:-}" ]]; then export KAPSIS_NOEXEC_TMP="true"; fi

    cfg_val=$(yq -r '.security.filesystem.readonly_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_READONLY_ROOT:-}" ]]; then export KAPSIS_READONLY_ROOT="true"; fi

    cfg_val=$(yq -r '.security.lsm.required // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_REQUIRE_LSM:-}" ]]; then export KAPSIS_REQUIRE_LSM="true"; fi

    cfg_val=$(yq -r '.security.process.no_new_privileges // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$cfg_val" == "false" ]] && [[ -z "${KAPSIS_NO_NEW_PRIVILEGES:-}" ]]; then export KAPSIS_NO_NEW_PRIVILEGES="false"; fi
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
# SANDBOX DISPATCH TABLE (Open/Closed Principle)
# Adding a new sandbox mode requires only registering handlers here.
#===============================================================================
declare -A SANDBOX_HANDLERS=(
    ["worktree:setup"]="setup_worktree_sandbox"
    ["worktree:post"]="post_container_worktree"
    ["overlay:setup"]="setup_overlay_sandbox"
    ["overlay:post"]="post_container_overlay"
)

# Dispatch to the appropriate handler for a given sandbox mode and phase
sandbox_dispatch() {
    local handler="${SANDBOX_HANDLERS["${1}:${2}"]:-}"
    if [[ -n "$handler" ]]; then
        "$handler" "${@:3}"
    else
        log_error "Unknown sandbox handler: ${1}:${2}"
        exit 1
    fi
}

setup_sandbox() {
    detect_sandbox_mode
    sandbox_dispatch "$SANDBOX_MODE" "setup"
}

#===============================================================================
# WORKTREE SANDBOX SETUP
#===============================================================================
setup_worktree_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    SANDBOX_ID="${project_name}-${AGENT_ID}"

    log_info "Setting up worktree sandbox: $SANDBOX_ID"

    # Source the worktree manager (needed for constants even in dry-run)
    source "$SCRIPT_DIR/worktree-manager.sh"

    # In dry-run mode, compute paths without creating anything
    if [[ "$DRY_RUN" == "true" ]]; then
        WORKTREE_PATH="${KAPSIS_WORKTREE_BASE:-$HOME/.kapsis/worktrees}/${project_name}-${AGENT_ID}"
        SANITIZED_GIT_PATH="${KAPSIS_SANITIZED_GIT_BASE:-$HOME/.kapsis/sanitized-git}/${AGENT_ID}"
        OBJECTS_PATH="${PROJECT_PATH}/.git/objects"
        log_info "  [DRY-RUN] Would create worktree: $WORKTREE_PATH"
        log_info "  [DRY-RUN] Would create sanitized git: $SANITIZED_GIT_PATH"
        log_info "  [DRY-RUN] Objects path: $OBJECTS_PATH"
        return
    fi

    # Create worktree on host (Fix #116: pass base branch for proper branching)
    WORKTREE_PATH=$(create_worktree "$PROJECT_PATH" "$AGENT_ID" "$BRANCH" "$BASE_BRANCH" "$REMOTE_BRANCH")

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

    ensure_dir "$UPPER_DIR"
    ensure_dir "$WORK_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [DRY-RUN] Would create upper directory: $UPPER_DIR"
        log_info "  [DRY-RUN] Would create work directory: $WORK_DIR"
    else
        log_info "  Upper directory: $UPPER_DIR"
        log_info "  Work directory: $WORK_DIR"
    fi
}

#===============================================================================
# VOLUME MOUNTS GENERATION
#===============================================================================

# Volume mount generation is provided by scripts/lib/volume-mounts.sh
# (generate_volume_mounts, generate_volume_mounts_worktree,
#  generate_volume_mounts_overlay, add_common_volume_mounts,
#  generate_filesystem_includes, _snapshot_file, generate_ssh_known_hosts)

# Environment variable generation is provided by scripts/lib/env-builder.sh
# (generate_env_vars, _env_process_passthrough, _env_process_keychain,
#  _env_add_kapsis_core, _env_resolve_agent_type, _env_add_mode_specific,
#  _env_add_git_vars, _env_add_task_and_config, _env_process_explicit_set)

#===============================================================================
# SECRETS ENV FILE GENERATION
#===============================================================================
# Global variables for temp file paths (for cleanup trap)
SECRETS_ENV_FILE=""
DNS_PIN_FILE=""
RESOLV_CONF_FILE=""
SNAPSHOT_DIR=""  # Host-side snapshot dir for filesystem includes (issue #164)

# Write secrets to a temporary env file for use with --env-file flag
# This prevents secrets from appearing in process listings or bash -x traces
# Falls back to inline -e flags if temp file creation fails
write_secrets_env_file() {
    # Skip if no secrets to write
    if [[ ${#SECRET_ENV_VARS[@]} -eq 0 ]]; then
        log_debug "No secrets to write to env file"
        return 0
    fi

    # Try to create temp file (may fail in restricted environments)
    # Note: BSD mktemp (macOS) requires X's at the end of the template - no suffix allowed
    if ! SECRETS_ENV_FILE=$(mktemp "${TMPDIR:-/tmp}/kapsis-secrets-XXXXXX" 2>/dev/null); then
        log_warn "Cannot create secrets env-file in /tmp - falling back to inline env vars"
        log_warn "Secrets may be visible in debug traces (bash -x) or process listings"
        # Fallback: add secrets as inline -e flags (current behavior)
        for secret_entry in "${SECRET_ENV_VARS[@]}"; do
            ENV_VARS+=("-e" "$secret_entry")
        done
        SECRET_ENV_VARS=()  # Clear to prevent double-adding
        return 0
    fi

    # Set restrictive permissions (owner read/write only)
    chmod 600 "$SECRETS_ENV_FILE"

    # Write secrets to file (one VAR=value per line)
    printf '%s\n' "${SECRET_ENV_VARS[@]}" > "$SECRETS_ENV_FILE"

    log_info "Created secrets env-file with ${#SECRET_ENV_VARS[@]} variable(s)"
    log_debug "Secrets env-file: $SECRETS_ENV_FILE"
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
# HANDLE EXISTING WORKTREE (Fix #1)
#
# Detects if a worktree already exists for the target branch and handles
# resume/force-clean scenarios. This prevents cryptic errors when a branch
# is already checked out elsewhere.
#===============================================================================
handle_existing_worktree() {
    # Skip if not using worktree mode
    [[ -z "$BRANCH" ]] && return 0

    log_debug "Checking for existing worktree with branch: $BRANCH"

    # Source worktree manager for find_worktree_for_branch
    source "$SCRIPT_DIR/worktree-manager.sh"

    local existing_worktree
    if ! existing_worktree=$(find_worktree_for_branch "$PROJECT_PATH" "$BRANCH"); then
        log_debug "No existing worktree found for branch: $BRANCH"
        return 0
    fi

    log_info "Found existing worktree for branch '$BRANCH':"
    log_info "  → $existing_worktree"

    # Get metadata about the existing worktree
    local metadata
    metadata=$(get_worktree_metadata "$existing_worktree")
    local existing_agent_id has_changes last_commit
    existing_agent_id=$(echo "$metadata" | grep "^agent_id=" | cut -d= -f2)
    has_changes=$(echo "$metadata" | grep "^has_changes=" | cut -d= -f2)
    last_commit=$(echo "$metadata" | grep "^last_commit=" | cut -d= -f2-)

    if [[ "$has_changes" == "true" ]]; then
        log_warn "  ⚠ Worktree has uncommitted changes"
    fi
    log_info "  Last commit: $last_commit"

    # Handle --force-clean: remove existing worktree
    if [[ "$FORCE_CLEAN" == "true" ]]; then
        log_warn "Force-clean requested: removing existing worktree..."
        cleanup_worktree "$PROJECT_PATH" "$existing_agent_id"
        log_info "Existing worktree removed. Continuing with fresh start."
        return 0
    fi

    # Handle --resume: use existing worktree
    if [[ "$RESUME_MODE" == "true" ]]; then
        log_info "Resume mode: using existing worktree"
        # Update AGENT_ID to match existing worktree
        AGENT_ID="$existing_agent_id"
        log_info "  Agent ID set to: $AGENT_ID"
        return 0
    fi

    # Interactive prompt (if not in non-interactive mode)
    if [[ -t 0 ]] && [[ "$INTERACTIVE" != "false" ]]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────────┐"
        echo "│ EXISTING WORKTREE DETECTED                                         │"
        echo "└────────────────────────────────────────────────────────────────────┘"
        echo ""
        echo "  Branch '$BRANCH' already has a worktree at:"
        echo "  $existing_worktree"
        echo ""
        echo "  [R] Resume - Continue with existing worktree"
        echo "  [S] Start fresh - Remove existing worktree and create new"
        echo "  [V] View - Show worktree status and diff"
        echo "  [A] Abort - Cancel and exit"
        echo ""
        echo -n "  Your choice [R/s/v/a]: "

        local choice
        read -r choice

        case "${choice,,}" in
            r|"")
                # Default: resume
                log_info "Resuming existing worktree..."
                AGENT_ID="$existing_agent_id"
                return 0
                ;;
            s)
                log_warn "Starting fresh: removing existing worktree..."
                cleanup_worktree "$PROJECT_PATH" "$existing_agent_id"
                log_info "Existing worktree removed. Continuing with fresh start."
                return 0
                ;;
            v)
                echo ""
                echo "─── Worktree Status ───"
                git -C "$existing_worktree" status 2>/dev/null || true
                echo ""
                echo "─── Recent Changes ───"
                git -C "$existing_worktree" diff --stat HEAD~3..HEAD 2>/dev/null || true
                echo ""
                echo "─── Uncommitted Changes ───"
                git -C "$existing_worktree" diff --stat 2>/dev/null || echo "(none)"
                echo ""
                # Recurse to prompt again
                handle_existing_worktree
                return $?
                ;;
            a)
                log_info "Aborted by user."
                exit 0
                ;;
            *)
                log_error "Invalid choice: $choice"
                exit 1
                ;;
        esac
    fi

    # Non-interactive mode: default to resume
    log_info "Non-interactive mode: auto-resuming existing worktree"
    AGENT_ID="$existing_agent_id"
    return 0
}

#===============================================================================
# BUILD CONTAINER COMMAND
#===============================================================================
build_container_command() {
    if ! validate_security_config; then
        log_error "Security configuration validation failed"
        exit 1
    fi

    CONTAINER_CMD=(
        "podman" "run"
        "--rm"
        "--name" "kapsis-${AGENT_ID}"
        "--hostname" "kapsis-${AGENT_ID}"
    )

    _build_tty_and_security_args
    _build_network_args
    _build_mounts_env_and_image
}

# Add TTY flags and security arguments
_build_tty_and_security_args() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        if [[ -t 0 ]] && [[ -t 1 ]]; then
            CONTAINER_CMD+=("-it")
        else
            CONTAINER_CMD+=("-i")
        fi
    fi

    local security_args
    mapfile -t security_args < <(generate_security_args "$AGENT_NAME" "$RESOURCE_MEMORY" "$RESOURCE_CPUS")
    CONTAINER_CMD+=("${security_args[@]}")
}

# Add network mode arguments
_build_network_args() {
    case "$NETWORK_MODE" in
        none)
            log_info "Network: isolated (no network access)"
            CONTAINER_CMD+=("--network=none")
            CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=none")
            ;;
        filtered)
            _build_filtered_network_args
            ;;
        open)
            log_warn "Network: unrestricted (consider --network-mode=none for security)"
            CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=open")
            ;;
    esac

    if [[ "${KAPSIS_PROGRESS_DISPLAY:-0}" == "1" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_LOG_LEVEL=WARN")
    fi
}

# Build filtered network mode arguments (DNS allowlist, pinning, resolv.conf)
_build_filtered_network_args() {
    log_info "Network: filtered (DNS-based allowlist)"
    CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=filtered")
    if [[ -n "${NETWORK_ALLOWLIST_DOMAINS:-}" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_DNS_ALLOWLIST=${NETWORK_ALLOWLIST_DOMAINS}")
    fi
    if [[ -n "${NETWORK_DNS_SERVERS:-}" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_DNS_SERVERS=${NETWORK_DNS_SERVERS}")
    fi
    if [[ "${NETWORK_LOG_DNS:-false}" == "true" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_DNS_LOG_QUERIES=true")
    fi

    _build_dns_pinning_args

    # Mount resolv.conf as read-only (prevents agent from modifying DNS)
    RESOLV_CONF_FILE=$(mktemp "${TMPDIR:-/tmp}/kapsis-resolv-XXXXXX")
    cat > "$RESOLV_CONF_FILE" <<'RESOLV_EOF'
# Kapsis DNS Filter - managed by host (read-only mount)
nameserver 127.0.0.1
RESOLV_EOF
    chmod 444 "$RESOLV_CONF_FILE"
    CONTAINER_CMD+=("-v" "${RESOLV_CONF_FILE}:/etc/resolv.conf:ro")
    CONTAINER_CMD+=("-e" "KAPSIS_RESOLV_CONF_MOUNTED=true")

    if [[ "${NETWORK_DNS_PIN_PROTECT:-true}" == "true" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_DNS_PIN_PROTECT_FILES=true")
    fi
}

# Build DNS pinning arguments (resolve domains on host, pin IPs in container)
_build_dns_pinning_args() {
    if [[ "${NETWORK_DNS_PIN_ENABLED:-true}" != "true" ]] || [[ -z "${NETWORK_ALLOWLIST_DOMAINS:-}" ]]; then
        return 0
    fi

    log_info "DNS pinning: resolving allowlist domains on host..."
    local resolved_data
    if resolved_data=$(resolve_allowlist_domains "$NETWORK_ALLOWLIST_DOMAINS" "${NETWORK_DNS_PIN_TIMEOUT:-5}" "${NETWORK_DNS_PIN_FALLBACK:-dynamic}"); then
        if [[ -n "$resolved_data" ]]; then
            DNS_PIN_FILE=$(mktemp)
            if write_pinned_dns_file "$DNS_PIN_FILE" "$resolved_data"; then
                local pinned_count
                pinned_count=$(count_pinned_domains "$DNS_PIN_FILE")
                log_success "DNS pinning: pinned $pinned_count domain(s)"
                CONTAINER_CMD+=("-v" "${DNS_PIN_FILE}:/etc/kapsis/pinned-dns.conf:ro")

                local add_host_args
                mapfile -t add_host_args < <(generate_add_host_args "$DNS_PIN_FILE")
                if [[ ${#add_host_args[@]} -gt 0 ]]; then
                    CONTAINER_CMD+=("${add_host_args[@]}")
                fi
                CONTAINER_CMD+=("-e" "KAPSIS_DNS_PIN_ENABLED=true")
            fi
        fi
    else
        if [[ "${NETWORK_DNS_PIN_FALLBACK:-dynamic}" == "abort" ]]; then
            log_error "DNS pinning failed with fallback=abort - aborting container launch"
            exit 1
        fi
        log_warn "DNS pinning failed - continuing with dynamic DNS (degraded security)"
    fi
}

# Add volume mounts, env vars, secrets, image, and command
_build_mounts_env_and_image() {
    CONTAINER_CMD+=("${VOLUME_MOUNTS[@]}")

    # Inline task spec mount
    if [[ -n "$TASK_INLINE" ]] && [[ "$INTERACTIVE" != "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            CONTAINER_CMD+=("-v" "/tmp/kapsis-inline-spec.XXXXXX:/task-spec.md:ro")
        else
            INLINE_SPEC_FILE=$(mktemp)
            echo "$TASK_INLINE" > "$INLINE_SPEC_FILE"
            CONTAINER_CMD+=("-v" "${INLINE_SPEC_FILE}:/task-spec.md:ro")
        fi
    fi

    # Environment variables
    CONTAINER_CMD+=("${ENV_VARS[@]}")
    if [[ -n "${SECRETS_ENV_FILE:-}" && -f "$SECRETS_ENV_FILE" ]]; then
        CONTAINER_CMD+=("--env-file" "$SECRETS_ENV_FILE")
    fi

    # Image and command
    CONTAINER_CMD+=("$IMAGE_NAME")
    if [[ "$INTERACTIVE" == "true" ]]; then
        CONTAINER_CMD+=("bash")
    elif [[ -n "$AGENT_COMMAND" ]] && [[ "$AGENT_COMMAND" != "bash" ]]; then
        CONTAINER_CMD+=("bash" "-c" "$AGENT_COMMAND")
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================
# Cleanup function — must be at top level for trap accessibility
# shellcheck disable=SC2329  # Function is invoked via trap
_cleanup_with_completion() {
    local exit_code=$?
    [[ -n "${_CONTAINER_OUTPUT_TMP:-}" ]] && rm -f "$_CONTAINER_OUTPUT_TMP"
    [[ -n "${SECRETS_ENV_FILE:-}" && -f "$SECRETS_ENV_FILE" ]] && rm -f "$SECRETS_ENV_FILE"
    [[ -n "${INLINE_SPEC_FILE:-}" && -f "$INLINE_SPEC_FILE" ]] && rm -f "$INLINE_SPEC_FILE"
    [[ -n "${DNS_PIN_FILE:-}" && -f "$DNS_PIN_FILE" ]] && rm -f "$DNS_PIN_FILE"
    [[ -n "${RESOLV_CONF_FILE:-}" && -f "$RESOLV_CONF_FILE" ]] && rm -f "$RESOLV_CONF_FILE"
    [[ -n "${SNAPSHOT_DIR:-}" && -d "$SNAPSHOT_DIR" ]] && rm -rf "$SNAPSHOT_DIR"
    if [[ "${_DISPLAY_COMPLETE_SHOWN:-}" != "true" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            display_complete 0
        else
            display_complete "$exit_code" "" "Exited with code $exit_code"
        fi
    fi
    display_cleanup
    return "$exit_code"
}

#-----------------------------------------------------------------------
# Phase functions for main() orchestrator
#-----------------------------------------------------------------------

# Phase: Initialize display, traps, and banner
phase_init() {
    display_init
    _DISPLAY_COMPLETE_SHOWN=false
    _CONTAINER_OUTPUT_TMP=""
    trap '_cleanup_with_completion' EXIT
    trap 'display_cleanup' INT TERM
    log_timer_start "total"
    log_section "Starting Kapsis Agent Launch"
    print_banner
}

# Phase: Parse args, validate, resolve config, preflight
phase_parse_and_validate() {
    log_debug "Parsing command line arguments..."
    parse_args "$@"

    log_timer_start "validation"
    validate_inputs
    log_timer_end "validation"

    local project_name
    project_name=$(basename "$PROJECT_PATH")
    status_init "$project_name" "$AGENT_ID" "$BRANCH" "" ""
    status_phase "initializing" 5 "Inputs validated"

    log_timer_start "config"
    resolve_config
    validate_config_security "$CONFIG_FILE"
    parse_config
    log_timer_end "config"
    status_phase "initializing" 10 "Configuration loaded"

    generate_branch_name
    if [[ -n "${GIT_COMMIT_MSG:-}" ]]; then
        GIT_COMMIT_MSG=$(substitute_commit_placeholders "$GIT_COMMIT_MSG")
        log_debug "Commit message after substitution: $GIT_COMMIT_MSG"
    fi

    if [[ -n "$BRANCH" ]] && [[ "$SANDBOX_MODE" != "overlay" ]] && [[ "$DRY_RUN" != "true" ]]; then
        handle_existing_worktree
    fi

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
}

# Phase: Setup sandbox, generate volumes/env, build container command
phase_prepare_container() {
    log_timer_start "sandbox_setup"
    setup_sandbox
    log_timer_end "sandbox_setup"

    local project_name
    project_name=$(basename "$PROJECT_PATH")
    status_init "$project_name" "$AGENT_ID" "$BRANCH" "$SANDBOX_MODE" "${WORKTREE_PATH:-}"
    status_phase "preparing" 18 "Sandbox ready"

    generate_volume_mounts
    generate_env_vars
    write_secrets_env_file
    build_container_command
    status_phase "preparing" 20 "Container configured"

    _display_config_summary
}

# Display agent configuration summary
_display_config_summary() {
    echo ""
    log_info "Agent Configuration:"
    echo "  Agent:         $(to_upper "$AGENT_NAME") (${CONFIG_FILE})"
    if [[ "${AGENT_ID_AUTO_GENERATED:-false}" == "true" ]]; then
        echo -e "  Instance ID:   ${CYAN}$AGENT_ID${NC} (auto-generated)"
    else
        echo "  Instance ID:   $AGENT_ID"
    fi
    echo "  Project:       $PROJECT_PATH"
    echo "  Image:         $IMAGE_NAME"
    echo "  Resources:     ${RESOURCE_MEMORY} RAM, ${RESOURCE_CPUS} CPUs"
    echo "  Sandbox Mode:  $SANDBOX_MODE"
    echo "  Network Mode:  $NETWORK_MODE"
    [[ -n "$BRANCH" ]] && echo "  Branch:        $BRANCH"
    [[ -n "$REMOTE_BRANCH" ]] && echo "  Remote Branch: $REMOTE_BRANCH"
    [[ -n "$BASE_BRANCH" ]] && echo "  Base Branch:   $BASE_BRANCH"
    [[ "$SANDBOX_MODE" == "worktree" ]] && echo "  Worktree:      $WORKTREE_PATH"
    [[ -n "$SPEC_FILE" ]] && echo "  Spec File:     $SPEC_FILE"
    [[ -n "$TASK_INLINE" ]] && echo "  Task:          ${TASK_INLINE:0:50}..."
    if [[ "${AGENT_ID_AUTO_GENERATED:-false}" == "true" ]]; then
        echo ""
        echo -e "  ${CYAN}To continue this session:${NC} --agent-id $AGENT_ID"
    fi
    echo ""
}

# Phase: Handle dry-run display and exit
phase_dry_run_exit() {
    if [[ "$DRY_RUN" != "true" ]]; then
        return 0
    fi

    log_info "DRY RUN - Command that would be executed:"
    echo ""
    echo "$(sanitize_secrets "${CONTAINER_CMD[*]}")"

    if [[ ${#SECRET_ENV_VARS[@]} -gt 0 ]]; then
        echo ""
        local secret_names=""
        for secret_entry in "${SECRET_ENV_VARS[@]}"; do
            local name="${secret_entry%%=*}"
            if [[ -n "$secret_names" ]]; then
                secret_names="${secret_names}, ${name}"
            else
                secret_names="${name}"
            fi
        done
        log_info "Secrets (${#SECRET_ENV_VARS[@]}) will be passed via --env-file: $secret_names"
    fi
    echo ""
    exit 0
}

# Phase: Launch container and capture output
phase_run_container() {
    echo "┌────────────────────────────────────────────────────────────────────┐"
    printf "│ LAUNCHING %-56s │\n" "$(to_upper "$AGENT_NAME")"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    display_header "$AGENT_ID" "$BRANCH" "$NETWORK_MODE"

    log_info "Starting container..."
    log_debug "Container command: ${CONTAINER_CMD[*]}"
    log_timer_start "container"
    status_phase "starting" 22 "Launching container"

    local container_output
    container_output=$(mktemp)
    _CONTAINER_OUTPUT_TMP="$container_output"
    CONTAINER_ERROR_OUTPUT=""

    set +e
    if command -v stdbuf &>/dev/null; then
        "${CONTAINER_CMD[@]}" 2>&1 | stdbuf -oL tee "$container_output"
    elif command -v gstdbuf &>/dev/null; then
        "${CONTAINER_CMD[@]}" 2>&1 | gstdbuf -oL tee "$container_output"
    else
        "${CONTAINER_CMD[@]}" 2>&1 | tee "$container_output"
    fi
    EXIT_CODE=${PIPESTATUS[0]}
    set -e

    log_timer_end "container"
    log_info "Container exited with code: $EXIT_CODE"

    _log_container_output "$container_output"
    _extract_container_errors "$container_output"
    rm -f "$container_output"

    status_phase "post_processing" 85 "Processing agent output (exit code: $EXIT_CODE)"
}

# Log full container output to log file
_log_container_output() {
    local container_output="$1"
    if [[ -f "$container_output" ]] && [[ -s "$container_output" ]]; then
        log_debug "=== Container output start ==="
        while IFS= read -r line; do
            local clean_line
            # shellcheck disable=SC2001
            clean_line=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
            log_debug "  $clean_line"
        done < "$container_output"
        log_debug "=== Container output end ==="
    fi
}

# Extract error lines from container output for display
_extract_container_errors() {
    local container_output="$1"
    if [[ "$EXIT_CODE" -ne 0 ]] && [[ -f "$container_output" ]] && [[ -s "$container_output" ]]; then
        local stripped_output
        stripped_output=$(sed 's/\x1b\[[0-9;]*m//g' "$container_output")
        CONTAINER_ERROR_OUTPUT=$(echo "$stripped_output" | grep -E '\[ERROR\]|SECURITY:|unbound variable|command not found|Permission denied' | head -10 || true)
        if [[ -z "$CONTAINER_ERROR_OUTPUT" ]]; then
            CONTAINER_ERROR_OUTPUT=$(echo "$stripped_output" | tail -10)
            log_debug "No specific error patterns found, using last 10 lines"
        else
            log_debug "Found error patterns in container output"
        fi
        log_debug "CONTAINER_ERROR_OUTPUT: $CONTAINER_ERROR_OUTPUT"
    fi
}

# Phase: Run post-container operations (uses sandbox dispatch table)
phase_post_container() {
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ AGENT EXITED                                                       │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    log_debug "Running post-container operations (mode: $SANDBOX_MODE)"
    log_timer_start "post_container"
    sandbox_dispatch "$SANDBOX_MODE" "post"
    POST_EXIT_CODE=$?
    log_timer_end "post_container"
}

# Phase: Resolve final exit code and report status
phase_finalize() {
    log_timer_end "total"

    if [[ "$EXIT_CODE" -ne 0 ]]; then
        FINAL_EXIT_CODE=$EXIT_CODE
        log_finalize "$EXIT_CODE"
        status_complete "$EXIT_CODE" "Agent exited with error code $EXIT_CODE"
        local error_msg="Agent exited with error code $EXIT_CODE"
        if [[ -n "$CONTAINER_ERROR_OUTPUT" ]]; then
            error_msg="$CONTAINER_ERROR_OUTPUT"
        fi
        display_complete "$EXIT_CODE" "" "$error_msg"
        _DISPLAY_COMPLETE_SHOWN=true
    elif [[ "$POST_EXIT_CODE" -ne 0 ]]; then
        FINAL_EXIT_CODE=$POST_EXIT_CODE
        log_finalize $POST_EXIT_CODE
        status_complete "$POST_EXIT_CODE" "Post-container operations failed (push)"
        display_complete "$POST_EXIT_CODE" "" "Post-container operations failed"
        _DISPLAY_COMPLETE_SHOWN=true
    else
        _finalize_success
    fi

    exit "$FINAL_EXIT_CODE"
}

# Handle success case with commit status check
_finalize_success() {
    local commit_status
    commit_status=$(status_get_commit_status 2>/dev/null || echo "unknown")
    log_debug "Commit status: $commit_status"

    if [[ "$commit_status" == "uncommitted" ]]; then
        FINAL_EXIT_CODE=3
        log_finalize 3
        log_warn "Uncommitted changes remain in worktree!"
        status_complete 3 "Uncommitted changes remain"
        display_complete 3 "" "Uncommitted changes remain"
    else
        FINAL_EXIT_CODE=0
        log_finalize 0
        status_complete 0 "" "${PR_URL:-}"
        display_complete 0 "${PR_URL:-}"
    fi
    _DISPLAY_COMPLETE_SHOWN=true
}

#-----------------------------------------------------------------------
# Main orchestrator — thin function calling phase functions
#-----------------------------------------------------------------------
main() {
    phase_init
    phase_parse_and_validate "$@"
    phase_prepare_container
    phase_dry_run_exit
    phase_run_container
    phase_post_container
    phase_finalize
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

        # Security: Validate filesystem scope before proceeding
        source "$SCRIPT_DIR/lib/validate-scope.sh"
        if ! validate_scope_worktree "$WORKTREE_PATH"; then
            log_error "Aborting due to scope violation"
            status_complete 1 "Scope violation detected"
            return 1
        fi

        # Run post-container git operations on HOST
        local post_container_script="$SCRIPT_DIR/post-container-git.sh"
        log_debug "Sourcing post-container script: $post_container_script"
        if [[ ! -f "$post_container_script" ]]; then
            log_error "post-container-git.sh not found at: $post_container_script"
            log_error "SCRIPT_DIR=$SCRIPT_DIR"
            log_error "Scripts in SCRIPT_DIR:"
            while IFS= read -r -d '' f; do
                log_error "  $(basename "$f")"
            done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.sh" -print0 2>/dev/null)
            return 1
        fi
        source "$post_container_script"
        # post_container_git sets PR_URL global variable
        post_container_git \
            "$WORKTREE_PATH" \
            "$BRANCH" \
            "$GIT_COMMIT_MSG" \
            "$GIT_REMOTE" \
            "$DO_PUSH" \
            "$AGENT_ID" \
            "$SANITIZED_GIT_PATH" \
            "$GIT_CO_AUTHORS" \
            "$GIT_FORK_ENABLED" \
            "$GIT_FORK_FALLBACK" \
            "$REMOTE_BRANCH"
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
                echo "  ${file#"${UPPER_DIR}"/}"
            done | head -20
            echo ""

            # Security: Validate filesystem scope before proceeding
            source "$SCRIPT_DIR/lib/validate-scope.sh"
            if ! validate_scope_overlay "$UPPER_DIR"; then
                log_error "Aborting due to scope violation"
                status_complete 1 "Scope violation detected"
                echo "Upper directory preserved: $UPPER_DIR"
                return 1
            fi

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
