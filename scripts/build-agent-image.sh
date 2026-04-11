#!/usr/bin/env bash
#===============================================================================
# Build Agent-Specific Kapsis Image
#
# Creates a container image with the specified agent pre-installed.
# Agents are defined in configs/agents/<name>.yaml
#
# Usage:
#   ./scripts/build-agent-image.sh claude-cli
#   ./scripts/build-agent-image.sh claude-cli --profile java-dev
#   ./scripts/build-agent-image.sh aider --build-config configs/build-config.yaml
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
    log_warn() { echo "[WARN] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# Source build-config library if available
if [[ -f "$SCRIPT_DIR/lib/build-config.sh" ]]; then
    source "$SCRIPT_DIR/lib/build-config.sh"
fi

#===============================================================================
# PARSE ARGUMENTS
#===============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") <agent-profile> [options]

Build a Kapsis container image with the specified agent pre-installed.

Arguments:
  agent-profile    Name of agent profile in configs/agents/ (e.g., claude-cli, aider)

Options:
  --pull                   Pull pre-built image from ghcr.io (recommended)
  --build-config <file>    Build config file (default: configs/build-config.yaml)
  --profile <name>         Build profile preset (e.g., java-dev, full-stack)
  -h, --help               Show this help message

Examples:
  $(basename "$0") claude-cli --pull               # Pull pre-built image (recommended)
  $(basename "$0") claude-cli                      # Build with default config
  $(basename "$0") claude-cli --profile java-dev   # Build with java-dev profile
  $(basename "$0") aider --profile full-stack      # Build aider with full-stack

Available Agent Profiles:
EOF
    for profile in "$KAPSIS_ROOT"/configs/agents/*.yaml; do
        name=$(basename "$profile" .yaml)
        desc=$(yq -r '.description // "No description"' "$profile" 2>/dev/null || echo "No description")
        printf "  %-15s %s\n" "$name" "$desc"
    done
    echo ""
    echo "Available Build Profiles:"
    if [[ -d "$KAPSIS_ROOT/configs/build-profiles" ]]; then
        for profile in "$KAPSIS_ROOT"/configs/build-profiles/*.yaml; do
            [[ -f "$profile" ]] && printf "  %s\n" "$(basename "$profile" .yaml)"
        done
    else
        echo "  (none - using default config)"
    fi
}

# Default values
AGENT_PROFILE=""
BUILD_CONFIG=""
BUILD_PROFILE=""
PULL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)
            PULL=true
            shift
            ;;
        --build-config)
            BUILD_CONFIG="$2"
            shift 2
            ;;
        --profile)
            BUILD_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$AGENT_PROFILE" ]]; then
                AGENT_PROFILE="$1"
            else
                log_error "Unexpected argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$AGENT_PROFILE" ]]; then
    usage
    exit 0
fi

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

# Pull mode: pull pre-built image from registry instead of building
if [[ "$PULL" == "true" ]]; then
    # Source constants for KAPSIS_REGISTRY
    if [[ -f "$SCRIPT_DIR/lib/constants.sh" ]]; then
        source "$SCRIPT_DIR/lib/constants.sh"
    else
        KAPSIS_REGISTRY="ghcr.io/aviadshiber"
    fi

    IMAGE_NAME="kapsis-${AGENT_PROFILE}"
    REMOTE_IMAGE="${KAPSIS_REGISTRY}/${IMAGE_NAME}:latest"
    log_info "Pulling pre-built image: ${REMOTE_IMAGE}"
    if podman pull "${REMOTE_IMAGE}"; then
        podman tag "${REMOTE_IMAGE}" "${IMAGE_NAME}:latest"
        log_success "Image ready: ${IMAGE_NAME}:latest"
        podman images "${IMAGE_NAME}"
    else
        log_error "Failed to pull ${REMOTE_IMAGE}"
        log_error "Check available images at: https://github.com/aviadshiber/kapsis/pkgs"
    fi
    exit $?
fi

log_info "Building agent image from profile: $AGENT_PROFILE"

#===============================================================================
# VERIFY YQ (required for YAML parsing)
#===============================================================================
if ! command -v yq &>/dev/null; then
    log_error "yq is required but not installed."
    log_error "Install yq: brew install yq (macOS) or sudo snap install yq (Linux)"
    exit 1
fi

#===============================================================================
# PARSE PROFILE
#===============================================================================
AGENT_NAME=$(yq -r '.name // ""' "$PROFILE_PATH")
AGENT_NPM=$(yq -r '.install.npm // ""' "$PROFILE_PATH")
AGENT_PIP=$(yq -r '.install.pip // ""' "$PROFILE_PATH")
AGENT_SCRIPT=$(yq -r '.install.script // ""' "$PROFILE_PATH")
AGENT_DESC=$(yq -r '.description // ""' "$PROFILE_PATH")

log_info "Agent: $AGENT_NAME"
[[ -n "$AGENT_DESC" ]] && log_info "Description: $AGENT_DESC"
[[ -n "$AGENT_NPM" ]] && log_info "NPM packages: $AGENT_NPM"
[[ -n "$AGENT_PIP" ]] && log_info "PIP packages: $AGENT_PIP"
[[ -n "$AGENT_SCRIPT" ]] && log_info "Install script: $AGENT_SCRIPT"

#===============================================================================
# RESOLVE BUILD CONFIGURATION
#===============================================================================
resolve_build_config() {
    local config_file=""

    # Priority: --build-config > --profile > default
    if [[ -n "$BUILD_CONFIG" ]]; then
        config_file="$BUILD_CONFIG"
    elif [[ -n "$BUILD_PROFILE" ]]; then
        config_file="$KAPSIS_ROOT/configs/build-profiles/${BUILD_PROFILE}.yaml"
    elif [[ -f "$KAPSIS_ROOT/configs/build-config.yaml" ]]; then
        config_file="$KAPSIS_ROOT/configs/build-config.yaml"
    fi

    echo "$config_file"
}

CONFIG_FILE=$(resolve_build_config)

if [[ -n "$CONFIG_FILE" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Build config not found: $CONFIG_FILE"
    exit 1
fi

#===============================================================================
# VALIDATE AGENT DEPENDENCIES
#===============================================================================

# Helper function to read boolean from YAML (handles false correctly)
# The // operator in yq treats false as falsy and applies the default,
# so we need to check for null explicitly
_read_bool() {
    local path="$1"
    local default="$2"
    local file="$3"
    local value
    value=$(yq -r "$path" "$file")
    if [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

validate_agent_dependencies() {
    local agent_profile="$1"
    local config_file="$2"

    # Parse agent dependencies (yq returns empty string if array doesn't exist)
    local deps
    deps=$(yq -r '.dependencies[]' "$agent_profile" 2>/dev/null) || deps=""

    if [[ -z "$deps" ]]; then
        log_info "No dependencies specified in agent profile"
        return 0
    fi

    # If no build config, assume defaults (all enabled)
    if [[ -z "$config_file" ]]; then
        log_info "Using default build config (all languages enabled)"
        return 0
    fi

    log_info "Validating agent dependencies against build config..."

    local errors=0

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        # Extract dependency name (e.g., "nodejs" from "nodejs >= 18")
        local dep_name
        dep_name=$(echo "$dep" | awk '{print $1}')

        case "$dep_name" in
            nodejs|node)
                local enabled
                enabled=$(_read_bool '.languages.nodejs.enabled' "true" "$config_file")
                if [[ "$enabled" != "true" ]]; then
                    log_error "Agent requires Node.js but it's disabled in build config"
                    log_error "  Dependency: $dep"
                    log_error "  Config: $config_file"
                    ((errors++))
                fi
                ;;
            python|python3)
                local enabled
                enabled=$(_read_bool '.languages.python.enabled' "true" "$config_file")
                if [[ "$enabled" != "true" ]]; then
                    log_error "Agent requires Python but it's disabled in build config"
                    log_error "  Dependency: $dep"
                    log_error "  Config: $config_file"
                    ((errors++))
                fi
                ;;
            rust|cargo)
                local enabled
                enabled=$(_read_bool '.languages.rust.enabled' "false" "$config_file")
                if [[ "$enabled" != "true" ]]; then
                    log_error "Agent requires Rust but it's disabled in build config"
                    log_error "  Dependency: $dep"
                    log_error "  Config: $config_file"
                    ((errors++))
                fi
                ;;
            go|golang)
                local enabled
                enabled=$(_read_bool '.languages.go.enabled' "false" "$config_file")
                if [[ "$enabled" != "true" ]]; then
                    log_error "Agent requires Go but it's disabled in build config"
                    log_error "  Dependency: $dep"
                    log_error "  Config: $config_file"
                    ((errors++))
                fi
                ;;
            java)
                local enabled
                enabled=$(_read_bool '.languages.java.enabled' "true" "$config_file")
                if [[ "$enabled" != "true" ]]; then
                    log_error "Agent requires Java but it's disabled in build config"
                    log_error "  Dependency: $dep"
                    log_error "  Config: $config_file"
                    ((errors++))
                fi
                ;;
            git)
                # Git is always available in base image
                ;;
            *)
                log_warn "Unknown dependency: $dep_name (skipping validation)"
                ;;
        esac
    done <<< "$deps"

    if [[ $errors -gt 0 ]]; then
        echo ""
        log_error "═══════════════════════════════════════════════════════════════"
        log_error "DEPENDENCY VALIDATION FAILED"
        log_error "═══════════════════════════════════════════════════════════════"
        log_error "The agent '$AGENT_NAME' requires dependencies that are disabled"
        log_error "in the build configuration."
        log_error ""
        log_error "Options:"
        log_error "  1. Use a different build profile:"
        log_error "     $0 $AGENT_PROFILE --profile full-stack"
        log_error ""
        log_error "  2. Enable the required language in your build config"
        log_error ""
        log_error "  3. Use the default build config (all languages enabled):"
        log_error "     $0 $AGENT_PROFILE"
        log_error "═══════════════════════════════════════════════════════════════"
        return 1
    fi

    log_info "All agent dependencies satisfied ✓"
    return 0
}

# Run dependency validation
if ! validate_agent_dependencies "$PROFILE_PATH" "$CONFIG_FILE"; then
    exit 1
fi

#===============================================================================
# BUILD IMAGE
#===============================================================================
IMAGE_NAME="kapsis-${AGENT_PROFILE}:latest"

log_info "Building image: $IMAGE_NAME"

# Initialize BUILD_ARGS (may be reset by parse_build_config)
BUILD_ARGS=()

# Pass build config args if using a custom config
if [[ -n "$CONFIG_FILE" ]] && [[ -f "$SCRIPT_DIR/lib/build-config.sh" ]]; then
    log_info "Parsing build config: $CONFIG_FILE"

    # Source and parse the build config
    if parse_build_config "$CONFIG_FILE"; then
        # Add all the ENABLE_* build args
        BUILD_ARGS+=("--build-arg" "ENABLE_JAVA=$ENABLE_JAVA")
        BUILD_ARGS+=("--build-arg" "ENABLE_NODEJS=$ENABLE_NODEJS")
        BUILD_ARGS+=("--build-arg" "ENABLE_PYTHON=$ENABLE_PYTHON")
        BUILD_ARGS+=("--build-arg" "ENABLE_RUST=$ENABLE_RUST")
        BUILD_ARGS+=("--build-arg" "ENABLE_GO=$ENABLE_GO")
        BUILD_ARGS+=("--build-arg" "ENABLE_MAVEN=$ENABLE_MAVEN")
        BUILD_ARGS+=("--build-arg" "ENABLE_GRADLE=$ENABLE_GRADLE")
        BUILD_ARGS+=("--build-arg" "ENABLE_GRADLE_ENTERPRISE=$ENABLE_GRADLE_ENTERPRISE")
        BUILD_ARGS+=("--build-arg" "ENABLE_PROTOC=$ENABLE_PROTOC")
        BUILD_ARGS+=("--build-arg" "ENABLE_DEV_TOOLS=$ENABLE_DEV_TOOLS")
        BUILD_ARGS+=("--build-arg" "ENABLE_SHELLS=$ENABLE_SHELLS")
        BUILD_ARGS+=("--build-arg" "ENABLE_UTILITIES=$ENABLE_UTILITIES")
        BUILD_ARGS+=("--build-arg" "ENABLE_OVERLAY=$ENABLE_OVERLAY")

        # Version args
        [[ -n "${JAVA_DEFAULT:-}" ]] && BUILD_ARGS+=("--build-arg" "JAVA_DEFAULT=$JAVA_DEFAULT")
        [[ -n "${NODEJS_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "NODE_VERSION=$NODEJS_VERSION")
        [[ -n "${MAVEN_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "MAVEN_VERSION=$MAVEN_VERSION")
        [[ -n "${GRADLE_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "GRADLE_VERSION=$GRADLE_VERSION")
        [[ -n "${GE_EXT_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "GE_EXT_VERSION=$GE_EXT_VERSION")
        [[ -n "${GE_CCUD_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "GE_CCUD_VERSION=$GE_CCUD_VERSION")
        [[ -n "${PROTOC_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "PROTOC_VERSION=$PROTOC_VERSION")
        [[ -n "${RUST_CHANNEL:-}" ]] && BUILD_ARGS+=("--build-arg" "RUST_CHANNEL=$RUST_CHANNEL")
        [[ -n "${GO_VERSION:-}" ]] && BUILD_ARGS+=("--build-arg" "GO_VERSION=$GO_VERSION")
    else
        log_error "Failed to parse build config: $CONFIG_FILE"
        exit 1
    fi
fi

# Add agent-specific build args AFTER config parsing (which may reset BUILD_ARGS)
[[ -n "$AGENT_NPM" ]] && BUILD_ARGS+=("--build-arg" "AGENT_NPM=$AGENT_NPM")
[[ -n "$AGENT_PIP" ]] && BUILD_ARGS+=("--build-arg" "AGENT_PIP=$AGENT_PIP")
[[ -n "$AGENT_SCRIPT" ]] && BUILD_ARGS+=("--build-arg" "AGENT_SCRIPT=$AGENT_SCRIPT")

#===============================================================================
# RESOLVE PLATFORM AND BASE IMAGE DIGEST
#===============================================================================
# Pinned base image digests per architecture (must match build-image.sh)
# To update: podman manifest inspect docker.io/library/ubuntu:24.04
declare -A BASE_IMAGE_DIGESTS=(
    ["linux/amd64"]="sha256:4fdf0125919d24aec972544669dcd7d6a26a8ad7e6561c73d5549bd6db258ac2"
    ["linux/arm64"]="sha256:955364933d0d91afa6e10fb045948c16d2b191114aa54bed3ab5430d8bbc58cc"
)

detect_platform() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "linux/amd64" ;;
        aarch64|arm64) echo "linux/arm64" ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac
}

PLATFORM=$(detect_platform)
BASE_IMAGE_DIGEST="${BASE_IMAGE_DIGESTS[$PLATFORM]:-}"

if [[ -z "$BASE_IMAGE_DIGEST" ]]; then
    log_error "No pinned digest for platform: $PLATFORM"
    exit 1
fi

BUILD_ARGS+=("--platform" "$PLATFORM")
BUILD_ARGS+=("--build-arg" "BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST")

log_info "Platform: $PLATFORM"
log_info "Base image digest: $BASE_IMAGE_DIGEST"

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

    # Prune dangling images from previous builds with same tag
    dangling_count=$($CONTAINER_RUNTIME images -q --filter "dangling=true" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dangling_count" -gt 0 ]]; then
        log_info "Pruning $dangling_count dangling image(s) from previous builds..."
        $CONTAINER_RUNTIME image prune -f >/dev/null 2>&1 || true
    fi

    echo ""
    echo "To use this image, run:"
    echo "  ./scripts/launch-agent.sh ~/git/products --image $IMAGE_NAME --task \"Your task\""
    echo ""
    echo "Or update your config to use this image:"
    echo "  agent:"
    echo "    image: $IMAGE_NAME"
else
    log_error "Build failed with exit code $BUILD_EXIT"
    exit $BUILD_EXIT
fi
