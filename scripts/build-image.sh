#!/usr/bin/env bash
#===============================================================================
# Kapsis - Build Container Image
#
# Builds the Kapsis sandbox container image using Podman.
#
# Usage:
#   ./build-image.sh [options]
#
# Options:
#   --name <name>         Image name (default: kapsis-sandbox)
#   --tag <tag>           Image tag (default: latest)
#   --platform <p>        Target platform (default: auto-detect, e.g., linux/amd64)
#   --build-config <file> Path to build configuration YAML (default: configs/build-config.yaml)
#   --profile <name>      Use a predefined profile (minimal, java-dev, full-stack, etc.)
#   --dry-run             Show build configuration without building
#   --no-cache            Build without cache
#   --push                Push to registry after build
#   --help                Show this help message
#
# Profiles:
#   minimal       Base container (~500MB) - no language runtimes
#   java-dev      Java development (~1.5GB) - Java 17/8, Maven, GE
#   java8-legacy  Legacy Java 8 (~1.3GB) - Java 8 only, Maven
#   full-stack    All languages (~2.1GB) - Java, Node.js, Python
#   backend-go    Go services (~1.2GB) - Go, Python
#   backend-rust  Rust services (~1.4GB) - Rust, Python
#   ml-python     ML/AI development (~1.8GB) - Python, Node.js, Rust
#   frontend      Frontend development (~1.2GB) - Node.js, Rust
#
# Examples:
#   ./build-image.sh                           # Build with default config
#   ./build-image.sh --profile minimal         # Build minimal image
#   ./build-image.sh --profile java-dev        # Build for Java development
#   ./build-image.sh --build-config custom.yaml  # Use custom config
#   ./build-image.sh --dry-run --profile full-stack  # Preview full-stack build
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"
log_init "build-image"

# Source build configuration library
source "$SCRIPT_DIR/lib/build-config.sh"

#===============================================================================
# Security: Pinned base image digests per architecture
# These are SHA256 digests of ubuntu:24.04 for each supported platform
# To update: podman manifest inspect docker.io/library/ubuntu:24.04
#===============================================================================
declare -A BASE_IMAGE_DIGESTS=(
    ["linux/amd64"]="sha256:4fdf0125919d24aec972544669dcd7d6a26a8ad7e6561c73d5549bd6db258ac2"
    ["linux/arm64"]="sha256:955364933d0d91afa6e10fb045948c16d2b191114aa54bed3ab5430d8bbc58cc"
)

# Defaults
IMAGE_NAME="kapsis-sandbox"
IMAGE_TAG="latest"
NO_CACHE=""
PUSH=false
PLATFORM=""
BUILD_CONFIG=""
PROFILE=""
DRY_RUN=false

# Note: logging functions are provided by lib/logging.sh

#===============================================================================
# show_help - Display usage information
#===============================================================================
show_help() {
    # Extract help from script header comments
    sed -n '2,/^#====.*$/p' "$0" | sed 's/^# *//' | head -n -1
    exit 0
}

#===============================================================================
# resolve_config_file - Resolve the configuration file to use
#===============================================================================
resolve_config_file() {
    local config_file=""

    # Priority: --build-config > --profile > default config
    if [[ -n "$BUILD_CONFIG" ]]; then
        config_file="$BUILD_CONFIG"
    elif [[ -n "$PROFILE" ]]; then
        config_file="$KAPSIS_ROOT/configs/build-profiles/${PROFILE}.yaml"
    else
        config_file="$KAPSIS_ROOT/configs/build-config.yaml"
    fi

    # Validate file exists (build-config.sh will use defaults if missing)
    if [[ ! -f "$config_file" ]]; then
        if [[ -n "$BUILD_CONFIG" ]]; then
            log_error "Build config file not found: $BUILD_CONFIG"
            exit 2
        elif [[ -n "$PROFILE" ]]; then
            log_error "Unknown profile: $PROFILE"
            log_error "Available profiles: minimal, java-dev, java8-legacy, full-stack, backend-go, backend-rust, ml-python, frontend"
            exit 2
        fi
        # Default config missing is OK - will use built-in defaults
        log_warn "Default config not found, using built-in defaults"
        config_file=""
    fi

    echo "$config_file"
}

#===============================================================================
# detect_platform - Auto-detect target platform from host architecture
#===============================================================================
detect_platform() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "linux/amd64"
            ;;
        aarch64|arm64)
            echo "linux/arm64"
            ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
}

#===============================================================================
# get_base_image_digest - Get pinned digest for target platform
#===============================================================================
get_base_image_digest() {
    local platform="$1"

    if [[ -z "${BASE_IMAGE_DIGESTS[$platform]:-}" ]]; then
        log_error "No pinned digest for platform: $platform"
        log_error "Supported platforms: ${!BASE_IMAGE_DIGESTS[*]}"
        exit 1
    fi

    echo "${BASE_IMAGE_DIGESTS[$platform]}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --build-config)
            BUILD_CONFIG="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            log_error "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate mutually exclusive options
if [[ -n "$BUILD_CONFIG" ]] && [[ -n "$PROFILE" ]]; then
    log_error "--build-config and --profile are mutually exclusive"
    exit 1
fi

# Resolve platform and digest
if [[ -z "$PLATFORM" ]]; then
    PLATFORM=$(detect_platform)
    log_debug "Auto-detected platform: $PLATFORM"
fi
BASE_IMAGE_DIGEST=$(get_base_image_digest "$PLATFORM")

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# Resolve and parse build configuration
CONFIG_FILE=$(resolve_config_file)
log_debug "Using config file: ${CONFIG_FILE:-<defaults>}"

if ! parse_build_config "$CONFIG_FILE"; then
    log_error "Failed to parse build configuration"
    exit 3
fi

log_debug "Parsed arguments:"
log_debug "  IMAGE_NAME=$IMAGE_NAME"
log_debug "  IMAGE_TAG=$IMAGE_TAG"
log_debug "  BUILD_CONFIG=$BUILD_CONFIG"
log_debug "  PROFILE=$PROFILE"
log_debug "  DRY_RUN=$DRY_RUN"
log_debug "  NO_CACHE=$NO_CACHE"
log_debug "  PUSH=$PUSH"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                    KAPSIS IMAGE BUILD                             ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ -n "$PROFILE" ]]; then
    log_info "Profile: $PROFILE"
elif [[ -n "$BUILD_CONFIG" ]]; then
    log_info "Config: $BUILD_CONFIG"
else
    log_info "Config: default (full-stack)"
fi

log_info "Building image: $FULL_IMAGE"
log_info "Estimated size: $(estimate_image_size)"
echo ""

# Display configuration summary
print_config_summary
echo ""

# Handle dry-run mode
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry-run mode - showing build arguments:"
    echo ""
    echo "podman build \\"
    echo "    --platform $PLATFORM \\"
    echo "    --build-arg BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST \\"
    for arg in "${BUILD_ARGS[@]}"; do
        echo "    $arg \\"
    done
    echo "    --tag $FULL_IMAGE \\"
    echo "    --file Containerfile ."
    echo ""
    log_info "To build, run without --dry-run"
    exit 0
fi

log_info "Context: $KAPSIS_ROOT"
echo ""

# Ensure Podman machine is running (macOS only - Linux runs Podman natively)
if [[ "$(uname)" == "Darwin" ]]; then
    log_debug "Checking Podman machine status..."
    if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
        log_info "Starting Podman machine..."
        podman machine start podman-machine-default
        log_debug "Podman machine started"
    else
        log_debug "Podman machine already running"
    fi
fi

# Build image
cd "$KAPSIS_ROOT"

log_timer_start "build"
log_info "Platform: $PLATFORM"
log_info "Base image digest: $BASE_IMAGE_DIGEST"
log_debug "Running: podman build with ${#BUILD_ARGS[@]} build args"

# Build the podman command with all build args
# shellcheck disable=SC2086
podman build \
    $NO_CACHE \
    --platform "$PLATFORM" \
    --build-arg "BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST" \
    "${BUILD_ARGS[@]}" \
    --tag "$FULL_IMAGE" \
    --file Containerfile \
    .

log_timer_end "build"

echo ""
log_success "Image built successfully: $FULL_IMAGE"
echo ""

# Show image info
podman images "$IMAGE_NAME"

# Push if requested
if [[ "$PUSH" == "true" ]]; then
    log_info "Pushing image..."
    podman push "$FULL_IMAGE"
    log_success "Image pushed: $FULL_IMAGE"
fi

echo ""
log_info "To run a container:"
echo "  ./scripts/launch-agent.sh ~/project --task \"your task\""
