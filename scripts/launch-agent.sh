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

# Pre-set log level to ERROR when in a TTY for cleaner progress display
# This must happen BEFORE sourcing logging.sh
# Only errors will be shown; progress display handles status updates
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${KAPSIS_DEBUG:-}" ]]; then
    export KAPSIS_LOG_LEVEL="${KAPSIS_LOG_LEVEL:-ERROR}"
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

# Source cross-platform compatibility helpers (provides expand_path_vars, etc.)
source "$SCRIPT_DIR/lib/compat.sh"

# Network isolation mode: none (isolated), filtered (DNS allowlist - default), open (unrestricted)
NETWORK_MODE="${KAPSIS_NETWORK_MODE:-$KAPSIS_DEFAULT_NETWORK_MODE}"

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
# CONFIG PARSING (YAML parsing with yq - required dependency)
#===============================================================================
parse_config() {
    log_debug "Parsing config file: $CONFIG_FILE"

    # Check if yq is available
    if command -v yq &> /dev/null; then
        log_debug "Using yq for config parsing"
        AGENT_COMMAND=$(yq -r '.agent.command // "bash"' "$CONFIG_FILE")
        export AGENT_WORKDIR
        AGENT_WORKDIR=$(yq -r '.agent.workdir // "/workspace"' "$CONFIG_FILE")
        # Gist instruction injection (default: false for safe rollout)
        INJECT_GIST=$(yq -r '.agent.inject_gist // "false"' "$CONFIG_FILE")
        RESOURCE_MEMORY=$(yq -r '.resources.memory // "8g"' "$CONFIG_FILE")
        RESOURCE_CPUS=$(yq -r '.resources.cpus // "4"' "$CONFIG_FILE")
        SANDBOX_UPPER_BASE=$(yq -r '.sandbox.upper_dir_base // "~/.ai-sandboxes"' "$CONFIG_FILE")
        # Only override image if not set via --image flag
        if [[ "$IMAGE_NAME" == "kapsis-sandbox:latest" ]]; then
            IMAGE_NAME=$(yq -r '.image.name // "kapsis-sandbox"' "$CONFIG_FILE"):$(yq -r '.image.tag // "latest"' "$CONFIG_FILE")
        fi
        GIT_REMOTE=$(yq -r '.git.auto_push.remote // "origin"' "$CONFIG_FILE")
        GIT_COMMIT_MSG=$(yq -r '.git.auto_push.commit_message // "feat: AI agent changes"' "$CONFIG_FILE")

        # Parse co-authors (newline-separated list)
        GIT_CO_AUTHORS=$(yq -r '.git.co_authors[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || echo "")

        # Parse fork workflow settings
        GIT_FORK_ENABLED=$(yq -r '.git.fork_workflow.enabled // "false"' "$CONFIG_FILE")
        GIT_FORK_FALLBACK=$(yq -r '.git.fork_workflow.fallback // "fork"' "$CONFIG_FILE")

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
        # account: can be string or array (array joined with comma for fallback support)
        ENV_KEYCHAIN=$(yq '.environment.keychain // {} | to_entries | .[] | .value.account |= (select(kind == "seq") | join(",")) // .value.account | .key + "|" + .value.service + "|" + (.value.account // "") + "|" + (.value.inject_to_file // "") + "|" + (.value.mode // "0600")' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse SSH host verification list
        SSH_VERIFY_HOSTS=$(yq -r '.ssh.verify_hosts[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse network mode from config (CLI flag takes precedence)
        if [[ "$NETWORK_MODE" == "open" ]]; then
            local config_network_mode
            config_network_mode=$(yq -r '.network.mode // "open"' "$CONFIG_FILE")
            if [[ "$config_network_mode" =~ ^(none|filtered|open)$ ]]; then
                NETWORK_MODE="$config_network_mode"
            fi
        fi

        # Parse DNS allowlist from config (for filtered mode)
        # Extract all domains into a comma-separated list for passing to container
        # Uses yq v4 (mikefarah/yq) syntax
        NETWORK_ALLOWLIST_DOMAINS=$(yq eval '
            [
                ((.network.allowlist.hosts // [])[] // ""),
                ((.network.allowlist.registries // [])[] // ""),
                ((.network.allowlist.containers // [])[] // ""),
                ((.network.allowlist.ai // [])[] // ""),
                ((.network.allowlist.custom // [])[] // "")
            ] | map(select(. != "")) | unique | join(",")
        ' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse DNS servers from config
        NETWORK_DNS_SERVERS=$(yq eval '.network.dns_servers // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse DNS logging setting
        NETWORK_LOG_DNS=$(yq eval '.network.log_dns_queries // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")

        # Parse security capabilities from config
        # These are added to KAPSIS_CAPS_ADD for the capability generation
        local config_caps_add
        config_caps_add=$(yq eval '.security.capabilities.add // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$config_caps_add" ]]; then
            # Merge with existing KAPSIS_CAPS_ADD (env var takes precedence for overrides)
            if [[ -n "${KAPSIS_CAPS_ADD:-}" ]]; then
                KAPSIS_CAPS_ADD="${KAPSIS_CAPS_ADD},${config_caps_add}"
            else
                KAPSIS_CAPS_ADD="$config_caps_add"
            fi
            export KAPSIS_CAPS_ADD
        fi

        # Parse security section (lower priority than env vars and CLI)
        # Only set if not already set by env var or CLI flag
        local cfg_security_profile
        cfg_security_profile=$(yq -r '.security.profile // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$cfg_security_profile" ]] && [[ -z "${KAPSIS_SECURITY_PROFILE:-}" ]]; then
            export KAPSIS_SECURITY_PROFILE="$cfg_security_profile"
            log_debug "Security profile from config: $cfg_security_profile"
        fi

        # Parse individual security settings (can override profile defaults)
        local cfg_val
        cfg_val=$(yq -r '.security.process.pids_limit // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ -n "$cfg_val" ]] && [[ -z "${KAPSIS_PIDS_LIMIT:-}" ]] && export KAPSIS_PIDS_LIMIT="$cfg_val"

        cfg_val=$(yq -r '.security.seccomp.enabled // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_SECCOMP_ENABLED:-}" ]] && export KAPSIS_SECCOMP_ENABLED="true"

        cfg_val=$(yq -r '.security.filesystem.noexec_tmp // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_NOEXEC_TMP:-}" ]] && export KAPSIS_NOEXEC_TMP="true"

        cfg_val=$(yq -r '.security.filesystem.readonly_root // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_READONLY_ROOT:-}" ]] && export KAPSIS_READONLY_ROOT="true"

        cfg_val=$(yq -r '.security.lsm.required // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ "$cfg_val" == "true" ]] && [[ -z "${KAPSIS_REQUIRE_LSM:-}" ]] && export KAPSIS_REQUIRE_LSM="true"

        cfg_val=$(yq -r '.security.process.no_new_privileges // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        [[ "$cfg_val" == "false" ]] && [[ -z "${KAPSIS_NO_NEW_PRIVILEGES:-}" ]] && export KAPSIS_NO_NEW_PRIVILEGES="false"
    else
        log_error "yq is required but not installed."
        log_error "Install yq: brew install yq (macOS) or sudo snap install yq (Linux)"
        log_error "Or run: ./setup.sh --install"
        exit 1
    fi

    # Expand environment variables in paths (fixes #104)
    SANDBOX_UPPER_BASE=$(expand_path_vars "$SANDBOX_UPPER_BASE")

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
    WORKTREE_PATH=$(create_worktree "$PROJECT_PATH" "$AGENT_ID" "$BRANCH" "$BASE_BRANCH")

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

# Add common volume mounts shared by all sandbox modes
# These include: status dir, build caches, spec file, filesystem includes, SSH
add_common_volume_mounts() {
    # Status reporting directory (shared between host and container)
    local status_dir="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"
    ensure_dir "$status_dir"
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

# Main dispatcher for volume mount generation
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

    # Mount sanitized git at $CONTAINER_GIT_PATH, replacing the worktree's .git file
    # This makes git work without needing GIT_DIR environment variable
    VOLUME_MOUNTS+=("-v" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro")

    # Mount objects directory read-only
    VOLUME_MOUNTS+=("-v" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro")

    # Add common mounts (status, caches, spec, filesystem includes, SSH)
    add_common_volume_mounts
}

#===============================================================================
# OVERLAY VOLUME MOUNTS (legacy)
#===============================================================================
generate_volume_mounts_overlay() {
    VOLUME_MOUNTS=()

    # Project with CoW overlay
    VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")

    # Add common mounts (status, caches, spec, filesystem includes, SSH)
    add_common_volume_mounts
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
            # Expand environment variables in path (fixes #104)
            expanded_path=$(expand_path_vars "$path")

            if [[ ! -e "$expanded_path" ]]; then
                log_debug "Skipping non-existent path: ${expanded_path}"
                continue
            fi

            # Home directory paths: use staging-and-copy pattern
            # Check original path for ~, $HOME, or ${HOME} patterns
            if [[ "$path" == "~"* ]] || [[ "$path" == *'$HOME'* ]] || [[ "$path" == *'${HOME}'* ]] || [[ "$expanded_path" == "$HOME"* ]]; then
                # Extract relative path (e.g., .claude, .gitconfig)
                relative_path="${expanded_path#"$HOME"/}"
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

    # Skip file creation in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "[DRY-RUN] Would generate SSH known_hosts for: $SSH_VERIFY_HOSTS"
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

            # Query secret store (keychain/secret-tool) with fallback account support
            local value
            if value=$(query_secret_store_with_fallbacks "$service" "$account" "$var_name"); then
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
    ENV_VARS+=("-e" "KAPSIS_INJECT_GIST=${INJECT_GIST:-false}")

    # Agent type for status tracking hooks
    # Maps to hook mechanism: claude-cli, codex-cli, gemini-cli use hooks; others use monitor
    # Try multiple sources: AGENT_NAME, then infer from image name
    local agent_type="${AGENT_NAME:-unknown}"
    local agent_types_lib="$KAPSIS_ROOT/scripts/lib/agent-types.sh"
    if [[ -f "$agent_types_lib" ]]; then
        # shellcheck source=lib/agent-types.sh
        source "$agent_types_lib"
        agent_type=$(normalize_agent_type "$agent_type")
    fi

    # If agent_type is still unknown, try to infer from image name
    # E.g., kapsis-claude-cli -> claude-cli, kapsis-codex-cli -> codex-cli
    if [[ "$agent_type" == "unknown" && -n "$IMAGE_NAME" ]]; then
        case "$IMAGE_NAME" in
            *claude-cli*)  agent_type="claude-cli" ;;
            *codex-cli*)   agent_type="codex-cli" ;;
            *gemini-cli*)  agent_type="gemini-cli" ;;
            *aider*)       agent_type="aider" ;;
        esac
        log_debug "Inferred agent type from image name: $agent_type"
    fi
    ENV_VARS+=("-e" "KAPSIS_AGENT_TYPE=${agent_type}")
    log_debug "Agent type for status tracking: $agent_type"

    # Mode-specific variables
    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        ENV_VARS+=("-e" "KAPSIS_WORKTREE_MODE=true")
    else
        ENV_VARS+=("-e" "KAPSIS_SANDBOX_DIR=${SANDBOX_DIR}")
    fi

    if [[ -n "$BRANCH" ]]; then
        ENV_VARS+=("-e" "KAPSIS_BRANCH=${BRANCH}")
        ENV_VARS+=("-e" "KAPSIS_GIT_REMOTE=${GIT_REMOTE}")
        ENV_VARS+=("-e" "KAPSIS_DO_PUSH=${DO_PUSH}")
        # Fix #116: Pass base branch for proper branch creation
        if [[ -n "$BASE_BRANCH" ]]; then
            ENV_VARS+=("-e" "KAPSIS_BASE_BRANCH=${BASE_BRANCH}")
        fi
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
    # Validate security configuration before building command
    if ! validate_security_config; then
        log_error "Security configuration validation failed"
        exit 1
    fi

    CONTAINER_CMD=(
        "podman" "run"
        "--rm"
        "-it"
        "--name" "kapsis-${AGENT_ID}"
        "--hostname" "kapsis-${AGENT_ID}"
    )

    # Generate security arguments from security.sh library
    # This includes: capabilities, seccomp, process isolation, LSM, resource limits
    local security_args
    mapfile -t security_args < <(generate_security_args "$AGENT_NAME" "$RESOURCE_MEMORY" "$RESOURCE_CPUS")
    CONTAINER_CMD+=("${security_args[@]}")

    # Network isolation mode
    case "$NETWORK_MODE" in
        none)
            log_info "Network: isolated (no network access)"
            CONTAINER_CMD+=("--network=none")
            CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=none")
            ;;
        filtered)
            log_info "Network: filtered (DNS-based allowlist)"
            # Pass environment variables to container for DNS filtering
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
            ;;
        open)
            log_warn "Network: unrestricted (consider --network-mode=none for security)"
            CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=open")
            ;;
    esac

    # Suppress verbose logs inside container when progress display is enabled
    # This prevents entrypoint logs from overwhelming the in-place progress updates
    if [[ "${KAPSIS_PROGRESS_DISPLAY:-0}" == "1" ]]; then
        CONTAINER_CMD+=("-e" "KAPSIS_LOG_LEVEL=ERROR")
    fi

    # Add volume mounts
    CONTAINER_CMD+=("${VOLUME_MOUNTS[@]}")

    # Add inline task spec mount if needed (must be before image name)
    if [[ -n "$TASK_INLINE" ]] && [[ "$INTERACTIVE" != "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            # Use placeholder path in dry-run mode
            CONTAINER_CMD+=("-v" "/tmp/kapsis-inline-spec.XXXXXX:/task-spec.md:ro")
        else
            INLINE_SPEC_FILE=$(mktemp)
            echo "$TASK_INLINE" > "$INLINE_SPEC_FILE"
            CONTAINER_CMD+=("-v" "${INLINE_SPEC_FILE}:/task-spec.md:ro")
        fi
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
    # Initialize progress display (must be early for trap registration)
    display_init

    # Cleanup display on exit (restore cursor visibility, etc.)
    trap 'display_cleanup' EXIT INT TERM

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
    validate_config_security "$CONFIG_FILE"
    parse_config
    log_timer_end "config"
    status_phase "initializing" 10 "Configuration loaded"

    generate_branch_name

    # Substitute placeholders in commit message template
    if [[ -n "${GIT_COMMIT_MSG:-}" ]]; then
        GIT_COMMIT_MSG=$(substitute_commit_placeholders "$GIT_COMMIT_MSG")
        log_debug "Commit message after substitution: $GIT_COMMIT_MSG"
    fi

    # Handle existing worktree for branch (Fix #1: resume/force-clean)
    if [[ -n "$BRANCH" ]] && [[ "$SANDBOX_MODE" != "overlay" ]] && [[ "$DRY_RUN" != "true" ]]; then
        handle_existing_worktree
    fi

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
    [[ -n "$BASE_BRANCH" ]] && echo "  Base Branch:   $BASE_BRANCH"
    [[ "$SANDBOX_MODE" == "worktree" ]] && echo "  Worktree:      $WORKTREE_PATH"
    [[ -n "$SPEC_FILE" ]] && echo "  Spec File:     $SPEC_FILE"
    [[ -n "$TASK_INLINE" ]] && echo "  Task:          ${TASK_INLINE:0:50}..."
    if [[ "${AGENT_ID_AUTO_GENERATED:-false}" == "true" ]]; then
        echo ""
        echo -e "  ${CYAN}To continue this session:${NC} --agent-id $AGENT_ID"
    fi
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN - Command that would be executed:"
        echo ""
        # Security: Use centralized sanitization to mask secrets
        local sanitized_cmd
        sanitized_cmd=$(sanitize_secrets "${CONTAINER_CMD[*]}")
        echo "$sanitized_cmd"
        echo ""
        exit 0
    fi

    echo "┌────────────────────────────────────────────────────────────────────┐"
    printf "│ LAUNCHING %-56s │\n" "$(to_upper "$AGENT_NAME")"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Display progress header (shows sandbox ready status with timer)
    display_header "$AGENT_ID" "$BRANCH" "$NETWORK_MODE"

    log_info "Starting container..."
    # Note: Secret sanitization is handled by _log()
    log_debug "Container command: ${CONTAINER_CMD[*]}"
    log_timer_start "container"
    status_phase "starting" 22 "Launching container"

    # Run the container
    "${CONTAINER_CMD[@]}"
    EXIT_CODE=$?

    log_timer_end "container"
    log_info "Container exited with code: $EXIT_CODE"
    # Update status to post_processing (Fix #3: don't report "completed" until commit verified)
    status_phase "post_processing" 85 "Processing agent output (exit code: $EXIT_CODE)"

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
        POST_EXIT_CODE=$?
    else
        post_container_overlay
        POST_EXIT_CODE=$?
    fi
    log_timer_end "post_container"

    log_timer_end "total"

    # Combine exit codes - fail if either container or post-container operations failed
    # Exit codes (Fix #3):
    #   0 = Success (changes committed or no changes)
    #   1 = Agent failure (container exit code non-zero)
    #   2 = Push failed
    #   3 = Uncommitted changes remain
    if [[ "$EXIT_CODE" -ne 0 ]]; then
        FINAL_EXIT_CODE=$EXIT_CODE
        log_finalize $EXIT_CODE
        status_complete "$EXIT_CODE" "Agent exited with error code $EXIT_CODE"
        display_complete "$EXIT_CODE" "" "Agent exited with error code $EXIT_CODE"
    elif [[ "$POST_EXIT_CODE" -ne 0 ]]; then
        FINAL_EXIT_CODE=$POST_EXIT_CODE
        log_finalize $POST_EXIT_CODE
        status_complete "$POST_EXIT_CODE" "Post-container operations failed (push)"
        display_complete "$POST_EXIT_CODE" "" "Post-container operations failed"
    else
        # Check commit status before reporting success (Fix #3)
        local commit_status
        commit_status=$(status_get_commit_status 2>/dev/null || echo "unknown")
        log_debug "Commit status: $commit_status"

        if [[ "$commit_status" == "uncommitted" ]]; then
            # Exit code 3: changes exist but weren't fully committed
            FINAL_EXIT_CODE=3
            log_finalize 3
            log_warn "Uncommitted changes remain in worktree!"
            status_complete 3 "Uncommitted changes remain"
            display_complete 3 "" "Uncommitted changes remain"
        else
            # Success: no changes, or changes were committed
            FINAL_EXIT_CODE=0
            log_finalize 0
            status_complete 0 "" "${PR_URL:-}"
            display_complete 0 "${PR_URL:-}"
        fi
    fi

    exit $FINAL_EXIT_CODE
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
            log_error "Contents of SCRIPT_DIR: $(ls -la "$SCRIPT_DIR" 2>&1 | head -20)"
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
            "$GIT_FORK_FALLBACK"
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
