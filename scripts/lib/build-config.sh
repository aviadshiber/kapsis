#!/usr/bin/env bash
#===============================================================================
# Kapsis Build Configuration Library
#
# Parses build-config.yaml and generates build arguments for the Containerfile.
# Requires: yq (https://github.com/mikefarah/yq)
#
# Usage:
#   source scripts/lib/build-config.sh
#   parse_build_config "configs/build-config.yaml"
#   echo "${BUILD_ARGS[@]}"
#===============================================================================

# Prevent namespace pollution when sourced
if [[ -z "${_KAPSIS_BUILD_CONFIG_LOADED:-}" ]]; then
    _KAPSIS_BUILD_CONFIG_LOADED=1

#===============================================================================
# CONFIGURATION DEFAULTS
#===============================================================================
# These are used when config file is missing or values are not specified

# shellcheck disable=SC2034  # Reserved for future API version checking
declare -g BUILD_CONFIG_VERSION="1.0"

# Language defaults
declare -g DEFAULT_JAVA_ENABLED="true"
declare -g DEFAULT_JAVA_VERSIONS='["17.0.14-zulu","8.0.422-zulu"]'
declare -g DEFAULT_JAVA_DEFAULT="17.0.14-zulu"
declare -g DEFAULT_NODEJS_ENABLED="true"
declare -g DEFAULT_NODEJS_VERSION="18.18.0"
declare -g DEFAULT_PYTHON_ENABLED="true"
declare -g DEFAULT_RUST_ENABLED="false"
declare -g DEFAULT_GO_ENABLED="false"

# Build tool defaults
declare -g DEFAULT_MAVEN_ENABLED="true"
declare -g DEFAULT_MAVEN_VERSION="3.9.9"
declare -g DEFAULT_GRADLE_ENABLED="false"
declare -g DEFAULT_GRADLE_VERSION="8.5"
declare -g DEFAULT_GE_ENABLED="true"
declare -g DEFAULT_GE_EXT_VERSION="1.20"
declare -g DEFAULT_GE_CCUD_VERSION="1.12.5"
declare -g DEFAULT_PROTOC_ENABLED="true"
declare -g DEFAULT_PROTOC_VERSION="25.1"

# System package defaults
declare -g DEFAULT_DEV_TOOLS_ENABLED="true"
declare -g DEFAULT_SHELLS_ENABLED="true"
declare -g DEFAULT_UTILITIES_ENABLED="true"
declare -g DEFAULT_OVERLAY_ENABLED="true"
declare -g DEFAULT_SECRET_STORE_ENABLED="true"

# yq defaults
declare -g DEFAULT_YQ_VERSION="4.44.3"
declare -g DEFAULT_YQ_SHA256="a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"

#===============================================================================
# PARSED VALUES (populated by parse_build_config)
#===============================================================================
declare -g ENABLE_JAVA=""
declare -g JAVA_VERSIONS=""
declare -g JAVA_DEFAULT=""
declare -g ENABLE_NODEJS=""
declare -g NODEJS_VERSION=""
declare -g ENABLE_PYTHON=""
declare -g ENABLE_RUST=""
declare -g RUST_CHANNEL=""
declare -g ENABLE_GO=""
declare -g GO_VERSION=""

declare -g ENABLE_MAVEN=""
declare -g MAVEN_VERSION=""
declare -g ENABLE_GRADLE=""
declare -g GRADLE_VERSION=""
declare -g ENABLE_GRADLE_ENTERPRISE=""
declare -g GE_EXT_VERSION=""
declare -g GE_CCUD_VERSION=""
declare -g ENABLE_PROTOC=""
declare -g PROTOC_VERSION=""

declare -g ENABLE_DEV_TOOLS=""
declare -g ENABLE_SHELLS=""
declare -g ENABLE_UTILITIES=""
declare -g ENABLE_OVERLAY=""
declare -g ENABLE_SECRET_STORE=""
declare -g CUSTOM_PACKAGES=""

declare -g YQ_VERSION=""
declare -g YQ_SHA256=""

declare -g -a BUILD_ARGS=()

#===============================================================================
# check_yq - Verify yq is available
#===============================================================================
check_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required but not installed." >&2
        echo "Install with: brew install yq (macOS) or snap install yq (Linux)" >&2
        return 1
    fi
}

#===============================================================================
# _yq_bool - Read boolean value from YAML with proper false handling
#
# The // operator in yq treats false as falsy and applies the default.
# This function handles false values correctly.
#
# Arguments:
#   $1 - YAML path (e.g., '.languages.java.enabled')
#   $2 - Default value if path is null
#   $3 - Config file path
#===============================================================================
_yq_bool() {
    local path="$1"
    local default="$2"
    local config_file="$3"
    local value

    value=$(yq -r "$path" "$config_file")
    if [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

#===============================================================================
# parse_build_config - Parse build configuration YAML file
#
# Arguments:
#   $1 - Path to build-config.yaml
#
# Sets global variables and BUILD_ARGS array
#===============================================================================
parse_build_config() {
    local config_file="${1:-}"

    check_yq || return 1

    # Use defaults if no config file provided or doesn't exist
    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        if [[ -n "$config_file" ]]; then
            echo "WARNING: Config file not found: $config_file, using defaults" >&2
        fi
        _apply_defaults
        _generate_build_args
        return 0
    fi

    # Validate YAML syntax
    if ! yq eval '.' "$config_file" &>/dev/null; then
        echo "ERROR: Invalid YAML syntax in: $config_file" >&2
        return 1
    fi

    # Parse languages (using _yq_bool for proper false handling)
    ENABLE_JAVA=$(_yq_bool '.languages.java.enabled' "true" "$config_file")
    JAVA_VERSIONS=$(yq -r '.languages.java.versions | @json' "$config_file" 2>/dev/null || echo "$DEFAULT_JAVA_VERSIONS")
    JAVA_DEFAULT=$(yq -r '.languages.java.default_version // "17.0.14-zulu"' "$config_file")

    ENABLE_NODEJS=$(_yq_bool '.languages.nodejs.enabled' "true" "$config_file")
    NODEJS_VERSION=$(yq -r '.languages.nodejs.default_version // "18.18.0"' "$config_file")

    ENABLE_PYTHON=$(_yq_bool '.languages.python.enabled' "true" "$config_file")

    ENABLE_RUST=$(_yq_bool '.languages.rust.enabled' "false" "$config_file")
    RUST_CHANNEL=$(yq -r '.languages.rust.channel // "stable"' "$config_file")

    ENABLE_GO=$(_yq_bool '.languages.go.enabled' "false" "$config_file")
    GO_VERSION=$(yq -r '.languages.go.version // "1.22.0"' "$config_file")

    # Parse build tools
    ENABLE_MAVEN=$(_yq_bool '.build_tools.maven.enabled' "true" "$config_file")
    MAVEN_VERSION=$(yq -r '.build_tools.maven.version // "3.9.9"' "$config_file")

    ENABLE_GRADLE=$(_yq_bool '.build_tools.gradle.enabled' "false" "$config_file")
    GRADLE_VERSION=$(yq -r '.build_tools.gradle.version // "8.5"' "$config_file")

    ENABLE_GRADLE_ENTERPRISE=$(_yq_bool '.build_tools.gradle_enterprise.enabled' "true" "$config_file")
    GE_EXT_VERSION=$(yq -r '.build_tools.gradle_enterprise.extension_version // "1.20"' "$config_file")
    GE_CCUD_VERSION=$(yq -r '.build_tools.gradle_enterprise.ccud_version // "1.12.5"' "$config_file")

    ENABLE_PROTOC=$(_yq_bool '.build_tools.protoc.enabled' "true" "$config_file")
    PROTOC_VERSION=$(yq -r '.build_tools.protoc.version // "25.1"' "$config_file")

    # Parse system packages
    ENABLE_DEV_TOOLS=$(_yq_bool '.system_packages.development.enabled' "true" "$config_file")
    ENABLE_SHELLS=$(_yq_bool '.system_packages.shells.enabled' "true" "$config_file")
    ENABLE_UTILITIES=$(_yq_bool '.system_packages.utilities.enabled' "true" "$config_file")
    ENABLE_OVERLAY=$(_yq_bool '.system_packages.overlay.enabled' "true" "$config_file")
    ENABLE_SECRET_STORE=$(_yq_bool '.system_packages.secret_store.enabled' "true" "$config_file")

    # Parse custom packages as space-separated list
    CUSTOM_PACKAGES=$(yq -r '.system_packages.custom // [] | join(" ")' "$config_file")

    # Parse yq settings
    YQ_VERSION=$(yq -r '.dependency_managers.yq.version // "4.44.3"' "$config_file")
    YQ_SHA256=$(yq -r '.dependency_managers.yq.sha256 // ""' "$config_file")

    _generate_build_args
}

#===============================================================================
# _apply_defaults - Apply default values when no config file is used
#===============================================================================
_apply_defaults() {
    ENABLE_JAVA="$DEFAULT_JAVA_ENABLED"
    JAVA_VERSIONS="$DEFAULT_JAVA_VERSIONS"
    JAVA_DEFAULT="$DEFAULT_JAVA_DEFAULT"

    ENABLE_NODEJS="$DEFAULT_NODEJS_ENABLED"
    NODEJS_VERSION="$DEFAULT_NODEJS_VERSION"

    ENABLE_PYTHON="$DEFAULT_PYTHON_ENABLED"

    ENABLE_RUST="$DEFAULT_RUST_ENABLED"
    RUST_CHANNEL="stable"

    ENABLE_GO="$DEFAULT_GO_ENABLED"
    GO_VERSION="1.22.0"

    ENABLE_MAVEN="$DEFAULT_MAVEN_ENABLED"
    MAVEN_VERSION="$DEFAULT_MAVEN_VERSION"

    ENABLE_GRADLE="$DEFAULT_GRADLE_ENABLED"
    GRADLE_VERSION="$DEFAULT_GRADLE_VERSION"

    ENABLE_GRADLE_ENTERPRISE="$DEFAULT_GE_ENABLED"
    GE_EXT_VERSION="$DEFAULT_GE_EXT_VERSION"
    GE_CCUD_VERSION="$DEFAULT_GE_CCUD_VERSION"

    ENABLE_PROTOC="$DEFAULT_PROTOC_ENABLED"
    PROTOC_VERSION="$DEFAULT_PROTOC_VERSION"

    ENABLE_DEV_TOOLS="$DEFAULT_DEV_TOOLS_ENABLED"
    ENABLE_SHELLS="$DEFAULT_SHELLS_ENABLED"
    ENABLE_UTILITIES="$DEFAULT_UTILITIES_ENABLED"
    ENABLE_OVERLAY="$DEFAULT_OVERLAY_ENABLED"
    ENABLE_SECRET_STORE="$DEFAULT_SECRET_STORE_ENABLED"
    CUSTOM_PACKAGES=""

    YQ_VERSION="$DEFAULT_YQ_VERSION"
    YQ_SHA256="$DEFAULT_YQ_SHA256"
}

#===============================================================================
# _generate_build_args - Generate BUILD_ARGS array for podman build
#===============================================================================
_generate_build_args() {
    BUILD_ARGS=(
        # Language toggles
        "--build-arg" "ENABLE_JAVA=$ENABLE_JAVA"
        "--build-arg" "ENABLE_NODEJS=$ENABLE_NODEJS"
        "--build-arg" "ENABLE_PYTHON=$ENABLE_PYTHON"
        "--build-arg" "ENABLE_RUST=$ENABLE_RUST"
        "--build-arg" "ENABLE_GO=$ENABLE_GO"

        # Java configuration
        "--build-arg" "JAVA_VERSIONS=$JAVA_VERSIONS"
        "--build-arg" "JAVA_DEFAULT=$JAVA_DEFAULT"

        # Node.js configuration
        "--build-arg" "NODE_VERSION=$NODEJS_VERSION"

        # Rust configuration
        "--build-arg" "RUST_CHANNEL=$RUST_CHANNEL"

        # Go configuration
        "--build-arg" "GO_VERSION=$GO_VERSION"

        # Build tool toggles
        "--build-arg" "ENABLE_MAVEN=$ENABLE_MAVEN"
        "--build-arg" "ENABLE_GRADLE=$ENABLE_GRADLE"
        "--build-arg" "ENABLE_GRADLE_ENTERPRISE=$ENABLE_GRADLE_ENTERPRISE"
        "--build-arg" "ENABLE_PROTOC=$ENABLE_PROTOC"

        # Build tool versions
        "--build-arg" "MAVEN_VERSION=$MAVEN_VERSION"
        "--build-arg" "GRADLE_VERSION=$GRADLE_VERSION"
        "--build-arg" "GE_EXT_VERSION=$GE_EXT_VERSION"
        "--build-arg" "GE_CCUD_VERSION=$GE_CCUD_VERSION"
        "--build-arg" "PROTOC_VERSION=$PROTOC_VERSION"

        # System package toggles
        "--build-arg" "ENABLE_DEV_TOOLS=$ENABLE_DEV_TOOLS"
        "--build-arg" "ENABLE_SHELLS=$ENABLE_SHELLS"
        "--build-arg" "ENABLE_UTILITIES=$ENABLE_UTILITIES"
        "--build-arg" "ENABLE_OVERLAY=$ENABLE_OVERLAY"
        "--build-arg" "ENABLE_SECRET_STORE=$ENABLE_SECRET_STORE"
        "--build-arg" "CUSTOM_PACKAGES=$CUSTOM_PACKAGES"

        # yq configuration
        "--build-arg" "YQ_VERSION=$YQ_VERSION"
    )

    # Only add SHA256 if provided
    if [[ -n "$YQ_SHA256" ]]; then
        BUILD_ARGS+=("--build-arg" "YQ_SHA256=$YQ_SHA256")
    fi
}

#===============================================================================
# get_build_args - Return BUILD_ARGS as a string (for debugging/display)
#===============================================================================
get_build_args() {
    printf '%s\n' "${BUILD_ARGS[@]}"
}

#===============================================================================
# print_config_summary - Print human-readable config summary
#===============================================================================
print_config_summary() {
    echo "Build Configuration Summary:"
    echo "──────────────────────────────────────────────────────────────"
    echo ""
    echo "Languages:"
    echo "  Java:    ${ENABLE_JAVA} (default: ${JAVA_DEFAULT})"
    echo "  Node.js: ${ENABLE_NODEJS} (version: ${NODEJS_VERSION})"
    echo "  Python:  ${ENABLE_PYTHON}"
    echo "  Rust:    ${ENABLE_RUST} (channel: ${RUST_CHANNEL})"
    echo "  Go:      ${ENABLE_GO} (version: ${GO_VERSION})"
    echo ""
    echo "Build Tools:"
    echo "  Maven:   ${ENABLE_MAVEN} (version: ${MAVEN_VERSION})"
    echo "  Gradle:  ${ENABLE_GRADLE} (version: ${GRADLE_VERSION})"
    echo "  GE Ext:  ${ENABLE_GRADLE_ENTERPRISE} (v${GE_EXT_VERSION})"
    echo "  Protoc:  ${ENABLE_PROTOC} (version: ${PROTOC_VERSION})"
    echo ""
    echo "System Packages:"
    echo "  Dev Tools: ${ENABLE_DEV_TOOLS}"
    echo "  Shells:    ${ENABLE_SHELLS}"
    echo "  Utilities: ${ENABLE_UTILITIES}"
    echo "  Overlay:   ${ENABLE_OVERLAY}"
    echo "  Secret Store: ${ENABLE_SECRET_STORE}"
    if [[ -n "$CUSTOM_PACKAGES" ]]; then
        echo "  Custom:    ${CUSTOM_PACKAGES}"
    fi
    echo ""
}

#===============================================================================
# estimate_image_size - Estimate resulting image size based on config
#===============================================================================
estimate_image_size() {
    local size_mb=300  # Base Ubuntu image

    [[ "$ENABLE_JAVA" == "true" ]] && size_mb=$((size_mb + 600))
    [[ "$ENABLE_NODEJS" == "true" ]] && size_mb=$((size_mb + 200))
    [[ "$ENABLE_PYTHON" == "true" ]] && size_mb=$((size_mb + 100))
    [[ "$ENABLE_RUST" == "true" ]] && size_mb=$((size_mb + 400))
    [[ "$ENABLE_GO" == "true" ]] && size_mb=$((size_mb + 300))

    [[ "$ENABLE_MAVEN" == "true" ]] && size_mb=$((size_mb + 50))
    [[ "$ENABLE_GRADLE" == "true" ]] && size_mb=$((size_mb + 100))
    [[ "$ENABLE_GRADLE_ENTERPRISE" == "true" ]] && size_mb=$((size_mb + 20))
    [[ "$ENABLE_PROTOC" == "true" ]] && size_mb=$((size_mb + 30))

    [[ "$ENABLE_DEV_TOOLS" == "true" ]] && size_mb=$((size_mb + 150))
    [[ "$ENABLE_SHELLS" == "true" ]] && size_mb=$((size_mb + 20))
    [[ "$ENABLE_UTILITIES" == "true" ]] && size_mb=$((size_mb + 30))
    [[ "$ENABLE_OVERLAY" == "true" ]] && size_mb=$((size_mb + 10))
    [[ "$ENABLE_SECRET_STORE" == "true" ]] && size_mb=$((size_mb + 6))

    # Convert to GB if over 1000MB
    if [[ $size_mb -ge 1000 ]]; then
        local size_gb
        size_gb=$(awk "BEGIN {printf \"%.1f\", $size_mb / 1024}")
        echo "~${size_gb}GB"
    else
        echo "~${size_mb}MB"
    fi
}

#===============================================================================
# export_config_json - Export configuration as JSON (for AI agents)
#===============================================================================
export_config_json() {
    cat <<EOF
{
  "languages": {
    "java": {"enabled": $ENABLE_JAVA, "versions": $JAVA_VERSIONS, "default_version": "$JAVA_DEFAULT"},
    "nodejs": {"enabled": $ENABLE_NODEJS, "version": "$NODEJS_VERSION"},
    "python": {"enabled": $ENABLE_PYTHON},
    "rust": {"enabled": $ENABLE_RUST, "channel": "$RUST_CHANNEL"},
    "go": {"enabled": $ENABLE_GO, "version": "$GO_VERSION"}
  },
  "build_tools": {
    "maven": {"enabled": $ENABLE_MAVEN, "version": "$MAVEN_VERSION"},
    "gradle": {"enabled": $ENABLE_GRADLE, "version": "$GRADLE_VERSION"},
    "gradle_enterprise": {"enabled": $ENABLE_GRADLE_ENTERPRISE, "extension_version": "$GE_EXT_VERSION"},
    "protoc": {"enabled": $ENABLE_PROTOC, "version": "$PROTOC_VERSION"}
  },
  "system_packages": {
    "development": {"enabled": $ENABLE_DEV_TOOLS},
    "shells": {"enabled": $ENABLE_SHELLS},
    "utilities": {"enabled": $ENABLE_UTILITIES},
    "overlay": {"enabled": $ENABLE_OVERLAY},
    "secret_store": {"enabled": $ENABLE_SECRET_STORE}
  },
  "estimated_size": "$(estimate_image_size)"
}
EOF
}

fi  # End of _KAPSIS_BUILD_CONFIG_LOADED guard
