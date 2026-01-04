#!/usr/bin/env bash
#===============================================================================
# Kapsis Setup Script
#
# This script prepares your system to run Kapsis AI agent sandboxes.
# It checks dependencies, installs missing components, and validates your setup.
#
# Usage:
#   ./setup.sh              # Full interactive setup
#   ./setup.sh --check      # Check dependencies only (no changes)
#   ./setup.sh --install    # Install missing dependencies (requires sudo/admin)
#   ./setup.sh --build      # Build container image only
#   ./setup.sh --validate   # Run validation tests
#   ./setup.sh --all        # Full setup: check, install, build, validate
#   ./setup.sh --dev        # Developer setup: install pre-commit hooks for contributing
#
# Requirements:
#   - macOS (Apple Silicon or Intel) or Linux
#   - Internet connection for package downloads
#   - Admin privileges for installing dependencies (optional)
#
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/.setup.log"
export LOG_FILE  # Used by logging functions

# Source logging library (setup.sh can run standalone so we need fallback)
if [[ -f "$SCRIPT_DIR/scripts/lib/logging.sh" ]]; then
    source "$SCRIPT_DIR/scripts/lib/logging.sh"
    log_init "setup"
fi

# Minimum versions
MIN_PODMAN_VERSION="4.0.0"
MIN_GIT_VERSION="2.0.0"
MIN_BASH_VERSION="3.2"

# Colors (used for setup-specific formatting)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Custom logging functions for setup UI (keep these for UI consistency)
setup_info() { echo -e "${CYAN}[INFO]${NC} $*"; log_debug "setup_info: $*" 2>/dev/null || true; }
setup_success() { echo -e "${GREEN}[✓]${NC} $*"; log_debug "setup_success: $*" 2>/dev/null || true; }
setup_warn() { echo -e "${YELLOW}[!]${NC} $*"; log_warn "$*" 2>/dev/null || true; }
setup_error() { echo -e "${RED}[✗]${NC} $*" >&2; log_error "$*" 2>/dev/null || true; }
log_step() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; log_info "Step: $*" 2>/dev/null || true; }

# Version comparison: returns 0 if $1 >= $2
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "unknown" ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Print banner
print_banner() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                   ║"
    echo "║   ██╗  ██╗ █████╗ ██████╗ ███████╗██╗███████╗                    ║"
    echo "║   ██║ ██╔╝██╔══██╗██╔══██╗██╔════╝██║██╔════╝                    ║"
    echo "║   █████╔╝ ███████║██████╔╝███████╗██║███████╗                    ║"
    echo "║   ██╔═██╗ ██╔══██║██╔═══╝ ╚════██║██║╚════██║                    ║"
    echo "║   ██║  ██╗██║  ██║██║     ███████║██║███████║                    ║"
    echo "║   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚══════╝╚═╝╚══════╝                    ║"
    echo "║                                                                   ║"
    echo "║   AI Agent Sandbox Setup                                          ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#===============================================================================
# DEPENDENCY CHECKS
#===============================================================================

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

check_result() {
    local status="$1"
    local name="$2"
    local message="$3"
    local fix="${4:-}"

    case "$status" in
        pass)
            log_success "$name: $message"
            ((CHECKS_PASSED++)) || true
            ;;
        warn)
            log_warn "$name: $message"
            [[ -n "$fix" ]] && echo "        → $fix"
            ((CHECKS_WARNED++)) || true
            ;;
        fail)
            log_error "$name: $message"
            [[ -n "$fix" ]] && echo "        → $fix"
            ((CHECKS_FAILED++)) || true
            ;;
    esac
}

check_os() {
    local os
    local arch
    os=$(detect_os)
    arch=$(detect_arch)

    case "$os" in
        macos)
            check_result pass "Operating System" "macOS detected ($arch)"
            ;;
        linux)
            check_result pass "Operating System" "Linux detected ($arch)"
            ;;
        *)
            check_result fail "Operating System" "Unsupported OS: $(uname -s)" \
                "Kapsis requires macOS or Linux"
            ;;
    esac
}

check_bash() {
    local version="${BASH_VERSION%%(*}"
    version="${version%%-*}"

    if version_gte "$version" "$MIN_BASH_VERSION"; then
        check_result pass "Bash" "Version $version"
    else
        check_result fail "Bash" "Version $version (need $MIN_BASH_VERSION+)" \
            "Upgrade bash: brew install bash (macOS) or apt install bash (Linux)"
    fi
}

check_git() {
    if ! command_exists git; then
        check_result fail "Git" "Not installed" \
            "Install: brew install git (macOS) or apt install git (Linux)"
        return
    fi

    local version
    version=$(git --version | sed 's/git version //' | cut -d' ' -f1)

    if version_gte "$version" "$MIN_GIT_VERSION"; then
        check_result pass "Git" "Version $version"
    else
        check_result warn "Git" "Version $version (recommend $MIN_GIT_VERSION+)" \
            "Upgrade git for best compatibility"
    fi
}

check_podman() {
    if ! command_exists podman; then
        check_result fail "Podman" "Not installed" \
            "Install: brew install podman (macOS) or see https://podman.io/getting-started/installation"
        return
    fi

    local version
    version=$(podman --version | awk '{print $3}')

    if version_gte "$version" "$MIN_PODMAN_VERSION"; then
        check_result pass "Podman" "Version $version"
    else
        check_result fail "Podman" "Version $version (need $MIN_PODMAN_VERSION+)" \
            "Upgrade: brew upgrade podman (macOS)"
    fi
}

check_podman_machine() {
    local os
    os=$(detect_os)

    if [[ "$os" != "macos" ]]; then
        check_result pass "Podman Machine" "Not required on Linux"
        return
    fi

    if ! command_exists podman; then
        check_result fail "Podman Machine" "Podman not installed"
        return
    fi

    # Check if any machine exists
    local machines
    machines=$(podman machine list --format '{{.Name}}' 2>/dev/null || echo "")

    if [[ -z "$machines" ]]; then
        check_result fail "Podman Machine" "No machine configured" \
            "Run: podman machine init"
        return
    fi

    # Check if machine is running
    local running
    running=$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null | grep -i "true" || echo "")

    if [[ -z "$running" ]]; then
        check_result warn "Podman Machine" "Machine exists but not running" \
            "Run: podman machine start"
    else
        local machine_name
        machine_name=$(echo "$running" | awk '{print $1}')
        check_result pass "Podman Machine" "Running: $machine_name"
    fi
}

check_yq() {
    if command_exists yq; then
        local version
        version=$(yq --version 2>/dev/null | head -1)
        check_result pass "yq" "Installed ($version)"
    else
        check_result fail "yq" "Not installed (required)" \
            "Install yq: brew install yq (macOS) or sudo snap install yq (Linux)"
    fi
}

check_pre_commit() {
    if command_exists pre-commit; then
        local version
        version=$(pre-commit --version 2>/dev/null | awk '{print $2}')
        check_result pass "pre-commit" "Version $version"
    else
        check_result warn "pre-commit" "Not installed" \
            "Install: brew install pre-commit (macOS) or pip install pre-commit"
    fi
}

check_pre_commit_hooks() {
    local hooks_dir

    # Handle both regular repos and worktrees
    if [[ -d "$SCRIPT_DIR/.git/hooks" ]]; then
        hooks_dir="$SCRIPT_DIR/.git/hooks"
    elif [[ -f "$SCRIPT_DIR/.git" ]]; then
        # Worktree: .git is a file pointing to the main repo
        local git_dir
        git_dir=$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null)
        if [[ -n "$git_dir" ]] && [[ -d "$git_dir/hooks" ]]; then
            hooks_dir="$git_dir/hooks"
        fi
    fi

    if [[ -z "$hooks_dir" ]] || [[ ! -d "$hooks_dir" ]]; then
        check_result warn "Git Hooks" "Not in a git repository"
        return
    fi

    local pre_commit_hook="$hooks_dir/pre-commit"
    local pre_push_hook="$hooks_dir/pre-push"

    if [[ -f "$pre_commit_hook" ]] && grep -q "pre-commit" "$pre_commit_hook" 2>/dev/null; then
        if [[ -f "$pre_push_hook" ]] && grep -q "pre-commit" "$pre_push_hook" 2>/dev/null; then
            check_result pass "Git Hooks" "pre-commit and pre-push installed"
        else
            check_result warn "Git Hooks" "pre-commit installed, pre-push missing" \
                "Run: pre-commit install --hook-type pre-push"
        fi
    else
        check_result warn "Git Hooks" "Not installed" \
            "Run: pre-commit install && pre-commit install --hook-type pre-push"
    fi
}

check_ssh_keys() {
    local ssh_dir="$HOME/.ssh"

    if [[ ! -d "$ssh_dir" ]]; then
        check_result warn "SSH Keys" "No ~/.ssh directory" \
            "Create SSH keys: ssh-keygen -t ed25519"
        return
    fi

    local key_count
    key_count=$(ls -1 "$ssh_dir"/*.pub 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$key_count" -eq 0 ]]; then
        check_result warn "SSH Keys" "No public keys found in ~/.ssh" \
            "Create SSH key: ssh-keygen -t ed25519"
    else
        check_result pass "SSH Keys" "$key_count key(s) found"
    fi
}

check_git_config() {
    local name
    local email
    name=$(git config --global user.name 2>/dev/null || echo "")
    email=$(git config --global user.email 2>/dev/null || echo "")

    if [[ -z "$name" ]] || [[ -z "$email" ]]; then
        check_result warn "Git Config" "User name/email not configured" \
            "Run: git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'"
    else
        check_result pass "Git Config" "User: $name <$email>"
    fi
}

check_disk_space() {
    local required_gb=20
    local available_gb

    if [[ "$(detect_os)" == "macos" ]]; then
        available_gb=$(df -g "$HOME" | tail -1 | awk '{print $4}')
    else
        available_gb=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
    fi

    if [[ "$available_gb" -ge "$required_gb" ]]; then
        check_result pass "Disk Space" "${available_gb}GB available"
    else
        check_result warn "Disk Space" "${available_gb}GB available (recommend ${required_gb}GB+)"
    fi
}

check_memory() {
    local required_gb=8
    local total_gb

    if [[ "$(detect_os)" == "macos" ]]; then
        total_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
    else
        total_gb=$(free -g | awk '/^Mem:/{print $2}')
    fi

    if [[ "$total_gb" -ge "$required_gb" ]]; then
        check_result pass "System Memory" "${total_gb}GB total"
    else
        check_result warn "System Memory" "${total_gb}GB (recommend ${required_gb}GB+ for parallel agents)"
    fi
}

check_api_keys() {
    local has_key=false

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        check_result pass "Anthropic API Key" "Set in environment"
        has_key=true
    fi

    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        check_result pass "OpenAI API Key" "Set in environment"
        has_key=true
    fi

    if [[ "$has_key" == "false" ]]; then
        check_result warn "API Keys" "No AI API keys found in environment" \
            "Set ANTHROPIC_API_KEY or OPENAI_API_KEY for your agent"
    fi
}

check_containerfile() {
    if [[ -f "$SCRIPT_DIR/Containerfile" ]]; then
        check_result pass "Containerfile" "Found"
    else
        check_result fail "Containerfile" "Not found in $SCRIPT_DIR"
    fi
}

check_scripts() {
    local required_scripts=(
        "scripts/launch-agent.sh"
        "scripts/entrypoint.sh"
        "scripts/build-image.sh"
        "scripts/worktree-manager.sh"
        "scripts/post-container-git.sh"
    )

    local missing=()
    for script in "${required_scripts[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
            missing+=("$script")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        check_result pass "Required Scripts" "All ${#required_scripts[@]} scripts present"
    else
        check_result fail "Required Scripts" "Missing: ${missing[*]}"
    fi
}

check_container_image() {
    if ! command_exists podman; then
        check_result warn "Container Image" "Cannot check (Podman not installed)"
        return
    fi

    local image_exists
    image_exists=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "^kapsis-sandbox:" || echo "")

    if [[ -n "$image_exists" ]]; then
        check_result pass "Container Image" "Built: $image_exists"
    else
        check_result warn "Container Image" "Not built yet" \
            "Run: ./scripts/build-image.sh"
    fi
}

run_all_checks() {
    log_step "Checking System Requirements"

    check_os
    check_bash
    check_memory
    check_disk_space

    log_step "Checking Required Dependencies"

    check_git
    check_podman
    check_podman_machine

    log_step "Checking Optional Dependencies"

    check_yq

    log_step "Checking Configuration"

    check_ssh_keys
    check_git_config
    check_api_keys

    log_step "Checking Kapsis Installation"

    check_containerfile
    check_scripts
    check_container_image

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC} $CHECKS_PASSED  ${YELLOW}Warnings:${NC} $CHECKS_WARNED  ${RED}Failed:${NC} $CHECKS_FAILED"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ $CHECKS_FAILED -gt 0 ]]; then
        echo ""
        log_error "Some required checks failed. Please fix the issues above."
        return 1
    elif [[ $CHECKS_WARNED -gt 0 ]]; then
        echo ""
        log_warn "Some optional checks have warnings. Kapsis may work but with limited functionality."
        return 0
    else
        echo ""
        log_success "All checks passed! Kapsis is ready to use."
        return 0
    fi
}

#===============================================================================
# INSTALLATION FUNCTIONS
#===============================================================================

install_homebrew() {
    if command_exists brew; then
        log_info "Homebrew already installed"
        return 0
    fi

    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_podman_macos() {
    if command_exists podman; then
        log_info "Podman already installed"
    else
        log_info "Installing Podman via Homebrew..."
        brew install podman
    fi

    # Initialize machine if needed
    local machines
    machines=$(podman machine list --format '{{.Name}}' 2>/dev/null || echo "")
    if [[ -z "$machines" ]]; then
        log_info "Initializing Podman machine..."
        podman machine init --cpus 4 --memory 8192 --disk-size 100
    fi

    # Start machine if not running
    local running
    running=$(podman machine list --format '{{.Running}}' 2>/dev/null | grep -i "true" || echo "")
    if [[ -z "$running" ]]; then
        log_info "Starting Podman machine..."
        podman machine start
    fi
}

install_podman_linux() {
    if command_exists podman; then
        log_info "Podman already installed"
        return 0
    fi

    log_info "Installing Podman..."

    if command_exists apt-get; then
        sudo apt-get update
        sudo apt-get install -y podman
    elif command_exists dnf; then
        sudo dnf install -y podman
    elif command_exists yum; then
        sudo yum install -y podman
    else
        log_error "Cannot install Podman: unsupported package manager"
        log_info "Please install Podman manually: https://podman.io/getting-started/installation"
        return 1
    fi
}

install_git() {
    if command_exists git; then
        log_info "Git already installed"
        return 0
    fi

    local os
    os=$(detect_os)

    case "$os" in
        macos)
            log_info "Installing Git via Homebrew..."
            brew install git
            ;;
        linux)
            log_info "Installing Git..."
            if command_exists apt-get; then
                sudo apt-get update && sudo apt-get install -y git
            elif command_exists dnf; then
                sudo dnf install -y git
            elif command_exists yum; then
                sudo yum install -y git
            fi
            ;;
    esac
}

install_yq() {
    if command_exists yq; then
        log_info "yq already installed"
        return 0
    fi

    local os
    os=$(detect_os)

    case "$os" in
        macos)
            log_info "Installing yq via Homebrew..."
            brew install yq
            ;;
        linux)
            log_info "Installing yq..."
            if command_exists snap; then
                sudo snap install yq
            else
                # Download binary
                local arch
                arch=$(detect_arch)
                local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
                sudo curl -fsSL "$yq_url" -o /usr/local/bin/yq
                sudo chmod +x /usr/local/bin/yq
            fi
            ;;
    esac
}

install_pre_commit() {
    if command_exists pre-commit; then
        log_info "pre-commit already installed"
    else
        local os
        os=$(detect_os)

        case "$os" in
            macos)
                log_info "Installing pre-commit via Homebrew..."
                brew install pre-commit
                ;;
            linux)
                log_info "Installing pre-commit via pip..."
                if command_exists pip3; then
                    pip3 install --user pre-commit
                elif command_exists pip; then
                    pip install --user pre-commit
                else
                    log_error "pip not found, cannot install pre-commit"
                    return 1
                fi
                ;;
        esac
    fi

    # Install git hooks if .pre-commit-config.yaml exists
    if [[ -f "$SCRIPT_DIR/.pre-commit-config.yaml" ]]; then
        log_info "Installing git hooks..."
        (cd "$SCRIPT_DIR" && pre-commit install && pre-commit install --hook-type pre-push)
        log_success "Git hooks installed (pre-commit + pre-push)"
    fi
}

run_install() {
    local os
    os=$(detect_os)

    log_step "Installing Dependencies"

    case "$os" in
        macos)
            install_homebrew
            install_git
            install_podman_macos
            install_yq
            ;;
        linux)
            install_git
            install_podman_linux
            install_yq
            ;;
        *)
            log_error "Unsupported operating system"
            return 1
            ;;
    esac

    log_success "Dependencies installed successfully"
}

#===============================================================================
# BUILD FUNCTIONS
#===============================================================================

build_container_image() {
    log_step "Building Container Image"

    if [[ ! -f "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
        log_error "Build script not found: $SCRIPT_DIR/scripts/build-image.sh"
        return 1
    fi

    # Make sure Podman is ready
    if [[ "$(detect_os)" == "macos" ]]; then
        local running
        running=$(podman machine list --format '{{.Running}}' 2>/dev/null | grep -i "true" || echo "")
        if [[ -z "$running" ]]; then
            log_info "Starting Podman machine..."
            podman machine start || true
            sleep 5
        fi
    fi

    log_info "This may take 5-10 minutes on first build..."
    echo ""

    "$SCRIPT_DIR/scripts/build-image.sh"

    log_success "Container image built successfully"
}

#===============================================================================
# CONFIGURATION FUNCTIONS
#===============================================================================

create_config() {
    log_step "Creating Configuration"

    local config_file="$SCRIPT_DIR/agent-sandbox.yaml"
    local template_file="$SCRIPT_DIR/agent-sandbox.yaml.template"

    if [[ -f "$config_file" ]]; then
        log_info "Configuration file already exists: $config_file"
        read -p "Overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing configuration"
            return 0
        fi
    fi

    if [[ -f "$template_file" ]]; then
        cp "$template_file" "$config_file"
        log_success "Created configuration from template: $config_file"
    else
        log_warn "Template not found, creating basic config..."
        cat > "$config_file" << 'EOF'
# Kapsis Agent Sandbox Configuration
# See configs/ directory for examples

agent:
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""
  workdir: /workspace

filesystem:
  include:
    - ~/.claude
    - ~/.claude.json
    - ~/.gitconfig
    - ~/.ssh

environment:
  passthrough:
    - ANTHROPIC_API_KEY
  set:
    MAVEN_OPTS: "-Xmx4g -XX:+UseG1GC"

resources:
  memory: 8g
  cpus: 4

maven:
  mirror_url: "https://repo1.maven.org/maven2"
  block_remote_snapshots: true
  block_deploy: true
EOF
        log_success "Created basic configuration: $config_file"
    fi

    echo ""
    log_info "Edit the configuration file to customize your setup:"
    echo "    $config_file"
}

#===============================================================================
# VALIDATION FUNCTIONS
#===============================================================================

run_validation() {
    log_step "Running Validation Tests"

    local test_script="$SCRIPT_DIR/tests/run-all-tests.sh"

    if [[ ! -f "$test_script" ]]; then
        log_warn "Test script not found, skipping validation"
        return 0
    fi

    log_info "Running quick tests (no container required)..."
    if "$test_script" --quick; then
        log_success "Quick tests passed"
    else
        log_warn "Some quick tests failed"
    fi

    # Check if container tests can run
    if command_exists podman; then
        local running=""
        if [[ "$(detect_os)" == "macos" ]]; then
            running=$(podman machine list --format '{{.Running}}' 2>/dev/null | grep -i "true" || echo "")
        else
            running="true"  # Linux doesn't need machine
        fi

        if [[ -n "$running" ]]; then
            log_info "Running container tests..."
            if "$test_script" --category quick; then
                log_success "Container tests passed"
            else
                log_warn "Some container tests failed (may be expected on macOS)"
            fi
        else
            log_warn "Podman machine not running, skipping container tests"
        fi
    fi
}

#===============================================================================
# MAIN
#===============================================================================

show_usage() {
    local cmd_name="${KAPSIS_CMD_NAME:-$0}"
    echo "Usage: $cmd_name [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --check      Check dependencies only (no changes)"
    echo "  --install    Install missing dependencies"
    echo "  --build      Build container image"
    echo "  --config     Create configuration file"
    echo "  --validate   Run validation tests"
    echo "  --all        Full setup (check, install, build, config, validate)"
    echo "  --dev        Developer setup (pre-commit hooks for contributing)"
    echo "  --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $cmd_name --check              # Just check what's needed"
    echo "  $cmd_name --all                # Full automated setup"
    echo "  $cmd_name --install --build    # Install deps and build image"
    echo "  $cmd_name --dev                # Set up pre-commit hooks for development"
}

main() {
    local do_check=false
    local do_install=false
    local do_build=false
    local do_config=false
    local do_validate=false
    local do_dev=false

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        # Interactive mode
        do_check=true
        do_config=true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                do_check=true
                ;;
            --install)
                do_install=true
                ;;
            --build)
                do_build=true
                ;;
            --config)
                do_config=true
                ;;
            --validate)
                do_validate=true
                ;;
            --all)
                do_check=true
                do_install=true
                do_build=true
                do_config=true
                do_validate=true
                ;;
            --dev)
                do_dev=true
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done

    print_banner

    echo "Platform: $(detect_os) / $(detect_arch)"
    echo "Date: $(date)"
    echo ""

    # Run selected operations
    if [[ "$do_check" == "true" ]]; then
        if ! run_all_checks; then
            if [[ "$do_install" != "true" ]]; then
                echo ""
                log_info "Run with --install to automatically install missing dependencies"
                exit 1
            fi
        fi
    fi

    if [[ "$do_install" == "true" ]]; then
        run_install
    fi

    if [[ "$do_config" == "true" ]]; then
        create_config
    fi

    if [[ "$do_build" == "true" ]]; then
        build_container_image
    fi

    if [[ "$do_validate" == "true" ]]; then
        run_validation
    fi

    if [[ "$do_dev" == "true" ]]; then
        log_step "Developer Setup"

        # Install pre-commit if needed (includes hook installation)
        install_pre_commit

        # Verify hooks are installed
        check_pre_commit_hooks

        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo -e "${GREEN}${BOLD}  Developer Setup Complete!${NC}"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "  Git hooks installed:"
        echo "    • pre-commit: Runs shellcheck, shfmt, yamllint, etc."
        echo "    • pre-push: Runs security scan before pushing"
        echo ""
        echo "  To run hooks manually:"
        echo "    pre-commit run --all-files"
        echo ""
        exit 0
    fi

    # Final summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}${BOLD}  Kapsis Setup Complete!${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Edit your configuration:"
    echo "     vim agent-sandbox.yaml"
    echo ""
    echo "  2. Set your API key:"
    echo "     export ANTHROPIC_API_KEY='your-key'"
    echo ""
    echo "  3. Launch an agent:"
    echo "     ./scripts/launch-agent.sh ~/your-project --branch feature/test"
    echo ""
    echo "  Or use the quick-start script:"
    echo "     ./quick-start.sh 1 project-name feature/branch"
    echo ""
    echo "Documentation: $SCRIPT_DIR/docs/ARCHITECTURE.md"
    echo ""
}

main "$@"
