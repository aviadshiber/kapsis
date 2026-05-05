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
AGENT_CONFIG_TYPE=""  # Fix #213: explicit agent type from config YAML
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
KEEP_WORKTREE="${KAPSIS_KEEP_WORKTREE:-false}"  # Fix #169: Preserve worktree after completion
KEEP_VOLUMES="${KAPSIS_KEEP_VOLUMES:-false}"  # Fix #191: Preserve build cache volumes after completion
CLI_CO_AUTHORS=()  # Co-authors added via --co-author CLI flag (merged with config)
INTERACTIVE=false
DRY_RUN=false
# Use KAPSIS_IMAGE env var if set (for CI), otherwise default
IMAGE_NAME="${KAPSIS_IMAGE:-kapsis-sandbox:latest}"
SANDBOX_MODE=""  # auto-detect, worktree, or overlay
WORKTREE_PATH=""
SANITIZED_GIT_PATH=""
OBJECTS_PATH=""
AGENT_ID_AUTO_GENERATED=false  # Track if ID was auto-generated
# Source shared constants (must come before using KAPSIS_DEFAULT_NETWORK_MODE)
source "$SCRIPT_DIR/lib/constants.sh"
BACKEND="${KAPSIS_DEFAULT_BACKEND}"  # podman (default) or k8s

# Source security library (provides generate_security_args, validate_security_config, etc.)
source "$SCRIPT_DIR/lib/security.sh"

# Source cross-platform compatibility helpers (provides expand_path_vars, resolve_domain_ips, etc.)
source "$SCRIPT_DIR/lib/compat.sh"

# Source DNS pinning library (provides resolve_allowlist_domains, generate_add_host_args, etc.)
source "$SCRIPT_DIR/lib/dns-pin.sh"

# Source virtio-fs health probe / auto-heal (Issue #276) — macOS only, no-op on Linux
source "$SCRIPT_DIR/lib/podman-health.sh"
# shellcheck source=lib/vfkit-watchdog.sh
source "$SCRIPT_DIR/lib/vfkit-watchdog.sh"

# Source host-side status volume sync (Issue #276) — no-op when KAPSIS_STATUS_VOLUME unset
source "$SCRIPT_DIR/lib/status-sync.sh"

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
  --keep-worktree       Preserve worktree after agent completion (default: auto-cleanup)
  --keep-volumes        Preserve build cache volumes after completion (default: auto-cleanup)
  --interactive         Force interactive shell mode (ignores agent.command)
  --dry-run             Show what would be executed without running
  --image <name>        Container image to use (e.g., kapsis-claude-cli:latest)
  --worktree-mode       Force worktree mode (requires git repo + branch)
  --overlay-mode        Force overlay mode (fuse-overlayfs, legacy)
  --network-mode <mode> Network isolation: none (isolated),
                        filtered (default, DNS allowlist), open (unrestricted)
  --security-profile <profile>
                        Security hardening: minimal, standard (default), strict, paranoid
  --co-author "Name <email>"
                        Add a git Co-authored-by trailer (repeatable; merges with config)
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
            --keep-worktree)
                # Preserve worktree after agent completion (Fix #169)
                KEEP_WORKTREE=true
                shift
                ;;
            --keep-volumes)
                # Preserve build cache volumes after agent completion (Fix #191)
                KEEP_VOLUMES=true
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
            --backend)
                BACKEND="$2"
                if [[ ! " $KAPSIS_SUPPORTED_BACKENDS " =~ [[:space:]]${BACKEND}[[:space:]] ]]; then
                    log_error "Unsupported backend: '$BACKEND'. Supported: $KAPSIS_SUPPORTED_BACKENDS"
                    exit 1
                fi
                shift 2
                ;;
            --security-profile)
                export KAPSIS_SECURITY_PROFILE="$2"
                shift 2
                ;;
            --co-author)
                if [[ $# -lt 2 ]]; then
                    log_error "--co-author requires an argument"
                    exit 1
                fi
                # Validate format: "Name <email>" — reject shell metacharacters in name
                if [[ ! "$2" =~ ^[[:alnum:][:space:].\'\",_-]+\ \<[^\>]+@[^\>]+\>$ ]]; then
                    log_error "Invalid --co-author format (expected 'Name <email>'): $2"
                    exit 1
                fi
                CLI_CO_AUTHORS+=("$2")
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

    # Backend validation (sources backend file and checks prerequisites)
    source "$SCRIPT_DIR/backends/${BACKEND}.sh"
    if ! backend_validate; then
        log_error "Backend '$BACKEND' validation failed"
        exit 1
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
        # Fix #213: explicit agent type for LSP injection, hooks, etc.
        AGENT_CONFIG_TYPE=$(yq -r '.agent.type // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        export AGENT_WORKDIR
        AGENT_WORKDIR=$(yq -r '.agent.workdir // "/workspace"' "$CONFIG_FILE")
        # Gist instruction injection (default: false for safe rollout)
        INJECT_GIST=$(yq -r '.agent.inject_gist // "false"' "$CONFIG_FILE")
        # LLM gist upgrade layer (default: false — adds per-tool Haiku API call)
        GIST_LLM=$(yq -r '.agent.gist_llm // "false"' "$CONFIG_FILE")
        GIST_LLM_INTERVAL=$(yq -r '.agent.gist_llm_interval // "60"' "$CONFIG_FILE")
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

        # Parse attribution templates (commit trailer + PR description).
        # A null/missing value yields the string "null" from yq -r; treat that as unset
        # so defaults kick in. An explicit empty string in config disables attribution.
        # Strip trailing whitespace — yq -r on YAML '|' block scalars appends a newline
        GIT_ATTRIBUTION_COMMIT_RAW=$(yq -r '.git.attribution.commit' "$CONFIG_FILE" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "null")
        GIT_ATTRIBUTION_PR_RAW=$(yq -r '.git.attribution.pr' "$CONFIG_FILE" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "null")

        # Parse fork workflow settings
        GIT_FORK_ENABLED=$(yq -r '.git.fork_workflow.enabled // "false"' "$CONFIG_FILE")
        GIT_FORK_FALLBACK=$(yq -r '.git.fork_workflow.fallback // "fork"' "$CONFIG_FILE")

        # Parse filesystem includes
        FILESYSTEM_INCLUDES=$(yq -r '.filesystem.include[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment passthrough
        ENV_PASSTHROUGH=$(yq -r '.environment.passthrough[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment set
        ENV_SET=$(yq -r '.environment.set // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")

        # Parse audit config (top-level audit.enabled or environment.set fallback)
        # Must happen before volume mounts since audit mount depends on this value
        if [[ -z "${KAPSIS_AUDIT_ENABLED:-}" ]]; then
            local config_audit_enabled
            config_audit_enabled=$(yq -r '.audit.enabled // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
            if [[ "$config_audit_enabled" != "true" ]]; then
                # Fallback: check environment.set.KAPSIS_AUDIT_ENABLED
                config_audit_enabled=$(yq -r '.environment.set.KAPSIS_AUDIT_ENABLED // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
            fi
            if [[ "$config_audit_enabled" == "true" ]]; then
                KAPSIS_AUDIT_ENABLED="true"
            fi
        fi

        # Parse global inject_to default (secret_store is preferred/default)
        GLOBAL_INJECT_TO=$(yq -r '.environment.inject_to // "secret_store"' "$CONFIG_FILE" 2>/dev/null || echo "secret_store")

        # Parse keychain mappings for secret store lookups
        # Output format: VAR_NAME|service|account|inject_to_file|mode|inject_to per line
        # inject_to_file: optional file path to write the secret to (agent-agnostic)
        # mode: optional file permissions (default 0600)
        # inject_to: where to inject in container - "secret_store" (default) or "env"
        # account: can be string or array (array joined with comma for fallback support)
        # KAPSIS_INJECT_DEFAULT is read by yq via strenv()
        # KAPSIS_YQ_KEYCHAIN_EXPR is defined in scripts/lib/constants.sh
        ENV_KEYCHAIN=$(KAPSIS_INJECT_DEFAULT="$GLOBAL_INJECT_TO" yq "$KAPSIS_YQ_KEYCHAIN_EXPR" "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse SSH host verification list
        SSH_VERIFY_HOSTS=$(yq -r '.ssh.verify_hosts[]' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse Claude agent config whitelisting (include-only)
        # When set, only matching hooks/MCP servers are kept in the container
        CLAUDE_HOOKS_INCLUDE=$(yq -r '.claude.hooks.include // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")
        CLAUDE_MCP_INCLUDE=$(yq -r '.claude.mcp_servers.include // [] | join(",")' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse LSP server configuration (agent-agnostic YAML, transformed per agent in container)
        LSP_SERVERS_JSON=$(yq -r '.lsp_servers // {} | tojson' "$CONFIG_FILE" 2>/dev/null || echo "{}")

        # Parse liveness monitoring configuration
        LIVENESS_ENABLED=$(yq -r '.liveness.enabled // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
        LIVENESS_TIMEOUT=$(yq -r '.liveness.timeout // "900"' "$CONFIG_FILE" 2>/dev/null || echo "900")
        LIVENESS_GRACE_PERIOD=$(yq -r '.liveness.grace_period // "300"' "$CONFIG_FILE" 2>/dev/null || echo "300")
        LIVENESS_CHECK_INTERVAL=$(yq -r '.liveness.check_interval // "30"' "$CONFIG_FILE" 2>/dev/null || echo "30")
        LIVENESS_COMPLETION_TIMEOUT=$(yq -r '.liveness.completion_timeout // "120"' "$CONFIG_FILE" 2>/dev/null || echo "120")

        # Parse sleep prevention configuration (Issue #276, macOS only)
        KAPSIS_PREVENT_SLEEP=$(yq -r '.prevent_sleep // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
        export KAPSIS_PREVENT_SLEEP

        # Parse mount check configuration (Issue #248)
        # Defaults to true when liveness section exists, since mount checking is lightweight
        MOUNT_CHECK_ENABLED=$(yq -r '.liveness.mount_check // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
        MOUNT_CHECK_RETRIES=$(yq -r '.liveness.mount_check_retries // "2"' "$CONFIG_FILE" 2>/dev/null || echo "2")
        MOUNT_CHECK_RETRY_DELAY=$(yq -r '.liveness.mount_check_retry_delay // "5"' "$CONFIG_FILE" 2>/dev/null || echo "5")
        MOUNT_CHECK_PROBE_TIMEOUT=$(yq -r '.liveness.mount_check_probe_timeout // "5"' "$CONFIG_FILE" 2>/dev/null || echo "5")
        MOUNT_CHECK_DELAY=$(yq -r '.liveness.mount_check_delay // "30"' "$CONFIG_FILE" 2>/dev/null || echo "30")

        # Parse network mode from config (CLI flag takes precedence)
        # Only read from config if CLI didn't explicitly set the value
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

        # Parse DNS pinning settings
        NETWORK_DNS_PIN_ENABLED=$(yq eval '.network.dns_pinning.enabled // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
        NETWORK_DNS_PIN_FALLBACK=$(yq eval '.network.dns_pinning.fallback // "dynamic"' "$CONFIG_FILE" 2>/dev/null || echo "dynamic")
        NETWORK_DNS_PIN_TIMEOUT=$(yq eval '.network.dns_pinning.resolve_timeout // "5"' "$CONFIG_FILE" 2>/dev/null || echo "5")
        NETWORK_DNS_PIN_PROTECT=$(yq eval '.network.dns_pinning.protect_dns_files // "true"' "$CONFIG_FILE" 2>/dev/null || echo "true")
        # Failure-rate abort thresholds (Issue #216): integers 0-100 (percent) / absolute count
        NETWORK_DNS_PIN_MAX_FAILURE_RATE=$(yq eval '.network.dns_pinning.max_failure_rate // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        NETWORK_DNS_PIN_MAX_FAILURES=$(yq eval '.network.dns_pinning.max_failures // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse cleanup configuration (Fix #183)
        # Env vars take precedence over YAML via ${VAR:-$(yq ...)} pattern
        KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS="${KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS:-$(yq -r '.cleanup.worktree.max_age_hours // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_GC_ON_LAUNCH="${KAPSIS_CLEANUP_GC_ON_LAUNCH:-$(yq -r '.cleanup.worktree.gc_on_launch // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_GC_BACKGROUND="${KAPSIS_CLEANUP_GC_BACKGROUND:-$(yq -r '.cleanup.worktree.gc_background // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_BRANCH_ENABLED="${KAPSIS_CLEANUP_BRANCH_ENABLED:-$(yq -r '.cleanup.branch.enabled // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_BRANCH_PREFIXES="${KAPSIS_CLEANUP_BRANCH_PREFIXES:-$(yq -r '.cleanup.branch.prefixes // [] | join("|")' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_BRANCH_PROTECTED="${KAPSIS_CLEANUP_BRANCH_PROTECTED:-$(yq -r '.cleanup.branch.protected // [] | join("|")' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED="${KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED:-$(yq -r '.cleanup.branch.require_pushed // ""' "$CONFIG_FILE" 2>/dev/null || echo "")}"
        export KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS KAPSIS_CLEANUP_GC_ON_LAUNCH KAPSIS_CLEANUP_GC_BACKGROUND
        export KAPSIS_CLEANUP_BRANCH_ENABLED KAPSIS_CLEANUP_BRANCH_PREFIXES KAPSIS_CLEANUP_BRANCH_PROTECTED
        export KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED

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

    # Merge CLI --co-author entries into GIT_CO_AUTHORS (pipe-separated).
    # Dedup happens downstream in build_coauthor_trailers().
    if [[ "${#CLI_CO_AUTHORS[@]}" -gt 0 ]]; then
        for c in "${CLI_CO_AUTHORS[@]}"; do
            if [[ -n "${GIT_CO_AUTHORS:-}" ]]; then
                GIT_CO_AUTHORS+="|$c"
            else
                GIT_CO_AUTHORS="$c"
            fi
        done
        log_debug "Merged ${#CLI_CO_AUTHORS[@]} CLI co-author(s) with config"
    fi

    # Resolve attribution templates — fall back to Kapsis-only default when
    # config has no attribution key (yq returns "null" for missing keys).
    # An explicit empty string in config disables attribution entirely.
    local default_commit_attr
    default_commit_attr="[Generated by Kapsis](https://github.com/aviadshiber/kapsis) v{version}"$'\n'"Agent: {agent_id}"
    local default_pr_attr="[Generated by Kapsis](https://github.com/aviadshiber/kapsis)"

    if [[ "${GIT_ATTRIBUTION_COMMIT_RAW:-null}" == "null" ]]; then
        GIT_ATTRIBUTION_COMMIT="$default_commit_attr"
    else
        GIT_ATTRIBUTION_COMMIT="$GIT_ATTRIBUTION_COMMIT_RAW"
    fi
    if [[ "${GIT_ATTRIBUTION_PR_RAW:-null}" == "null" ]]; then
        GIT_ATTRIBUTION_PR="$default_pr_attr"
    else
        GIT_ATTRIBUTION_PR="$GIT_ATTRIBUTION_PR_RAW"
    fi

    # Substitute placeholders: {version}, {agent_id}, {branch}
    # {worktree} is resolved later in generate_env_vars() once WORKTREE_PATH is known.
    # Version resolution matches get_kapsis_version() in post-container-git.sh:
    # prefer package.json, fall back to git describe, else "dev".
    local kapsis_version_str="${KAPSIS_VERSION:-}"
    if [[ -z "$kapsis_version_str" ]] && [[ -f "$KAPSIS_ROOT/package.json" ]]; then
        kapsis_version_str=$(grep -o '"version": *"[^"]*"' "$KAPSIS_ROOT/package.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    if [[ -z "$kapsis_version_str" ]] && command -v git &>/dev/null; then
        kapsis_version_str=$(git -C "$KAPSIS_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "")
    fi
    [[ -z "$kapsis_version_str" ]] && kapsis_version_str="dev"
    GIT_ATTRIBUTION_COMMIT="${GIT_ATTRIBUTION_COMMIT//\{version\}/$kapsis_version_str}"
    GIT_ATTRIBUTION_COMMIT="${GIT_ATTRIBUTION_COMMIT//\{agent_id\}/$AGENT_ID}"
    GIT_ATTRIBUTION_COMMIT="${GIT_ATTRIBUTION_COMMIT//\{branch\}/${BRANCH:-}}"
    GIT_ATTRIBUTION_PR="${GIT_ATTRIBUTION_PR//\{version\}/$kapsis_version_str}"
    GIT_ATTRIBUTION_PR="${GIT_ATTRIBUTION_PR//\{agent_id\}/$AGENT_ID}"
    GIT_ATTRIBUTION_PR="${GIT_ATTRIBUTION_PR//\{branch\}/${BRANCH:-}}"

    log_debug "Config parsed successfully:"
    log_debug "  AGENT_COMMAND=$AGENT_COMMAND"
    log_debug "  RESOURCE_MEMORY=$RESOURCE_MEMORY"
    log_debug "  RESOURCE_CPUS=$RESOURCE_CPUS"
    log_debug "  IMAGE_NAME=$IMAGE_NAME"
    log_debug "  GIT_ATTRIBUTION_COMMIT=${GIT_ATTRIBUTION_COMMIT%%$'\n'*}..."
}

#===============================================================================
# AGENT COMMAND VALIDATION
#===============================================================================
validate_agent_command() {
    local cmd="$1"
    [[ -z "$cmd" || "$cmd" == "bash" ]] && return 0

    # Validate that the command starts with a known agent binary.
    # Container isolation bounds the blast radius of the command itself;
    # this check ensures the invocation at least *begins* with a sanctioned
    # binary, catching config tampering that swaps in arbitrary programs.
    local first_word
    first_word=$(echo "$cmd" | awk '{print $1}')

    local -a known_prefixes=(
        "claude" "codex" "aider" "gemini" "bash" "sh" "python3" "python" "node" "echo"
    )
    for prefix in "${known_prefixes[@]}"; do
        if [[ "$first_word" == "$prefix" ]]; then
            return 0
        fi
    done

    # Strict mode: block unrecognized commands when KAPSIS_STRICT_AGENT_COMMANDS=1
    if [[ "${KAPSIS_STRICT_AGENT_COMMANDS:-}" == "1" ]]; then
        log_error "Strict mode: agent command '$first_word' is not in the allowlist"
        log_error "Allowed: ${known_prefixes[*]}"
        return 1
    fi

    log_debug "Agent command '$first_word' is not in the known-safe list (non-strict mode)"
    return 0
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
# Acquire an atomic GC lock using mkdir (POSIX-atomic). Returns 0 if acquired.
# Uses a lock directory with a PID file inside. (Fix #183)
_gc_lock_acquire() {
    local lock_dir="$1"
    # Try atomic mkdir — only one process can succeed
    if mkdir "$lock_dir" 2>/dev/null; then
        return 0  # Lock acquired
    fi
    # Lock dir exists — check if owner is still alive
    local pid_file="${lock_dir}/pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || return 1
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 1  # Lock held by live process
        fi
    fi
    # Stale lock — remove and retry once
    rm -rf "$lock_dir" 2>/dev/null || return 1
    mkdir "$lock_dir" 2>/dev/null
}

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
# WORKTREE PATH VALIDATION (Fix #221)
#
# Validates that WORKTREE_PATH exists and is well-formed after creation.
# Guards against race conditions (background GC, external deletion) and
# filesystem issues between worktree creation and container start.
#===============================================================================
validate_worktree_path() {
    local worktree_path="$1"
    local sanitized_git_path="$2"

    if [[ ! -d "$worktree_path" ]]; then
        log_error "WORKTREE MISSING: $worktree_path does not exist after creation"
        log_error "Possible causes: background GC race condition, filesystem error"
        return 1
    fi

    if [[ ! -f "$worktree_path/.git" ]]; then
        log_error "WORKTREE INVALID: $worktree_path/.git not found"
        log_error "Expected a git worktree with .git file"
        return 1
    fi

    if [[ ! -d "$sanitized_git_path" ]]; then
        log_error "SANITIZED GIT MISSING: $sanitized_git_path does not exist"
        return 1
    fi

    log_debug "Worktree validation passed: $worktree_path"
    return 0
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

    # Opportunistic GC: clean stale worktrees from previous completed agents (Fix #169, #183)
    local gc_on_launch="${KAPSIS_CLEANUP_GC_ON_LAUNCH:-${KAPSIS_DEFAULT_CLEANUP_GC_ON_LAUNCH:-true}}"
    local gc_background="${KAPSIS_CLEANUP_GC_BACKGROUND:-${KAPSIS_DEFAULT_CLEANUP_GC_BACKGROUND:-true}}"

    if [[ "$gc_on_launch" == "true" ]]; then
        if [[ "$gc_background" == "true" ]]; then
            # Run GC in background to avoid blocking agent launch (Fix #183)
            local gc_lock_dir
            gc_lock_dir="${KAPSIS_GC_LOCK_DIR:-$HOME/.kapsis/locks}/gc-$(basename "$PROJECT_PATH").lock.d"
            mkdir -p "$(dirname "$gc_lock_dir")" 2>/dev/null || true
            if _gc_lock_acquire "$gc_lock_dir"; then
                (
                    echo "$BASHPID" > "${gc_lock_dir}/pid"
                    trap 'rm -rf "$gc_lock_dir"' EXIT
                    gc_stale_worktrees "$PROJECT_PATH" "$AGENT_ID" 2>>"${LOG_FILE:-/dev/null}" || true
                ) &
                disown
                log_debug "Background GC started (PID: $!)"
            else
                log_debug "GC already running for $(basename "$PROJECT_PATH"), skipping"
            fi
        else
            gc_stale_worktrees "$PROJECT_PATH" "$AGENT_ID" || log_warn "Opportunistic GC failed (non-fatal)"
        fi
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

    # Validate worktree exists and is well-formed (Fix #221)
    if ! validate_worktree_path "$WORKTREE_PATH" "$SANITIZED_GIT_PATH"; then
        status_complete 1 "Worktree validation failed after creation (Issue #221)"
        _STATUS_COMPLETE_SHOWN=true
        exit 1
    fi
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

    # Issue #276: on macOS the host bind-mount traverses virtio-fs, which can
    # degrade silently (sleep/wake) and make /kapsis-status unwritable at
    # container start. Back /kapsis-status with a per-agent named volume
    # instead — named volumes live inside the Podman VM and are not affected
    # by virtio-fs drops. A host-side sync (see start_status_sync) mirrors
    # the volume into $status_dir so live --watch consumers keep working.
    if is_macos; then
        KAPSIS_STATUS_VOLUME="kapsis-${AGENT_ID}${KAPSIS_STATUS_VOLUME_SUFFIX}"
        VOLUME_MOUNTS+=("-v" "${KAPSIS_STATUS_VOLUME}:/kapsis-status")
    else
        KAPSIS_STATUS_VOLUME=""
        VOLUME_MOUNTS+=("-v" "${status_dir}:/kapsis-status")
    fi

    # Audit directory (shared between host and container)
    if [[ "${KAPSIS_AUDIT_ENABLED:-${KAPSIS_DEFAULT_AUDIT_ENABLED}}" == "true" ]]; then
        local audit_dir="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"
        ensure_dir "$audit_dir"
        VOLUME_MOUNTS+=("-v" "${audit_dir}:${CONTAINER_AUDIT_PATH}")
    fi

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

#-------------------------------------------------------------------------------
# _snapshot_file <host_path> <relative_name>
#
# Creates a point-in-time snapshot of a host file for race-free bind mounting.
# Prevents torn reads when host processes (e.g., Claude Code) actively write to
# files listed in filesystem.include. The container mounts the static snapshot
# instead of the live host file, eliminating the race condition.
#
# Returns: path to snapshot (or original path on failure as fallback)
# See: GitHub issue #164
#-------------------------------------------------------------------------------
_snapshot_file() {
    local host_path="$1"
    local relative_name="$2"

    # SNAPSHOT_DIR must be initialized by the caller (generate_filesystem_includes)
    # before calling this function. This function is called via $() subshell, so
    # any variable assignments here would be lost in the parent shell.

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$host_path"
        return 0
    fi

    local snapshot_path="${SNAPSHOT_DIR}/${relative_name}"

    # Ensure parent directory exists (for paths like .claude/settings.json)
    mkdir -p "$(dirname "$snapshot_path")" 2>/dev/null || true

    # Host-local cp — source is on the local filesystem (not a bind mount), so
    # there is no concurrent-writer torn-read risk at this point
    if cp -p "$host_path" "$snapshot_path" 2>/dev/null; then
        echo "$snapshot_path"
    else
        log_warn "Snapshot failed for ${host_path}, falling back to live mount"
        echo "$host_path"
    fi
}

generate_filesystem_includes() {
    local staging_dir="/kapsis-staging"
    STAGED_CONFIGS=""

    if [[ -n "$FILESYSTEM_INCLUDES" ]]; then
        # Initialize snapshot directory in parent shell scope (issue #164)
        # Must be done here — NOT inside _snapshot_file() — because _snapshot_file
        # is called via $() subshell, and variable assignments in subshells don't
        # propagate back to the parent. Without this, cleanup would never fire.
        # Placed under $HOME/.kapsis/ (NOT /tmp) because macOS /tmp resolves to
        # /private/tmp which is inaccessible from the Podman VM's virtio-fs mount.
        if [[ -z "$SNAPSHOT_DIR" ]]; then
            SNAPSHOT_DIR="${HOME}/.kapsis/snapshots/${AGENT_ID}"
            if [[ "$DRY_RUN" != "true" ]]; then
                mkdir -p "$SNAPSHOT_DIR"
                log_debug "Created snapshot directory: $SNAPSHOT_DIR"
            else
                log_debug "[DRY-RUN] Would create snapshot dir: $SNAPSHOT_DIR"
            fi
        fi

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
            # shellcheck disable=SC2016  # Intentional: matching literal $HOME text, not expanded value
            if [[ "$path" == "~"* ]] || [[ "$path" == *'$HOME'* ]] || [[ "$path" == *'${HOME}'* ]] || [[ "$expanded_path" == "$HOME"* ]]; then
                # Extract relative path (e.g., .claude, .gitconfig)
                relative_path="${expanded_path#"$HOME"/}"
                staging_path="${staging_dir}/${relative_path}"

                # Snapshot regular files to prevent torn reads (issue #164)
                # Directories are left as-is — they use fuse-overlayfs CoW inside the container
                local mount_source="$expanded_path"
                if [[ -f "$expanded_path" ]]; then
                    mount_source=$(_snapshot_file "$expanded_path" "$relative_path")
                    log_debug "Snapshot: ${expanded_path} -> ${mount_source}"
                fi

                # Mount to staging directory (read-only)
                VOLUME_MOUNTS+=("-v" "${mount_source}:${staging_path}:ro")
                log_debug "Staged for copy: ${mount_source} -> ${staging_path}"

                # Track for entrypoint to copy
                if [[ -n "$STAGED_CONFIGS" ]]; then
                    STAGED_CONFIGS="${STAGED_CONFIGS},${relative_path}"
                else
                    STAGED_CONFIGS="${relative_path}"
                fi
            else
                # Non-home absolute paths: snapshot files, mount directly (read-only)
                local mount_source="$expanded_path"
                if [[ -f "$expanded_path" ]]; then
                    mount_source=$(_snapshot_file "$expanded_path" "absolute${expanded_path}")
                    log_debug "Snapshot: ${expanded_path} -> ${mount_source}"
                fi
                VOLUME_MOUNTS+=("-v" "${mount_source}:${expanded_path}:ro")
                log_debug "Direct mount (ro): ${mount_source} -> ${expanded_path}"
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

# Global arrays for environment variables
# ENV_VARS: non-secret variables (visible in dry-run, use -e flags)
# SECRET_ENV_VARS: secret variables (written to temp file, use --env-file)
declare -a ENV_VARS=()
declare -a SECRET_ENV_VARS=()

generate_env_vars() {
    ENV_VARS=()
    SECRET_ENV_VARS=()

    # Pass through environment variables
    # Classify based on variable name (secrets go to SECRET_ENV_VARS)
    if [[ -n "$ENV_PASSTHROUGH" ]]; then
        while IFS= read -r var; do
            [[ -z "$var" ]] && continue
            if [[ -n "${!var:-}" ]]; then
                if is_secret_var_name "$var"; then
                    SECRET_ENV_VARS+=("${var}=${!var}")
                else
                    ENV_VARS+=("-e" "${var}=${!var}")
                fi
            fi
        done <<< "$ENV_PASSTHROUGH"
    fi

    # Process keychain-backed environment variables
    # Track credentials that need file injection (agent-agnostic)
    local CREDENTIAL_FILES=""
    # Track secrets that should be stored in container's Linux secret store
    local SECRET_STORE_ENTRIES=""
    # Track keyring collection mappings for 99designs/keyring compat (Issue #170, #176)
    # Format: VAR_NAME|collection_label|profile (comma-separated)
    local KEYRING_COLLECTIONS=""
    # Track git credential host-to-keyring mappings (Issue #188)
    # Format: host|service|account|keyring_collection|keyring_profile (comma-separated)
    local GIT_CREDENTIAL_MAP=""

    if [[ -n "$ENV_KEYCHAIN" ]]; then
        log_info "Resolving secrets from system keychain..."
        # shellcheck disable=SC2034  # inject_file_template_b64 used in template validation block below
        while IFS='|' read -r var_name service account inject_to_file file_mode inject_to keyring_collection keyring_profile git_credential_for inject_file_template_b64; do
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

            # Skip if already set via passthrough (check both arrays)
            local already_set=false
            if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
                for existing in "${ENV_VARS[@]}"; do
                    if [[ "$existing" == "${var_name}="* ]]; then
                        already_set=true
                        break
                    fi
                done
            fi
            if [[ "$already_set" != "true" && ${#SECRET_ENV_VARS[@]} -gt 0 ]]; then
                for existing in "${SECRET_ENV_VARS[@]}"; do
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

            # Validate inject_to value before proceeding
            if [[ -n "${inject_to:-}" ]] && [[ "$inject_to" != "secret_store" ]] && [[ "$inject_to" != "env" ]]; then
                log_warn "Unknown inject_to value '$inject_to' for $var_name — defaulting to env"
                inject_to="env"
            fi

            # Query secret store (keychain/secret-tool) with fallback account support
            local value
            if value=$(query_secret_store_with_fallbacks "$service" "$account" "$var_name"); then
                # Keychain values are always secrets - add to SECRET_ENV_VARS
                SECRET_ENV_VARS+=("${var_name}=${value}")
                log_success "Loaded $var_name from secret store (service: $service)"

                # Track secret store injection if requested (default: secret_store)
                if [[ "${inject_to:-secret_store}" == "secret_store" ]]; then
                    local ss_entry="${var_name}|${service}|${account:-kapsis}"
                    if [[ -n "$SECRET_STORE_ENTRIES" ]]; then
                        SECRET_STORE_ENTRIES="${SECRET_STORE_ENTRIES},${ss_entry}"
                    else
                        SECRET_STORE_ENTRIES="${ss_entry}"
                    fi
                    log_debug "Will inject $var_name to container secret store"

                    # Track keyring collection for 99designs/keyring compat (Issue #170)
                    # Allowlist validation: only safe characters for D-Bus paths/labels
                    if [[ -n "${keyring_collection:-}" ]]; then
                        if [[ "$keyring_collection" =~ [^a-zA-Z0-9/.@:_-] ]]; then
                            log_warn "keyring_collection for $var_name contains invalid characters — ignoring"
                            keyring_collection=""
                        fi
                    fi
                    # Validate keyring_profile (Issue #176)
                    if [[ -n "${keyring_profile:-}" ]]; then
                        if [[ "$keyring_profile" =~ [^a-zA-Z0-9/.@:_-] ]]; then
                            log_warn "keyring_profile for $var_name contains invalid characters — ignoring"
                            keyring_profile=""
                        fi
                    fi
                    if [[ -n "${keyring_collection:-}" ]]; then
                        local kc_entry="${var_name}|${keyring_collection}|${keyring_profile:-}"
                        KEYRING_COLLECTIONS="${KEYRING_COLLECTIONS:+${KEYRING_COLLECTIONS},}${kc_entry}"
                        log_debug "Will use collection '$keyring_collection' for $var_name${keyring_profile:+ (profile: $keyring_profile)}"
                    elif [[ -n "${keyring_profile:-}" ]]; then
                        log_warn "keyring_profile for $var_name ignored — requires keyring_collection to be set"
                    fi
                fi

                # Track git credential mapping if specified (Issue #188)
                if [[ -n "${git_credential_for:-}" ]]; then
                    if [[ "$git_credential_for" =~ [^a-zA-Z0-9._-] ]]; then
                        log_warn "git_credential_for for $var_name contains invalid characters — ignoring"
                    else
                        local gc_entry="${git_credential_for}|${service}|${account:-}|${keyring_collection:-}|${keyring_profile:-}"
                        GIT_CREDENTIAL_MAP="${GIT_CREDENTIAL_MAP:+${GIT_CREDENTIAL_MAP},}${gc_entry}"
                        log_debug "Git credential mapping: ${git_credential_for} -> $service"
                    fi
                fi

                # Track file injection if specified (orthogonal to inject_to)
                if [[ -n "$inject_to_file" ]]; then
                    # Format: VAR_NAME|file_path|mode (comma-separated list)
                    if [[ -n "$CREDENTIAL_FILES" ]]; then
                        CREDENTIAL_FILES="${CREDENTIAL_FILES},${var_name}|${inject_to_file}|${file_mode:-0600}"
                    else
                        CREDENTIAL_FILES="${var_name}|${inject_to_file}|${file_mode:-0600}"
                    fi
                    log_debug "Will inject $var_name to file: $inject_to_file"
                fi

                # Validate and pass inject_file_template if specified (Issue #241)
                if [[ -n "${inject_file_template_b64:-}" ]]; then
                    # Template requires inject_to_file — fail-loud if absent
                    if [[ -z "$inject_to_file" ]]; then
                        log_error "inject_file_template for $var_name requires inject_to_file to be set"
                        exit 1
                    fi

                    # Decode template for validation (yq already base64-encoded it)
                    local template_raw
                    if ! template_raw=$(printf '%s' "$inject_file_template_b64" | base64 -d 2>/dev/null); then
                        log_error "Failed to decode inject_file_template for $var_name"
                        exit 1
                    fi

                    # Skip empty templates (field is base64("") when not specified)
                    if [[ -n "$template_raw" ]]; then
                        # Reject NUL bytes (would corrupt template substitution)
                        # Bash variables silently strip NUL, so [[ == *$'\0'* ]]
                        # always matches (Bug #251). Compare raw byte count from
                        # the base64 stream against NUL-stripped count instead.
                        local raw_byte_count clean_byte_count
                        raw_byte_count=$(printf '%s' "$inject_file_template_b64" | base64 -d 2>/dev/null | wc -c)
                        clean_byte_count=$(printf '%s' "$inject_file_template_b64" | base64 -d 2>/dev/null | tr -d '\0' | wc -c)
                        if (( raw_byte_count != clean_byte_count )); then
                            log_error "inject_file_template for $var_name contains NUL bytes"
                            exit 1
                        fi

                        # Enforce 64 KB pre-encoding size cap
                        local template_len=${#template_raw}
                        if (( template_len > 65536 )); then
                            log_error "inject_file_template for $var_name exceeds 64 KB limit (${template_len} bytes)"
                            exit 1
                        fi

                        # Require {{VALUE}} marker — a template without one is always a misconfiguration
                        if [[ "$template_raw" != *'{{VALUE}}'* ]]; then
                            log_error "inject_file_template for $var_name missing required {{VALUE}} placeholder"
                            exit 1
                        fi

                        # Cap {{VALUE}} marker count to prevent heap amplification
                        local marker_count=0
                        local _marker_tmp="$template_raw"
                        while [[ "$_marker_tmp" == *'{{VALUE}}'* ]]; do
                            _marker_tmp="${_marker_tmp#*\{\{VALUE\}\}}"
                            ((marker_count++)) || true
                        done
                        if (( marker_count > 5 )); then
                            log_error "inject_file_template for $var_name has $marker_count {{VALUE}} markers (max 5)"
                            exit 1
                        fi

                        # Warn if secret value itself contains {{VALUE}} (safe for single-pass
                        # bash parameter expansion, but surprising if mechanism ever changes)
                        if [[ "$value" == *'{{VALUE}}'* ]]; then
                            log_warn "Secret value for $var_name contains literal '{{VALUE}}' — substitution is single-pass"
                        fi

                        # Pass template to container via env-file (avoids ARG_MAX limits)
                        SECRET_ENV_VARS+=("KAPSIS_TMPL_${var_name}=${inject_file_template_b64}")
                        log_debug "Will apply template for $var_name (${template_len} bytes)"
                    fi
                fi
            else
                log_warn "Secret not found: $service (for $var_name)"
            fi
        done <<< "$ENV_KEYCHAIN"
    fi

    # Pass credential file injection metadata to entrypoint (agent-agnostic)
    # This is metadata about file paths, not the secrets themselves
    if [[ -n "$CREDENTIAL_FILES" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CREDENTIAL_FILES=${CREDENTIAL_FILES}")
    fi

    # Pass secret store injection metadata to entrypoint
    # Secrets with inject_to: "secret_store" will be moved from env vars to Linux keyring
    if [[ -n "$SECRET_STORE_ENTRIES" ]]; then
        ENV_VARS+=("-e" "KAPSIS_SECRET_STORE_ENTRIES=${SECRET_STORE_ENTRIES}")
    fi

    # Pass keyring collection mappings for 99designs/keyring compat (Issue #170)
    if [[ -n "$KEYRING_COLLECTIONS" ]]; then
        ENV_VARS+=("-e" "KAPSIS_KEYRING_COLLECTIONS=${KEYRING_COLLECTIONS}")
    fi

    # Pass git credential host-to-keyring mappings (Issue #188)
    if [[ -n "$GIT_CREDENTIAL_MAP" ]]; then
        ENV_VARS+=("-e" "KAPSIS_GIT_CREDENTIAL_MAP_DATA=${GIT_CREDENTIAL_MAP}")
    fi

    # Set explicit environment variables (non-secrets)
    ENV_VARS+=("-e" "KAPSIS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_SANDBOX_MODE=${SANDBOX_MODE}")

    # Status reporting environment variables (for container to update status)
    ENV_VARS+=("-e" "KAPSIS_STATUS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_STATUS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_STATUS_BRANCH=${BRANCH:-}")
    ENV_VARS+=("-e" "KAPSIS_INJECT_GIST=${INJECT_GIST:-false}")
    ENV_VARS+=("-e" "KAPSIS_GIST_LLM=${GIST_LLM:-false}")
    ENV_VARS+=("-e" "KAPSIS_GIST_LLM_INTERVAL=${GIST_LLM_INTERVAL:-60}")

    # Audit environment variables
    if [[ "${KAPSIS_AUDIT_ENABLED:-${KAPSIS_DEFAULT_AUDIT_ENABLED}}" == "true" ]]; then
        ENV_VARS+=("-e" "KAPSIS_AUDIT_ENABLED=true")
        ENV_VARS+=("-e" "KAPSIS_AUDIT_DIR=${CONTAINER_AUDIT_PATH}")
    fi

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

    # Fix #213: explicit agent.type from YAML config overrides filename inference
    if [[ "$agent_type" == "unknown" && -n "${AGENT_CONFIG_TYPE:-}" ]]; then
        local config_type
        config_type=$(normalize_agent_type "$AGENT_CONFIG_TYPE")
        if [[ "$config_type" != "unknown" ]]; then
            agent_type="$config_type"
            log_debug "Agent type from config agent.type: $agent_type"
        fi
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

    # Fix #213: infer from agent command string as last resort
    if [[ "$agent_type" == "unknown" && -n "${AGENT_COMMAND:-}" ]]; then
        case "$AGENT_COMMAND" in
            claude\ *|*\ claude\ *|*/claude\ *)   agent_type="claude-cli" ;;
            codex\ *|*\ codex\ *|*/codex\ *)      agent_type="codex-cli" ;;
            gemini\ *|*\ gemini\ *|*/gemini\ *)    agent_type="gemini-cli" ;;
            aider\ *|*\ aider\ *|*/aider\ *)      agent_type="aider" ;;
        esac
        if [[ "$agent_type" != "unknown" ]]; then
            log_debug "Inferred agent type from command: $agent_type"
        fi
    fi

    ENV_VARS+=("-e" "KAPSIS_AGENT_TYPE=${agent_type}")
    log_debug "Agent type for status tracking: $agent_type"

    # Attribution templates (commit trailer + PR description).
    # - Claude Code (claude-cli): inject-status-hooks.sh writes these into
    #   ~/.claude/settings.local.json so Claude Code uses them natively.
    # - Other agents: entrypoint.sh and host-side post-container-git.sh read
    #   KAPSIS_ATTRIBUTION_COMMIT and append it to commit messages directly.
    # Empty string disables attribution (Claude Code honors this explicitly).
    #
    # Resolve {worktree} placeholder now that WORKTREE_PATH is available.
    local worktree_basename
    worktree_basename="$(basename "${WORKTREE_PATH:-workspace}")"
    GIT_ATTRIBUTION_COMMIT="${GIT_ATTRIBUTION_COMMIT//\{worktree\}/$worktree_basename}"
    GIT_ATTRIBUTION_PR="${GIT_ATTRIBUTION_PR//\{worktree\}/$worktree_basename}"

    ENV_VARS+=("-e" "KAPSIS_ATTRIBUTION_COMMIT=${GIT_ATTRIBUTION_COMMIT:-}")
    ENV_VARS+=("-e" "KAPSIS_ATTRIBUTION_PR=${GIT_ATTRIBUTION_PR:-}")
    # Export for host-side post-container-git.sh (sourced later in same process).
    export KAPSIS_ATTRIBUTION_COMMIT="${GIT_ATTRIBUTION_COMMIT:-}"
    export KAPSIS_ATTRIBUTION_PR="${GIT_ATTRIBUTION_PR:-}"
    export KAPSIS_AGENT_TYPE="${agent_type}"

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
        # Pass remote branch name when different from local
        if [[ -n "$REMOTE_BRANCH" ]]; then
            ENV_VARS+=("-e" "KAPSIS_REMOTE_BRANCH=${REMOTE_BRANCH}")
        fi
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

    # Pass host HOME for plugin path rewriting inside container (Issue #217)
    # Plugin paths in installed_plugins.json contain host-absolute paths
    # that need to be rewritten to container HOME
    ENV_VARS+=("-e" "KAPSIS_HOST_HOME=${HOME}")

    # Pass Claude config whitelist filters
    if [[ -n "${CLAUDE_HOOKS_INCLUDE:-}" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CLAUDE_HOOKS_INCLUDE=${CLAUDE_HOOKS_INCLUDE}")
    fi
    if [[ -n "${CLAUDE_MCP_INCLUDE:-}" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CLAUDE_MCP_INCLUDE=${CLAUDE_MCP_INCLUDE}")
    fi

    # Pass LSP server configuration as JSON
    if [[ -n "${LSP_SERVERS_JSON:-}" && "${LSP_SERVERS_JSON:-}" != "{}" ]]; then
        ENV_VARS+=("-e" "KAPSIS_LSP_SERVERS_JSON=${LSP_SERVERS_JSON}")
    fi

    # Liveness monitoring env vars (Issue #257: enabled by default)
    if [[ "${LIVENESS_ENABLED:-true}" == "true" ]]; then
        ENV_VARS+=("-e" "KAPSIS_LIVENESS_ENABLED=true")
        ENV_VARS+=("-e" "KAPSIS_LIVENESS_TIMEOUT=${LIVENESS_TIMEOUT:-900}")
        ENV_VARS+=("-e" "KAPSIS_LIVENESS_GRACE_PERIOD=${LIVENESS_GRACE_PERIOD:-300}")
        ENV_VARS+=("-e" "KAPSIS_LIVENESS_CHECK_INTERVAL=${LIVENESS_CHECK_INTERVAL:-30}")
        ENV_VARS+=("-e" "KAPSIS_LIVENESS_COMPLETION_TIMEOUT=${LIVENESS_COMPLETION_TIMEOUT:-120}")
    fi

    # Mount check env vars (Issue #248) — independent of liveness enabled
    if [[ "${MOUNT_CHECK_ENABLED:-false}" == "true" ]]; then
        ENV_VARS+=("-e" "KAPSIS_MOUNT_CHECK_ENABLED=true")
        ENV_VARS+=("-e" "KAPSIS_MOUNT_CHECK_RETRIES=${MOUNT_CHECK_RETRIES:-2}")
        ENV_VARS+=("-e" "KAPSIS_MOUNT_CHECK_RETRY_DELAY=${MOUNT_CHECK_RETRY_DELAY:-5}")
        ENV_VARS+=("-e" "KAPSIS_MOUNT_CHECK_PROBE_TIMEOUT=${MOUNT_CHECK_PROBE_TIMEOUT:-5}")
        ENV_VARS+=("-e" "KAPSIS_MOUNT_CHECK_DELAY=${MOUNT_CHECK_DELAY:-30}")
    fi

    # Fix hang-after-completion for Claude agents (anthropics/claude-code#21099)
    # This env var tells Claude CLI to exit after the Stop event when stdout is piped
    # agent_type is set earlier in this function from AGENT_NAME or image inference
    if [[ "$agent_type" == "claude-cli" || "$agent_type" == "claude" || "$agent_type" == "claude-code" ]]; then
        ENV_VARS+=("-e" "CLAUDE_CODE_EXIT_AFTER_STOP_DELAY=${CLAUDE_CODE_EXIT_AFTER_STOP_DELAY:-10000}")
    fi

    # Process explicit set environment variables from config
    # Classify based on variable name (secrets go to SECRET_ENV_VARS)
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
                    if is_secret_var_name "$key"; then
                        SECRET_ENV_VARS+=("${key}=${value}")
                    else
                        ENV_VARS+=("-e" "${key}=${value}")
                    fi
                fi
            done <<< "$set_vars"
        fi
    fi
}

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
    local old_umask
    old_umask=$(umask)
    umask 0077
    if ! SECRETS_ENV_FILE=$(mktemp "${TMPDIR:-/tmp}/kapsis-secrets-XXXXXX" 2>/dev/null); then
        umask "$old_umask"
        log_warn "Cannot create secrets env-file in /tmp - falling back to inline env vars"
        log_warn "Secrets may be visible in debug traces (bash -x) or process listings"
        # Fallback: add secrets as inline -e flags (current behavior)
        for secret_entry in "${SECRET_ENV_VARS[@]}"; do
            ENV_VARS+=("-e" "$secret_entry")
        done
        SECRET_ENV_VARS=()  # Clear to prevent double-adding
        return 0
    fi
    umask "$old_umask"

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
    # Validate security configuration before building command
    if ! validate_security_config; then
        log_error "Security configuration validation failed"
        exit 1
    fi

    CONTAINER_CMD=(
        "podman" "run"
        "--rm"
        "--name" "kapsis-${AGENT_ID}"
        "--hostname" "kapsis-${AGENT_ID}"
        # Label (Issue #276 review, #5): count_running_kapsis_containers
        # filters by this label instead of the name prefix, so unrelated
        # user containers named "kapsis-*" cannot stall auto-heal.
        "--label" "kapsis.managed=true"
        "--label" "kapsis.agent-id=${AGENT_ID}"
    )

    # Add TTY flags only for interactive mode
    # -i (stdin open) causes hangs when piping through tee for non-interactive runs
    if [[ "$INTERACTIVE" == "true" ]]; then
        if [[ -t 0 ]] && [[ -t 1 ]]; then
            CONTAINER_CMD+=("-it")
        else
            CONTAINER_CMD+=("-i")
        fi
    fi
    # Non-interactive: no -i or -t flags needed, container runs detached from stdin

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

            # DNS IP Pinning: resolve domains on host and pin IPs in container
            # This prevents DNS manipulation attacks inside the container
            if [[ "${NETWORK_DNS_PIN_ENABLED:-true}" == "true" ]] && [[ -n "${NETWORK_ALLOWLIST_DOMAINS:-}" ]]; then
                log_info "DNS pinning: resolving allowlist domains on host..."
                local resolved_data dns_metrics_file
                dns_metrics_file=$(mktemp)
                if resolved_data=$(resolve_allowlist_domains "$NETWORK_ALLOWLIST_DOMAINS" "${NETWORK_DNS_PIN_TIMEOUT:-5}" "${NETWORK_DNS_PIN_FALLBACK:-dynamic}" "$dns_metrics_file"); then
                    # Abort if too many domains failed to resolve (Issue #216)
                    local _dns_resolved _dns_failed _dns_wildcards
                    read -r _dns_resolved _dns_failed _dns_wildcards < "$dns_metrics_file" 2>/dev/null || true
                    rm -f "$dns_metrics_file"
                    if ! check_dns_failure_threshold \
                            "${_dns_resolved:-0}" "${_dns_failed:-0}" \
                            "${NETWORK_DNS_PIN_MAX_FAILURE_RATE:-}" \
                            "${NETWORK_DNS_PIN_MAX_FAILURES:-}"; then
                        exit 1
                    fi

                    if [[ -n "$resolved_data" ]]; then
                        # Create temp file for pinned DNS (cleaned up in _cleanup_with_completion)
                        DNS_PIN_FILE=$(mktemp)
                        if write_pinned_dns_file "$DNS_PIN_FILE" "$resolved_data"; then
                            local pinned_count
                            pinned_count=$(count_pinned_domains "$DNS_PIN_FILE")
                            log_success "DNS pinning: pinned $pinned_count domain(s)"

                            # Mount pinned file read-only in container
                            CONTAINER_CMD+=("-v" "${DNS_PIN_FILE}:/etc/kapsis/pinned-dns.conf:ro")

                            # Generate --add-host flags for belt-and-suspenders protection
                            local add_host_args
                            mapfile -t add_host_args < <(generate_add_host_args "$DNS_PIN_FILE")
                            if [[ ${#add_host_args[@]} -gt 0 ]]; then
                                CONTAINER_CMD+=("${add_host_args[@]}")
                            fi

                            # Tell container that pinning is enabled
                            CONTAINER_CMD+=("-e" "KAPSIS_DNS_PIN_ENABLED=true")
                        fi
                    fi
                else
                    rm -f "$dns_metrics_file"
                    if [[ "${NETWORK_DNS_PIN_FALLBACK:-dynamic}" == "abort" ]]; then
                        log_error "DNS pinning failed with fallback=abort - aborting container launch"
                        exit 1
                    fi
                    log_warn "DNS pinning failed - continuing with dynamic DNS (degraded security)"
                fi
            fi

            # Mount resolv.conf from host as read-only (truly immutable from container)
            # This prevents the agent from modifying DNS configuration even if dnsmasq is killed
            RESOLV_CONF_FILE=$(mktemp "${TMPDIR:-/tmp}/kapsis-resolv-XXXXXX")
            cat > "$RESOLV_CONF_FILE" <<'RESOLV_EOF'
# Kapsis DNS Filter - managed by host (read-only mount)
nameserver 127.0.0.1
RESOLV_EOF
            chmod 444 "$RESOLV_CONF_FILE"
            CONTAINER_CMD+=("-v" "${RESOLV_CONF_FILE}:/etc/resolv.conf:ro")
            CONTAINER_CMD+=("-e" "KAPSIS_RESOLV_CONF_MOUNTED=true")

            # Protect DNS files inside container
            if [[ "${NETWORK_DNS_PIN_PROTECT:-true}" == "true" ]]; then
                CONTAINER_CMD+=("-e" "KAPSIS_DNS_PIN_PROTECT_FILES=true")
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
        CONTAINER_CMD+=("-e" "KAPSIS_LOG_LEVEL=WARN")
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

    # Add environment variables (non-secrets via -e flags)
    CONTAINER_CMD+=("${ENV_VARS[@]}")

    # Add secrets via --env-file (prevents exposure in bash -x traces and process listings)
    if [[ -n "${SECRETS_ENV_FILE:-}" && -f "$SECRETS_ENV_FILE" ]]; then
        CONTAINER_CMD+=("--env-file" "$SECRETS_ENV_FILE")
    fi

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
# POST-CONTAINER: VOLUME CLEANUP (Fix #191)
#===============================================================================

# Remove per-agent build cache volumes after session completion
cleanup_agent_volumes() {
    local agent_id="$1"
    local removed=0

    # Build the suffix list: "-status" is macOS-only because that's the only
    # platform where we back /kapsis-status with a named volume (Issue #276).
    # On Linux the bind mount is used and the -status volume never exists,
    # so attempting to `podman volume rm` it is just noise.
    local suffixes=(m2 gradle ge)
    if is_macos; then
        suffixes+=(status)
    fi

    for suffix in "${suffixes[@]}"; do
        local vol="kapsis-${agent_id}-${suffix}"
        if podman volume rm "$vol" &>/dev/null; then
            log_debug "Removed volume: $vol"
            ((removed++)) || true
        fi
    done

    if (( removed > 0 )); then
        log_info "Cleaned up $removed build cache volume(s) for agent $agent_id"
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================
main() {
    # Initialize progress display (must be early for trap registration)
    display_init

    # Track if we've shown completion message (to avoid duplicate on normal exit)
    _DISPLAY_COMPLETE_SHOWN=false
    # Track if status_complete has been called (to avoid orphaned status on abnormal exit)
    _STATUS_COMPLETE_SHOWN=false

    # Track temp file for cleanup on signal (set later when container runs)
    _CONTAINER_OUTPUT_TMP=""

    # PID of caffeinate background process (macOS sleep prevention, Issue #276).
    # Set after caffeinate is started; cleared after it is killed.
    _CAFFEINATE_PID=""

    # PID of vfkit watchdog subshell (Issue #303). macOS-only; empty when
    # disabled or vfkit not found. Cleaned up in _cleanup_with_completion.
    _VFKIT_WATCHDOG_PID=""

    # Host-only sentinel path written by the watchdog when vfkit exits.
    # Lives under $TMPDIR which is host-private on macOS — NOT bind-mounted
    # into the container. The post-container override requires this file
    # AS WELL AS status.json's mount_failure entry, so a compromised agent
    # inside the container cannot forge a mount_failure exit.
    _VFKIT_FIRED_SENTINEL=""

    # Cleanup function that ensures completion message is shown
    # shellcheck disable=SC2329  # Function is invoked via trap on line 1565
    _cleanup_with_completion() {
        local exit_code=$?
        # Clean up temp files if they exist
        [[ -n "$_CONTAINER_OUTPUT_TMP" ]] && rm -f "$_CONTAINER_OUTPUT_TMP"
        # Stop macOS sleep prevention if active (Issue #276).
        if [[ -n "$_CAFFEINATE_PID" ]]; then
            kill "$_CAFFEINATE_PID" 2>/dev/null || true
            _CAFFEINATE_PID=""
        fi
        # Stop vfkit watchdog if active (Issue #303). Killed before
        # backend_cleanup so a stale watchdog cannot SIGTERM the agent's
        # `podman run` after the container has already exited normally.
        # `wait` drains the subshell so any in-flight `_status_write` finishes
        # before this trap runs `status_complete` again — without it, a
        # `${status}.tmp.$$` from the watchdog can leak.
        if [[ -n "${_VFKIT_WATCHDOG_PID:-}" ]]; then
            kill "$_VFKIT_WATCHDOG_PID" 2>/dev/null || true
            wait "$_VFKIT_WATCHDOG_PID" 2>/dev/null || true
            _VFKIT_WATCHDOG_PID=""
        fi
        # Clean up the host-only watchdog sentinel. The override has already
        # consumed it by this point; leaving it would not affect this run,
        # but cleaning it prevents a leftover from confusing a future agent
        # run with the same AGENT_ID (resume mode).
        if [[ -n "${_VFKIT_FIRED_SENTINEL:-}" ]]; then
            rm -f "$_VFKIT_FIRED_SENTINEL" 2>/dev/null || true
        fi
        # Stop host-side status volume sync and flush one final snapshot to
        # the host status dir so post-exit consumers see the definitive state
        # (Issue #276). No-op when KAPSIS_STATUS_VOLUME is unset.
        if [[ -n "${KAPSIS_STATUS_VOLUME:-}" ]]; then
            stop_status_sync "${AGENT_ID:-}" "$KAPSIS_STATUS_VOLUME" \
                "${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}" 2>/dev/null || true
        fi
        # Delegate backend-specific cleanup (secrets env file, inline spec, dns pin, etc.)
        backend_cleanup 2>/dev/null || true
        # Ensure status transitions to 'complete' on abnormal exit (Fix #168)
        if [[ "$_STATUS_COMPLETE_SHOWN" != "true" ]]; then
            if [[ $exit_code -eq 0 ]]; then
                status_complete 0 2>/dev/null || true
            else
                status_complete "$exit_code" "Exited with code $exit_code" 2>/dev/null || true
            fi
        fi
        # Show completion message if not already shown
        if [[ "$_DISPLAY_COMPLETE_SHOWN" != "true" ]]; then
            if [[ $exit_code -eq 0 ]]; then
                display_complete 0
            else
                display_complete "$exit_code" "" "Exited with code $exit_code"
            fi
        fi
        display_cleanup
        # CRITICAL: Preserve original exit code - EXIT trap's return value becomes script's exit status
        return "$exit_code"
    }

    # Cleanup display on exit (restore cursor visibility, etc.)
    trap '_cleanup_with_completion' EXIT
    trap 'display_cleanup' INT TERM

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
    validate_agent_command "$AGENT_COMMAND"
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
            _STATUS_COMPLETE_SHOWN=true
            exit 1
        fi
        log_timer_end "preflight"
        status_phase "initializing" 15 "Pre-flight check passed"
    fi

    # Setup sandbox (worktree/overlay) — only for backends that support it
    if backend_supports "worktree" || backend_supports "overlay"; then
        log_timer_start "sandbox_setup"
        setup_sandbox
        log_timer_end "sandbox_setup"
    else
        log_info "Backend '$BACKEND' handles sandbox setup in-cluster"
    fi

    # Update status with sandbox mode and worktree path now that we know them
    status_init "$project_name" "$AGENT_ID" "$BRANCH" "$SANDBOX_MODE" "${WORKTREE_PATH:-}"
    status_phase "preparing" 18 "Sandbox ready"

    # Podman-specific: generate volume mounts, env vars, secrets env-file
    # K8s backend generates its own CR with this info
    if [[ "$BACKEND" == "podman" ]]; then
        generate_volume_mounts
        generate_env_vars
        write_secrets_env_file
    fi
    backend_build_spec
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

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$BACKEND" != "podman" ]]; then
            # Non-podman backends handle dry-run output in backend_build_spec()
            echo ""
            exit 0
        fi

        log_info "DRY RUN - Command that would be executed:"
        echo ""
        # Sanitize secrets as defense-in-depth (secrets normally go via --env-file,
        # but fallback path may add them as inline -e flags)
        sanitize_secrets "${CONTAINER_CMD[*]}"

        # Show secrets env-file info if secrets were configured
        if [[ ${#SECRET_ENV_VARS[@]} -gt 0 ]]; then
            echo ""
            # List secret variable names (not values) for visibility
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
    fi

    echo "┌────────────────────────────────────────────────────────────────────┐"
    printf "│ LAUNCHING %-56s │\n" "$(to_upper "$AGENT_NAME")"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Pre-launch virtio-fs health probe (Issue #276, macOS only).
    # Fails the launch fast with exit code 4 (KAPSIS_EXIT_MOUNT_FAILURE) when
    # virtio-fs is degraded and cannot be auto-healed. Skipped for Linux, K8s,
    # and probe/dry-run paths where no real container will be started.
    if [[ "$BACKEND" == "podman" ]] && is_macos \
       && [[ "${KAPSIS_VFS_PROBE_ENABLED:-true}" == "true" ]]; then
        log_timer_start "vfs_probe"
        # H3 fix: expose the project path so probe_virtio_fs_health tests the /Users
        # virtio-fs mount instead of $TMPDIR (/var/folders), which is a different
        # transport in the Podman VM. Without this, a degraded /Users mount passes
        # the pre-launch probe silently.
        # Worktree mode: use WORKTREE_PATH (inside ~/.kapsis/worktrees/).
        # Overlay mode: use PROJECT_PATH (the source repo on /Users).
        if [[ -n "${WORKTREE_PATH:-}" ]]; then
            export KAPSIS_WORKTREE_PATH="$WORKTREE_PATH"
        elif [[ -n "${PROJECT_PATH:-}" ]]; then
            export KAPSIS_WORKTREE_PATH="$PROJECT_PATH"
        fi
        if ! maybe_autoheal_podman_vm; then
            # Emit the tagged sentinel to stderr so any log-scraping caller
            # sees the same signal as from in-container failures. (Host code
            # sets EXIT_CODE=4 directly below — the sentinel is informational.)
            log_error "KAPSIS_MOUNT_FAILURE[probe_virtio_fs_health]: virtio-fs degraded at launch — aborting before container start"
            # status.json: explicit error_type so slack-bot / --watch consumers
            # can treat this as retriable infra, not an agent bug.
            status_set_error_type "mount_failure"
            status_complete "$KAPSIS_EXIT_MOUNT_FAILURE" \
                "Virtio-fs degraded at launch (Issue #276). Recovery: podman machine stop && podman machine start, then re-run."
            _STATUS_COMPLETE_SHOWN=true
            exit "$KAPSIS_EXIT_MOUNT_FAILURE"
        fi
        log_timer_end "vfs_probe"
    fi

    # macOS sleep prevention (Issue #276): prevent idle/system sleep while the
    # agent is running so virtio-fs is never disrupted by a host sleep event.
    # caffeinate -i prevents idle sleep; -s prevents system sleep.
    # Controlled by the 'prevent_sleep' config key or KAPSIS_PREVENT_SLEEP env var.
    if [[ "$BACKEND" == "podman" ]] && is_macos \
       && [[ "${KAPSIS_PREVENT_SLEEP:-${KAPSIS_DEFAULT_PREVENT_SLEEP:-true}}" == "true" ]]; then
        caffeinate -i -s &
        _CAFFEINATE_PID=$!
        log_debug "Sleep prevention active (caffeinate PID: $_CAFFEINATE_PID)"
    fi

    # vfkit watchdog (Issue #303): host-side ≤10s detection of virtio-fs
    # drops. Implementation lives in scripts/lib/vfkit-watchdog.sh so the
    # body is shared with tests. Sets _VFKIT_WATCHDOG_PID on success.
    # Skipped automatically on Linux, when disabled, or when vfkit is not
    # found.
    if [[ "$BACKEND" == "podman" ]]; then
        # Compute and pre-clean the host-only sentinel path. The watchdog
        # subshell will create this file when vfkit exits; the override
        # block requires its presence to upgrade EXIT_CODE (see Issue #303
        # ensemble review #2 — defense against in-container forgery of
        # status.json mount_failure entries).
        _VFKIT_FIRED_SENTINEL="${TMPDIR:-/tmp}/kapsis-${AGENT_ID}.vfkit-fired"
        rm -f "$_VFKIT_FIRED_SENTINEL" 2>/dev/null || true
        start_vfkit_watchdog "$AGENT_ID" "" "" "$_VFKIT_FIRED_SENTINEL"
    fi

    # Display progress header (shows sandbox ready status with timer)
    display_header "$AGENT_ID" "$BRANCH" "$NETWORK_MODE"

    log_info "Starting container..."
    # Note: Secret sanitization is handled by _log()
    log_debug "Container command: ${CONTAINER_CMD[*]}"
    log_timer_start "container"
    status_phase "starting" 22 "Launching container"

    # Start host-side sync of the /kapsis-status named volume (macOS only).
    # No-op on Linux where /kapsis-status is a direct bind mount and on K8s
    # where KAPSIS_STATUS_VOLUME is never set. Registered BEFORE backend_run so
    # the EXIT trap's stop_status_sync call always has a consistent pair.
    if [[ -n "${KAPSIS_STATUS_VOLUME:-}" ]]; then
        start_status_sync "$AGENT_ID" "$KAPSIS_STATUS_VOLUME" \
            "${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"
    fi

    # Create temp file to capture output for error reporting and logging
    # Store in global for cleanup on signal (see _cleanup_with_completion)
    local container_output
    container_output=$(mktemp)
    _CONTAINER_OUTPUT_TMP="$container_output"
    CONTAINER_ERROR_OUTPUT=""

    # Run the container via backend
    backend_run "$container_output"
    EXIT_CODE=$(backend_get_exit_code)

    log_timer_end "container"
    log_info "Container exited with code: $EXIT_CODE"

    # Drain the host-side status sync now so post-container logic (sentinel
    # detection, status_get_exit_code) reads the container's final state from
    # the host dir, not a stale cached snapshot (Issue #276).
    if [[ -n "${KAPSIS_STATUS_VOLUME:-}" ]]; then
        stop_status_sync "$AGENT_ID" "$KAPSIS_STATUS_VOLUME" \
            "${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}" 2>/dev/null || true
        # Prevent _cleanup_with_completion from re-running the stop (idempotent
        # stop_status_sync would be a no-op anyway, but this avoids a duplicate
        # `podman volume export` at exit-time).
        KAPSIS_STATUS_VOLUME=""
    fi

    # Log full container output to log file for debugging
    if [[ -f "$container_output" ]] && [[ -s "$container_output" ]]; then
        log_debug "=== Container output start ==="
        while IFS= read -r line; do
            # Strip ANSI codes for log file (sed required for ANSI escape regex)
            local clean_line
            # shellcheck disable=SC2001
            clean_line=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
            log_debug "  $clean_line"
        done < "$container_output"
        log_debug "=== Container output end ==="
    fi

    # On error, capture specific error lines for display
    if [[ "$EXIT_CODE" -ne 0 ]] && [[ -f "$container_output" ]] && [[ -s "$container_output" ]]; then
        # Strip ANSI codes and get relevant error lines
        local stripped_output
        stripped_output=$(sed 's/\x1b\[[0-9;]*m//g' "$container_output")

        # Try to find ERROR lines or common error patterns (grep returns 1 if no matches)
        CONTAINER_ERROR_OUTPUT=$(echo "$stripped_output" | grep -E '\[ERROR\]|SECURITY:|unbound variable|command not found|Permission denied' | head -10 || true)

        # If no specific error lines, get the last 10 lines
        if [[ -z "$CONTAINER_ERROR_OUTPUT" ]]; then
            CONTAINER_ERROR_OUTPUT=$(echo "$stripped_output" | tail -10)
            log_debug "No specific error patterns found, using last 10 lines"
        else
            log_debug "Found error patterns in container output"
        fi
        log_debug "CONTAINER_ERROR_OUTPUT: $CONTAINER_ERROR_OUTPUT"
    fi

    # Check for mount failure sentinel in container output (Issues #248, #276)
    #
    # Pattern (post-review): tagged form `KAPSIS_MOUNT_FAILURE[<subsystem>]:`
    # where <subsystem> is one of: probe_mount_readiness, liveness_monitor,
    # probe_virtio_fs_health. This anchored format and the restriction of the
    # grep to the last 10 lines of container output defend against agents that
    # log "KAPSIS_MOUNT_FAILURE:" somewhere in their own diagnostics.
    #
    # Accepted exit codes:
    #  - 143 / 137: signal kills (SIGTERM / SIGKILL) from the in-container
    #               liveness monitor (scripts/lib/liveness-monitor.sh)
    # Exit 0 is never overridden, preserving the security property that a
    # compromised agent cannot upgrade a clean success into a mount failure.
    # Exit 1 is intentionally excluded: probe_mount_readiness exits 4 directly
    # on failure (not 1), so exit-1 + sentinel cannot occur in legitimate code;
    # accepting it would widen the spoofing surface for compromised agents.
    local _MOUNT_SENTINEL_PATTERN='^(\[[^]]*\])?[[:space:]]*(\x1b\[[0-9;]*m)?(\[[A-Z]+\][[:space:]]+)?KAPSIS_MOUNT_FAILURE\[(probe_mount_readiness|liveness_monitor|probe_virtio_fs_health)\]:'
    if [[ "$EXIT_CODE" -eq 143 || "$EXIT_CODE" -eq 137 ]]; then
        if [[ -f "$container_output" ]] \
           && tail -n 10 "$container_output" 2>/dev/null \
              | grep -Eq "$_MOUNT_SENTINEL_PATTERN" ; then
            log_warn "Mount failure detected via sentinel — overriding exit code to 4"
            EXIT_CODE=4
        fi
    fi

    # Check for hung-after-completion in status.json (Issue #257)
    # When liveness monitor kills AND agent had completed work, exit_code 5 is in status.json
    if [[ "$EXIT_CODE" -eq 143 || "$EXIT_CODE" -eq 137 ]]; then
        local status_exit
        status_exit=$(status_get_exit_code 2>/dev/null || echo "")
        if [[ "$status_exit" == "5" ]]; then
            log_warn "Agent completed but process hung (exit code 5 from liveness monitor)"
            EXIT_CODE=5
        fi
    fi

    # Check for vfkit watchdog mount failure (Issue #303).
    #
    # Trust model (post ensemble review #2):
    #
    # The override requires THREE conditions, all-or-nothing:
    #   1. EXIT_CODE != 0   — exit 0 is preserved (legitimate completion
    #      before vfkit died must not be retroactively rewritten).
    #   2. _VFKIT_FIRED_SENTINEL exists on the HOST filesystem at a path
    #      under $TMPDIR — NOT bind-mounted into the container, so a
    #      compromised agent inside the container cannot create it. This
    #      is the authoritative proof that the host-side watchdog actually
    #      observed vfkit exit.
    #   3. status.json reports `exit_code: 4` AND `error_type: mount_failure`
    #      — defense in depth. status.json on macOS is mirrored from the
    #      container's named volume into the host status dir, so it is NOT
    #      independently host-trusted; we use it to confirm the watchdog's
    #      own write but never trust it on its own.
    #
    # We DO NOT restrict to signal exit codes (143/137) because pkill may
    # fail to reach the agent's `podman run` (e.g. podman already detached);
    # the pipeline can return 1 even though the watchdog correctly observed
    # vfkit exit. Condition (2) replaces the prior 143/137 restriction as
    # the trust anchor.
    if [[ "$EXIT_CODE" -ne 0 ]] \
       && [[ -n "${_VFKIT_FIRED_SENTINEL:-}" && -f "$_VFKIT_FIRED_SENTINEL" ]]; then
        local _status_file
        _status_file="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}/kapsis-$(basename "$PROJECT_PATH")-${AGENT_ID}.json"
        local status_exit_vfkit status_err_vfkit
        status_exit_vfkit=$(status_get_exit_code 2>/dev/null || echo "")
        status_err_vfkit=""
        if [[ -f "$_status_file" ]] \
           && grep -Eq '"error_type":[[:space:]]*"mount_failure"' "$_status_file" 2>/dev/null; then
            status_err_vfkit="mount_failure"
        fi
        if [[ "$status_exit_vfkit" == "4" && "$status_err_vfkit" == "mount_failure" ]]; then
            log_warn "Mount failure confirmed by vfkit watchdog (host sentinel + status.json mount_failure) — overriding exit code from $EXIT_CODE to 4"
            EXIT_CODE=4
        else
            # Sentinel present but status.json doesn't agree — possible
            # status_complete failure inside the watchdog subshell. Still
            # safe to override because the sentinel is host-trusted.
            log_warn "Mount failure detected via vfkit watchdog host sentinel (status.json mismatch — disk full?) — overriding exit code from $EXIT_CODE to 4"
            EXIT_CODE=4
        fi
    fi

    rm -f "$container_output"
    # Update status to post_processing (Fix #3: don't report "completed" until commit verified)
    status_phase "post_processing" 85 "Processing agent output (exit code: $EXIT_CODE)"

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ AGENT EXITED                                                       │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Handle post-container operations based on sandbox mode
    # Only local backends (podman) need host-side git operations
    # Capture post-container return code with || to prevent set -e from killing
    # the script before the structured exit code logic runs (Issue #256)
    # CRITICAL: This || capture is inseparable from the inner || capture at the
    # post_container_git call site — both must be present or neither works.
    POST_EXIT_CODE=0
    if [[ "$BACKEND" == "podman" ]]; then
        log_debug "Running post-container operations (mode: $SANDBOX_MODE)"
        log_timer_start "post_container"
        if [[ "$SANDBOX_MODE" == "worktree" ]]; then
            post_container_worktree || POST_EXIT_CODE=$?
        else
            post_container_overlay || POST_EXIT_CODE=$?
        fi
        log_timer_end "post_container"
    else
        log_info "Backend '$BACKEND' handles git operations in-pod"
    fi

    # Auto-cleanup agent volumes after session end (Fix #191)
    if [[ "$BACKEND" == "podman" ]] && [[ "$KEEP_VOLUMES" != "true" ]]; then
        log_debug "Auto-cleaning volumes for agent $AGENT_ID (use --keep-volumes to preserve)..."
        cleanup_agent_volumes "$AGENT_ID"
    fi

    log_timer_end "total"

    # Combine exit codes - fail if either container or post-container operations failed
    # Exit codes (Fix #3, Issue #256, Issue #257):
    #   0 = Success (changes committed or no changes)
    #   1 = Agent failure (container exit code non-zero; error_type=agent_partial if work committed)
    #   2 = Push failed
    #   3 = Uncommitted changes remain
    #   4 = Mount failure (virtio-fs drop)
    #   5 = Agent completed but process hung (stuck child process)
    #   6 = Commit failure (agent produced work but git commit failed)
    if [[ "$EXIT_CODE" -eq 4 ]]; then
        # Mount failure detected via sentinel (Issue #248)
        FINAL_EXIT_CODE=4
        log_finalize 4
        status_set_error_type "mount_failure"
        local mount_error="Workspace mount lost (virtio-fs drop). Recovery: podman machine stop && podman machine start, then re-run."
        status_complete 4 "$mount_error"
        _STATUS_COMPLETE_SHOWN=true
        display_complete 4 "" "$mount_error"
        _DISPLAY_COMPLETE_SHOWN=true
    elif [[ "$EXIT_CODE" -eq 5 ]]; then
        # Agent completed but process hung (Issue #257)
        FINAL_EXIT_CODE=5
        log_finalize 5
        status_set_error_type "hung_after_completion"
        local hung_error="Agent completed work but process hung (killed by liveness monitor). Likely cause: stuck child process (e.g., tool call subprocess)."
        status_complete 5 "$hung_error"
        _STATUS_COMPLETE_SHOWN=true
        display_complete 5 "" "$hung_error"
        _DISPLAY_COMPLETE_SHOWN=true
    elif [[ "$EXIT_CODE" -ne 0 ]]; then
        FINAL_EXIT_CODE=$EXIT_CODE
        log_finalize "$EXIT_CODE"
        # Distinguish agent_partial (crashed but committed work) from agent_failure (Issue #260)
        # Note: In overlay mode, commit_status is "overlay_pending" (not "success"),
        # so overlay-mode crashes are always "agent_failure". This is intentional —
        # overlay mode has no git commit, only an upper-dir with changes.
        local agent_commit_status
        agent_commit_status=$(status_get_commit_status 2>/dev/null || echo "unknown")
        if [[ "$agent_commit_status" == "success" ]]; then
            status_set_error_type "agent_partial"
        else
            status_set_error_type "agent_failure"
        fi
        status_complete "$EXIT_CODE" "Agent exited with error code $EXIT_CODE"
        _STATUS_COMPLETE_SHOWN=true
        # Include captured container error in the failure message
        local error_msg="Agent exited with error code $EXIT_CODE"
        if [[ -n "$CONTAINER_ERROR_OUTPUT" ]]; then
            error_msg="$CONTAINER_ERROR_OUTPUT"
            log_debug "Using CONTAINER_ERROR_OUTPUT for display"
        else
            log_debug "CONTAINER_ERROR_OUTPUT is empty, using default message"
        fi
        log_debug "Calling display_complete with error_msg: $error_msg"
        display_complete "$EXIT_CODE" "" "$error_msg"
        _DISPLAY_COMPLETE_SHOWN=true
    elif [[ "$POST_EXIT_CODE" -ne 0 ]]; then
        # Distinguish commit failure from push failure (Issue #256)
        local commit_status
        commit_status=$(status_get_commit_status 2>/dev/null || echo "unknown")
        if [[ "$commit_status" == "failed" ]]; then
            # Exit code 6: agent produced work but git commit failed
            FINAL_EXIT_CODE=6
            log_finalize 6
            status_set_error_type "commit_failure"
            status_complete 6 "Commit failed — agent produced work but git commit returned error. Worktree preserved."
            _STATUS_COMPLETE_SHOWN=true
            display_complete 6 "" "Commit failed — worktree preserved for manual recovery"
            _DISPLAY_COMPLETE_SHOWN=true
        else
            FINAL_EXIT_CODE=$POST_EXIT_CODE
            log_finalize $POST_EXIT_CODE
            status_set_error_type "push_failure"
            status_complete "$POST_EXIT_CODE" "Post-container operations failed (push)"
            _STATUS_COMPLETE_SHOWN=true
            display_complete "$POST_EXIT_CODE" "" "Post-container operations failed (push)"
            _DISPLAY_COMPLETE_SHOWN=true
        fi
    else
        # Check commit status before reporting success (Fix #3)
        local commit_status
        commit_status=$(status_get_commit_status 2>/dev/null || echo "unknown")
        log_debug "Commit status: $commit_status"

        if [[ "$commit_status" == "uncommitted" ]]; then
            # Exit code 3: changes exist but weren't fully committed
            FINAL_EXIT_CODE=3
            log_finalize 3
            status_set_error_type "uncommitted_work"
            log_warn "Uncommitted changes remain in worktree!"
            status_complete 3 "Uncommitted changes remain"
            _STATUS_COMPLETE_SHOWN=true
            display_complete 3 "" "Uncommitted changes remain"
            _DISPLAY_COMPLETE_SHOWN=true
        else
            # Success: no changes, or changes were committed
            FINAL_EXIT_CODE=0
            log_finalize 0
            status_complete 0 "" "${PR_URL:-}"
            _STATUS_COMPLETE_SHOWN=true
            display_complete 0 "${PR_URL:-}"
            _DISPLAY_COMPLETE_SHOWN=true
        fi
    fi

    exit "$FINAL_EXIT_CODE"
}

#===============================================================================
# POST-CONTAINER: WORKTREE MODE
#===============================================================================
# PR_URL is set by post_container_git and used for status reporting
PR_URL=""

# Fix #219: Re-point sanitized git objects symlink from container path to host path.
# Inside the container, objects were at /workspace/.git-objects (mounted from host).
# After container exit, that path is dangling. Re-point to actual host objects.
# Exported as a function so tests can exercise the production code path.
repoint_sanitized_git_objects() {
    local sanitized_git="${1:-${SANITIZED_GIT_PATH:-}}"
    local objects_path="${2:-${OBJECTS_PATH:-}}"

    # Fallback: read HOST_OBJECTS_PATH from kapsis-meta if objects_path is empty
    if [[ -z "$objects_path" && -n "$sanitized_git" && -f "$sanitized_git/kapsis-meta" ]]; then
        objects_path=$(grep "^HOST_OBJECTS_PATH=" "$sanitized_git/kapsis-meta" 2>/dev/null | cut -d= -f2-)
        log_debug "Read HOST_OBJECTS_PATH from kapsis-meta: $objects_path"
    fi

    if [[ -z "$sanitized_git" || ! -d "$sanitized_git" || -z "$objects_path" ]]; then
        log_debug "Skipping sanitized git objects re-point (missing path or dir)"
        return 0
    fi

    # Only re-point if objects is a symlink or doesn't exist yet
    if [[ -L "$sanitized_git/objects" ]] || [[ ! -e "$sanitized_git/objects" ]]; then
        ln -sfn "$objects_path" "$sanitized_git/objects"
        log_debug "Re-pointed sanitized git objects: $sanitized_git/objects -> $objects_path"
    else
        log_warn "sanitized git objects is not a symlink — skipping re-point"
    fi
}

post_container_worktree() {
    log_debug "Processing worktree post-container operations..."
    log_debug "  WORKTREE_PATH=$WORKTREE_PATH"

    # Declare unconditionally so cleanup guard and return always have a defined value (Issue #256)
    local _pcg_rc=0

    # Re-point sanitized git objects symlink BEFORE any git operations (#219)
    # Must happen first so git status and sync_index_from_container work correctly
    repoint_sanitized_git_objects "$SANITIZED_GIT_PATH" "$OBJECTS_PATH"

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
            _STATUS_COMPLETE_SHOWN=true
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
        # MUST be sourced (not exec'd or run in subshell) so that status_set_commit_info
        # writes to the same shell's _KAPSIS_COMMIT_STATUS variable, which is read later
        # by status_get_commit_status in the FINAL_EXIT_CODE logic (Issue #256)
        source "$post_container_script"
        # post_container_git sets PR_URL global variable
        # Capture return code to prevent set -e from killing the function (Issue #256)
        # CRITICAL: This || capture is inseparable from the outer || capture at the
        # post_container_worktree call site — both must be present or neither works.
        # The outer || also keeps this function alive long enough for the _pcg_rc-based
        # worktree preservation logic below to execute.
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
            "$REMOTE_BRANCH" || _pcg_rc=$?

        if [[ $_pcg_rc -ne 0 ]]; then
            log_warn "post_container_git failed (exit code $_pcg_rc)"
        fi
    else
        log_info "No file changes detected"
    fi

    # Generate audit report if audit was enabled
    if [[ "${KAPSIS_AUDIT_ENABLED:-${KAPSIS_DEFAULT_AUDIT_ENABLED}}" == "true" ]]; then
        if [[ -f "$SCRIPT_DIR/audit-report.sh" ]]; then
            "$SCRIPT_DIR/audit-report.sh" --agent-id "$AGENT_ID" --format text \
                > "${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}/${AGENT_ID}-report.txt" 2>/dev/null || true
            log_info "Audit report generated: ${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}/${AGENT_ID}-report.txt"
        fi
    fi

    # Auto-cleanup worktree after completion (Fix #169, Fix #256)
    # Only cleanup when: KEEP_WORKTREE is false AND no failures (agent or post-container)
    if [[ "$KEEP_WORKTREE" == "true" ]] || [[ "$EXIT_CODE" -ne 0 ]] || [[ "${_pcg_rc:-0}" -ne 0 ]]; then
        # Preserve worktree: user requested --keep-worktree, or agent/post-container failed
        if [[ "$EXIT_CODE" -ne 0 ]]; then
            log_warn "Preserving worktree (agent exited with code $EXIT_CODE, partial work may exist)"
        elif [[ "${_pcg_rc:-0}" -ne 0 ]]; then
            log_warn "Preserving worktree (post-container git failed with code ${_pcg_rc}, staged changes may exist)"
            echo ""
            echo "To manually commit from the worktree:"
            echo "  cd \"$WORKTREE_PATH\" && git status && git commit -m 'fix: manual recovery'"
        fi
        echo ""
        echo "Worktree location: $WORKTREE_PATH"
        echo ""
        echo "To continue working:"
        echo "  cd $WORKTREE_PATH"
        echo ""
        echo "To cleanup worktree:"
        echo "  cd $PROJECT_PATH && git worktree remove $WORKTREE_PATH"
    else
        log_info "Auto-cleaning worktree (use --keep-worktree or KAPSIS_KEEP_WORKTREE=true to preserve)..."
        local delete_branch="${KAPSIS_CLEANUP_BRANCH_ENABLED:-${KAPSIS_DEFAULT_CLEANUP_BRANCH_ENABLED:-false}}"
        cleanup_worktree "$PROJECT_PATH" "$AGENT_ID" "$delete_branch"
        prune_worktrees "$PROJECT_PATH"
    fi

    # Propagate post-container failure to caller so POST_EXIT_CODE is set (Issue #256)
    # Without this, the function returns 0 implicitly and the commit-failure detection
    # chain (exit code 6, error_type, worktree preservation in main) is never triggered.
    return "$_pcg_rc"
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
                _STATUS_COMPLETE_SHOWN=true
                echo "Upper directory preserved: $UPPER_DIR"
                return 1
            fi

            # Set commit status for overlay mode (Fix #168)
            # Placed after scope validation so it's only set for valid changes
            status_set_commit_info "overlay_pending" "" "$changes_count"

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
            # Set commit status for overlay mode (Fix #168)
            status_set_commit_info "no_changes" "" "0"
        fi
    else
        log_info "No upper directory found"
        # Set commit status for overlay mode (Fix #168)
        status_set_commit_info "no_changes" "" "0"
    fi
}

# Run main
main "$@"
