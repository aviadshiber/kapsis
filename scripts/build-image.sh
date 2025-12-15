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
#   --no-cache        Build without cache
#   --push            Push to registry after build
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
source "$SCRIPT_DIR/lib/logging.sh"
log_init "build-image"

# Defaults
IMAGE_NAME="kapsis-sandbox"
IMAGE_TAG="latest"
NO_CACHE=""
PUSH=false

# Note: logging functions are provided by lib/logging.sh

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

# Ensure Podman machine is running
log_debug "Checking Podman machine status..."
if ! podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null | grep -q "running"; then
    log_info "Starting Podman machine..."
    podman machine start podman-machine-default
    log_debug "Podman machine started"
else
    log_debug "Podman machine already running"
fi

# Build image
cd "$KAPSIS_ROOT"

log_timer_start "build"
log_debug "Running: podman build $NO_CACHE --tag $FULL_IMAGE --file Containerfile ."

podman build \
    $NO_CACHE \
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
echo "  ./scripts/launch-agent.sh 1 ~/project --task \"your task\""
