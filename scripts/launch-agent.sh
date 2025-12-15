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
IMAGE_NAME="kapsis-sandbox:latest"

#===============================================================================
# COLORS AND OUTPUT
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                         KAPSIS SANDBOX                            ║"
    echo "║           Hermetically Isolated AI Agent Environment              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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
    # Validate project path
    PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || {
        log_error "Project path does not exist: $PROJECT_PATH"
        exit 1
    }

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

    # Check Podman is available
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed or not in PATH"
        exit 1
    fi

    # Check Podman machine is running
    if ! podman machine inspect podman-machine-default &>/dev/null || \
       [[ "$(podman machine inspect podman-machine-default --format '{{.State}}')" != "running" ]]; then
        log_warn "Podman machine is not running. Attempting to start..."
        podman machine start podman-machine-default || {
            log_error "Failed to start Podman machine. Please run: podman machine start"
            exit 1
        }
    fi
}

#===============================================================================
# CONFIG RESOLUTION
#===============================================================================
resolve_config() {
    # --config takes precedence
    if [[ -n "$CONFIG_FILE" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        # Extract agent name from config filename
        if [[ -z "$AGENT_NAME" ]]; then
            AGENT_NAME=$(basename "$CONFIG_FILE" .yaml)
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
    # Check if yq is available
    if command -v yq &> /dev/null; then
        AGENT_COMMAND=$(yq -r '.agent.command // "bash"' "$CONFIG_FILE")
        AGENT_WORKDIR=$(yq -r '.agent.workdir // "/workspace"' "$CONFIG_FILE")
        RESOURCE_MEMORY=$(yq -r '.resources.memory // "8g"' "$CONFIG_FILE")
        RESOURCE_CPUS=$(yq -r '.resources.cpus // "4"' "$CONFIG_FILE")
        SANDBOX_UPPER_BASE=$(yq -r '.sandbox.upper_dir_base // "~/.ai-sandboxes"' "$CONFIG_FILE")
        IMAGE_NAME=$(yq -r '.image.name // "kapsis-sandbox"' "$CONFIG_FILE"):$(yq -r '.image.tag // "latest"' "$CONFIG_FILE")
        GIT_REMOTE=$(yq -r '.git.auto_push.remote // "origin"' "$CONFIG_FILE")
        GIT_COMMIT_MSG=$(yq -r '.git.auto_push.commit_message // "feat: AI agent changes"' "$CONFIG_FILE")

        # Parse filesystem includes
        FILESYSTEM_INCLUDES=$(yq -r '.filesystem.include[]? // empty' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment passthrough
        ENV_PASSTHROUGH=$(yq -r '.environment.passthrough[]? // empty' "$CONFIG_FILE" 2>/dev/null || echo "")

        # Parse environment set
        ENV_SET=$(yq -r '.environment.set // {}' "$CONFIG_FILE" 2>/dev/null || echo "{}")
    else
        log_warn "yq not found. Using default config values."
        AGENT_COMMAND="bash"
        AGENT_WORKDIR="/workspace"
        RESOURCE_MEMORY="8g"
        RESOURCE_CPUS="4"
        SANDBOX_UPPER_BASE="$HOME/.ai-sandboxes"
        GIT_REMOTE="origin"
        GIT_COMMIT_MSG="feat: AI agent changes"
        FILESYSTEM_INCLUDES=""
        ENV_PASSTHROUGH="ANTHROPIC_API_KEY"
        ENV_SET="{}"
    fi

    # Expand ~ in paths
    SANDBOX_UPPER_BASE="${SANDBOX_UPPER_BASE/#\~/$HOME}"
}

#===============================================================================
# SANDBOX SETUP
#===============================================================================
setup_sandbox() {
    local project_name
    project_name=$(basename "$PROJECT_PATH")
    SANDBOX_ID="${project_name}-${AGENT_ID}"
    SANDBOX_DIR="${SANDBOX_UPPER_BASE}/${SANDBOX_ID}"
    UPPER_DIR="${SANDBOX_DIR}/upper"
    WORK_DIR="${SANDBOX_DIR}/work"

    log_info "Setting up sandbox: $SANDBOX_ID"

    mkdir -p "$UPPER_DIR" "$WORK_DIR"

    log_info "  Upper directory: $UPPER_DIR"
    log_info "  Work directory: $WORK_DIR"
}

#===============================================================================
# VOLUME MOUNTS GENERATION
#===============================================================================
generate_volume_mounts() {
    VOLUME_MOUNTS=()

    # Project with CoW overlay
    VOLUME_MOUNTS+=("-v" "${PROJECT_PATH}:/workspace:O,upperdir=${UPPER_DIR},workdir=${WORK_DIR}")

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
    if [[ -n "$FILESYSTEM_INCLUDES" ]]; then
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            expanded_path="${path/#\~/$HOME}"
            if [[ -e "$expanded_path" ]]; then
                # Map to same relative path in container home
                container_path="${path/#\~//home/developer}"
                VOLUME_MOUNTS+=("-v" "${expanded_path}:${container_path}:ro")
            fi
        done <<< "$FILESYSTEM_INCLUDES"
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

    # Set explicit environment variables
    ENV_VARS+=("-e" "KAPSIS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_SANDBOX_DIR=${SANDBOX_DIR}")

    if [[ -n "$BRANCH" ]]; then
        ENV_VARS+=("-e" "KAPSIS_BRANCH=${BRANCH}")
        ENV_VARS+=("-e" "KAPSIS_GIT_REMOTE=${GIT_REMOTE}")
        ENV_VARS+=("-e" "KAPSIS_NO_PUSH=${NO_PUSH}")
    fi

    if [[ -n "$TASK_INLINE" ]]; then
        ENV_VARS+=("-e" "KAPSIS_TASK=${TASK_INLINE}")
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

    # Add environment variables
    CONTAINER_CMD+=("${ENV_VARS[@]}")

    # Add image
    CONTAINER_CMD+=("$IMAGE_NAME")

    # Add command
    if [[ "$INTERACTIVE" == "true" ]]; then
        CONTAINER_CMD+=("bash")
    elif [[ -n "$TASK_INLINE" ]]; then
        # Create temp spec file for inline task
        INLINE_SPEC_FILE=$(mktemp)
        echo "$TASK_INLINE" > "$INLINE_SPEC_FILE"
        # Re-add spec mount
        CONTAINER_CMD=("${CONTAINER_CMD[@]}" "-v" "${INLINE_SPEC_FILE}:/task-spec.md:ro")
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================
main() {
    print_banner

    parse_args "$@"
    validate_inputs
    resolve_config
    parse_config
    generate_branch_name
    setup_sandbox
    generate_volume_mounts
    generate_env_vars
    build_container_command

    echo ""
    log_info "Agent Configuration:"
    echo "  Agent:         $(to_upper "$AGENT_NAME") (${CONFIG_FILE})"
    echo "  Instance ID:   $AGENT_ID"
    echo "  Project:       $PROJECT_PATH"
    echo "  Image:         $IMAGE_NAME"
    echo "  Resources:     ${RESOURCE_MEMORY} RAM, ${RESOURCE_CPUS} CPUs"
    [[ -n "$BRANCH" ]] && echo "  Branch:        $BRANCH"
    [[ -n "$SPEC_FILE" ]] && echo "  Spec File:     $SPEC_FILE"
    [[ -n "$TASK_INLINE" ]] && echo "  Task:          ${TASK_INLINE:0:50}..."
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN - Command that would be executed:"
        echo ""
        echo "${CONTAINER_CMD[*]}"
        echo ""
        exit 0
    fi

    echo "┌────────────────────────────────────────────────────────────────────┐"
    printf "│ LAUNCHING %-56s │\n" "$(to_upper "$AGENT_NAME")"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Run the container
    "${CONTAINER_CMD[@]}"
    EXIT_CODE=$?

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ AGENT EXITED                                                       │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo ""

    # Show changes summary
    if [[ -d "$UPPER_DIR" ]]; then
        local changes_count
        changes_count=$(find "$UPPER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$changes_count" -gt 0 ]]; then
            log_success "Agent made $changes_count file change(s)"
            echo ""
            echo "Changed files:"
            find "$UPPER_DIR" -type f -printf "  %P\n" 2>/dev/null | head -20
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

    exit $EXIT_CODE
}

# Run main
main "$@"
