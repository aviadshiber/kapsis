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
#   --name <name>     Image name (default: kapsis-sandbox)
#   --tag <tag>       Image tag (default: latest)
#   --platform <p>    Target platform (default: auto-detect, e.g., linux/amd64)
#   --no-cache        Build without cache
#   --push            Push to registry after build
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"
log_init "build-image"

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

# Note: logging functions are provided by lib/logging.sh

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
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Resolve platform and digest
if [[ -z "$PLATFORM" ]]; then
    PLATFORM=$(detect_platform)
    log_debug "Auto-detected platform: $PLATFORM"
fi
BASE_IMAGE_DIGEST=$(get_base_image_digest "$PLATFORM")

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

log_debug "Parsed arguments:"
log_debug "  IMAGE_NAME=$IMAGE_NAME"
log_debug "  IMAGE_TAG=$IMAGE_TAG"
log_debug "  NO_CACHE=$NO_CACHE"
log_debug "  PUSH=$PUSH"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                    KAPSIS IMAGE BUILD                             ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

log_info "Building image: $FULL_IMAGE"
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
log_debug "Running: podman build $NO_CACHE --platform $PLATFORM --build-arg BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST --tag $FULL_IMAGE --file Containerfile ."

podman build \
    $NO_CACHE \
    --platform "$PLATFORM" \
    --build-arg "BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST" \
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
