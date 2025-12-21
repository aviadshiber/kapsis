#!/usr/bin/env bash
#===============================================================================
# Build Agent-Specific Kapsis Image
#
# Creates a container image with the specified agent pre-installed.
# Agents are defined in configs/agents/<name>.yaml
#
# Usage:
#   ./scripts/build-agent-image.sh claude-cli
#   ./scripts/build-agent-image.sh aider
#   ./scripts/build-agent-image.sh claude-api
#
# Output:
#   kapsis-<agent>:latest (e.g., kapsis-claude-cli:latest)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source logging if available
if [[ -f "$SCRIPT_DIR/lib/logging.sh" ]]; then
    source "$SCRIPT_DIR/lib/logging.sh"
    log_init "build-agent"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

#===============================================================================
# PARSE ARGUMENTS
#===============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") <agent-profile>

Build a Kapsis container image with the specified agent pre-installed.

Arguments:
  agent-profile    Name of agent profile in configs/agents/ (e.g., claude-cli, aider)

Options:
  -h, --help       Show this help message

Examples:
  $(basename "$0") claude-cli    # Build with Claude Code CLI
  $(basename "$0") claude-api    # Build with Anthropic Python SDK
  $(basename "$0") aider         # Build with Aider

Available Profiles:
EOF
    for profile in "$KAPSIS_ROOT"/configs/agents/*.yaml; do
        name=$(basename "$profile" .yaml)
        desc=$(yq -r '.description // "No description"' "$profile" 2>/dev/null || echo "No description")
        printf "  %-15s %s\n" "$name" "$desc"
    done
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
    exit 0
fi

AGENT_PROFILE="$1"
PROFILE_PATH="$KAPSIS_ROOT/configs/agents/${AGENT_PROFILE}.yaml"

#===============================================================================
# VALIDATE PROFILE
#===============================================================================
if [[ ! -f "$PROFILE_PATH" ]]; then
    log_error "Agent profile not found: $PROFILE_PATH"
    echo ""
    echo "Available profiles:"
    for profile in "$KAPSIS_ROOT/configs/agents/"*.yaml; do
        [[ -f "$profile" ]] && echo "  $(basename "$profile" .yaml)"
    done
    exit 1
fi

log_info "Building agent image from profile: $AGENT_PROFILE"

#===============================================================================
# PARSE PROFILE
#===============================================================================
AGENT_NAME=$(yq -r '.name // ""' "$PROFILE_PATH")
AGENT_NPM=$(yq -r '.install.npm // ""' "$PROFILE_PATH")
AGENT_PIP=$(yq -r '.install.pip // ""' "$PROFILE_PATH")
AGENT_DESC=$(yq -r '.description // ""' "$PROFILE_PATH")

log_info "Agent: $AGENT_NAME"
[[ -n "$AGENT_DESC" ]] && log_info "Description: $AGENT_DESC"
[[ -n "$AGENT_NPM" ]] && log_info "NPM packages: $AGENT_NPM"
[[ -n "$AGENT_PIP" ]] && log_info "PIP packages: $AGENT_PIP"

#===============================================================================
# BUILD IMAGE
#===============================================================================
IMAGE_NAME="kapsis-${AGENT_PROFILE}:latest"

log_info "Building image: $IMAGE_NAME"

BUILD_ARGS=()
[[ -n "$AGENT_NPM" ]] && BUILD_ARGS+=("--build-arg" "AGENT_NPM=$AGENT_NPM")
[[ -n "$AGENT_PIP" ]] && BUILD_ARGS+=("--build-arg" "AGENT_PIP=$AGENT_PIP")

cd "$KAPSIS_ROOT"

# Detect container runtime
if command -v podman &>/dev/null; then
    CONTAINER_RUNTIME="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_RUNTIME="docker"
else
    log_error "Neither podman nor docker found"
    exit 1
fi

log_info "Using container runtime: $CONTAINER_RUNTIME"

# Build the image
$CONTAINER_RUNTIME build \
    "${BUILD_ARGS[@]}" \
    --label "kapsis.agent=$AGENT_NAME" \
    --label "kapsis.profile=$AGENT_PROFILE" \
    -t "$IMAGE_NAME" \
    -f Containerfile .

BUILD_EXIT=$?

if [[ $BUILD_EXIT -eq 0 ]]; then
    log_success "Image built successfully: $IMAGE_NAME"
    echo ""
    echo "To use this image, run:"
    echo "  ./scripts/launch-agent.sh 1 ~/git/products --image $IMAGE_NAME --task \"Your task\""
    echo ""
    echo "Or update your config to use this image:"
    echo "  agent:"
    echo "    image: $IMAGE_NAME"
else
    log_error "Build failed with exit code $BUILD_EXIT"
    exit $BUILD_EXIT
fi
