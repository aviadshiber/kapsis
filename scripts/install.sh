#!/usr/bin/env bash
# Kapsis Installer Script
# Usage: curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash
#
# Environment variables:
#   KAPSIS_VERSION  - Specific version to install (default: latest)
#   KAPSIS_PREFIX   - Installation prefix (default: ~/.local)
#   KAPSIS_NO_MODIFY_PATH - Set to 1 to skip PATH modification

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GITHUB_REPO="aviadshiber/kapsis"
INSTALL_PREFIX="${KAPSIS_PREFIX:-$HOME/.local}"
BIN_DIR="$INSTALL_PREFIX/bin"
LIB_DIR="$INSTALL_PREFIX/lib/kapsis"
SHARE_DIR="$INSTALL_PREFIX/share/kapsis"

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}

# Check for required commands
check_dependencies() {
    local missing=()

    for cmd in curl tar git; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# Get latest version from GitHub
get_latest_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [[ -z "$version" ]]; then
        die "Failed to determine latest version"
    fi

    echo "$version"
}

# Download and extract release
download_release() {
    local version="$1"
    local tmpdir
    tmpdir=$(mktemp -d)

    info "Downloading Kapsis v${version}..."

    local url="https://github.com/$GITHUB_REPO/archive/refs/tags/v${version}.tar.gz"

    if ! curl -fsSL "$url" -o "$tmpdir/kapsis.tar.gz"; then
        rm -rf "$tmpdir"
        die "Failed to download release"
    fi

    tar -xzf "$tmpdir/kapsis.tar.gz" -C "$tmpdir"

    echo "$tmpdir/kapsis-${version}"
}

# Install files
install_files() {
    local src_dir="$1"

    info "Installing to $INSTALL_PREFIX..."

    # Create directories
    mkdir -p "$BIN_DIR"
    mkdir -p "$LIB_DIR/scripts"
    mkdir -p "$LIB_DIR/lib"
    mkdir -p "$SHARE_DIR/configs/agents"
    mkdir -p "$SHARE_DIR/maven"

    # Install scripts
    cp "$src_dir/scripts/launch-agent.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/build-image.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/build-agent-image.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/kapsis-cleanup.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/kapsis-status.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/entrypoint.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/worktree-manager.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/post-container-git.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/post-exit-git.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/preflight-check.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/init-git-branch.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/merge-changes.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/scripts/switch-java.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/setup.sh" "$LIB_DIR/scripts/"
    cp "$src_dir/quick-start.sh" "$LIB_DIR/scripts/"
    chmod +x "$LIB_DIR/scripts/"*.sh

    # Install library files
    cp "$src_dir/scripts/lib/"*.sh "$LIB_DIR/lib/"

    # Install configuration files
    cp "$src_dir/agent-sandbox.yaml.template" "$SHARE_DIR/"
    cp "$src_dir/Containerfile" "$SHARE_DIR/"
    cp "$src_dir/configs/agents/"*.yaml "$SHARE_DIR/configs/agents/" 2>/dev/null || true
    cp "$src_dir/maven/isolated-settings.xml" "$SHARE_DIR/maven/"

    # Create wrapper scripts
    create_wrapper "kapsis" "launch-agent.sh"
    create_wrapper "kapsis-build" "build-image.sh"
    create_wrapper "kapsis-cleanup" "kapsis-cleanup.sh"
    create_wrapper "kapsis-status" "kapsis-status.sh"
    create_wrapper "kapsis-setup" "setup.sh"
    create_wrapper "kapsis-quick" "quick-start.sh"
}

# Create a wrapper script
create_wrapper() {
    local name="$1"
    local script="$2"

    cat > "$BIN_DIR/$name" << EOF
#!/bin/bash
export KAPSIS_HOME="$SHARE_DIR"
export KAPSIS_LIB="$LIB_DIR/lib"
export KAPSIS_SCRIPTS="$LIB_DIR/scripts"
exec "$LIB_DIR/scripts/$script" "\$@"
EOF
    chmod +x "$BIN_DIR/$name"
}

# Add to PATH if needed
setup_path() {
    if [[ "${KAPSIS_NO_MODIFY_PATH:-0}" == "1" ]]; then
        return
    fi

    # Check if already in PATH
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        return
    fi

    local shell_rc=""
    local shell_name

    shell_name=$(basename "$SHELL")

    case "$shell_name" in
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                shell_rc="$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                shell_rc="$HOME/.bash_profile"
            fi
            ;;
        zsh)
            shell_rc="$HOME/.zshrc"
            ;;
        fish)
            shell_rc="$HOME/.config/fish/config.fish"
            ;;
    esac

    if [[ -n "$shell_rc" && -f "$shell_rc" ]]; then
        if ! grep -q "KAPSIS_HOME" "$shell_rc" 2>/dev/null; then
            info "Adding Kapsis to PATH in $shell_rc"

            if [[ "$shell_name" == "fish" ]]; then
                echo "" >> "$shell_rc"
                echo "# Kapsis" >> "$shell_rc"
                echo "set -gx PATH $BIN_DIR \$PATH" >> "$shell_rc"
            else
                echo "" >> "$shell_rc"
                echo "# Kapsis" >> "$shell_rc"
                echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_rc"
            fi

            warn "PATH updated. Run 'source $shell_rc' or start a new shell."
        fi
    else
        warn "Could not detect shell configuration file."
        warn "Add '$BIN_DIR' to your PATH manually."
    fi
}

# Check for Podman
check_podman() {
    if command -v podman &>/dev/null; then
        success "Podman found: $(podman --version)"
    else
        warn "Podman not found. Kapsis requires Podman for container isolation."
        echo ""
        echo "Install Podman:"
        echo "  macOS:         brew install podman && podman machine init && podman machine start"
        echo "  Debian/Ubuntu: sudo apt install podman"
        echo "  Fedora:        sudo dnf install podman"
        echo "  Arch:          sudo pacman -S podman"
        echo ""
    fi
}

# Cleanup
cleanup() {
    local tmpdir="$1"
    if [[ -d "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}

# Main installation
main() {
    echo ""
    echo "  _  __                _     "
    echo " | |/ /__ _ _ __  ___(_)___ "
    echo " | ' // _\` | '_ \\/ __| / __|"
    echo " | . \\ (_| | |_) \\__ \\ \\__ \\"
    echo " |_|\\_\\__,_| .__/|___/_|___/"
    echo "           |_|               "
    echo ""
    echo "Kapsis Installer"
    echo "================"
    echo ""

    check_dependencies

    # Determine version
    local version="${KAPSIS_VERSION:-}"
    if [[ -z "$version" ]]; then
        info "Fetching latest version..."
        version=$(get_latest_version)
    fi

    info "Version: $version"
    info "Install prefix: $INSTALL_PREFIX"

    # Download
    local src_dir
    src_dir=$(download_release "$version")
    trap "cleanup '$src_dir'" EXIT

    # Install
    install_files "$src_dir"
    setup_path

    echo ""
    success "Kapsis v${version} installed successfully!"
    echo ""

    check_podman

    echo "Next steps:"
    echo "  1. Ensure Podman is installed and running"
    echo "  2. Build the container image: kapsis-setup --build"
    echo "  3. Run an agent: kapsis 1 /path/to/project --agent claude --task 'Your task'"
    echo ""
    echo "Documentation: https://github.com/$GITHUB_REPO"
    echo ""
}

main "$@"
