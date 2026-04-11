#!/usr/bin/env bash
#===============================================================================
# Kapsis Dependency Configuration CLI
#
# Configure container dependencies interactively or via command-line flags.
# Supports both human (TTY) and AI agent (non-interactive) modes.
#
# Usage:
#   ./scripts/configure-deps.sh                       # Interactive mode
#   ./scripts/configure-deps.sh --profile java-dev    # Apply profile
#   ./scripts/configure-deps.sh --enable rust --json  # Non-interactive
#
# Exit Codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Config file not found
#   3 - Invalid configuration value
#   4 - Failed to write config
#   5 - TTY required but not available
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

# Source logging library
if [[ -f "$SCRIPT_DIR/lib/logging.sh" ]]; then
    source "$SCRIPT_DIR/lib/logging.sh"
    log_init "configure-deps"
else
    # Fallback logging
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
    log_debug() { [[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] $*"; }
fi

# Source build config library
source "$SCRIPT_DIR/lib/build-config.sh"

#===============================================================================
# CONSTANTS
#===============================================================================
DEFAULT_CONFIG="$KAPSIS_ROOT/configs/build-config.yaml"
PROFILES_DIR="$KAPSIS_ROOT/configs/build-profiles"

# Colors (disable if NO_COLOR or not TTY)
# shellcheck disable=SC2034  # YELLOW reserved for future warning messages
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    CYAN='' GREEN='' YELLOW='' RED='' BOLD='' NC=''
fi

#===============================================================================
# AVAILABLE PROFILES
#===============================================================================
declare -A PROFILES=(
    ["minimal"]="Base only (~500MB)"
    ["java-dev"]="Java + Maven + GE (~1.5GB)"
    ["java8-legacy"]="Java 8 only (~1.3GB)"
    ["full-stack"]="Java + Node + Python (~2.1GB)"
    ["backend-go"]="Go + Python (~1.2GB)"
    ["backend-rust"]="Rust + Python (~1.4GB)"
    ["ml-python"]="Python + Node + Rust (~1.8GB)"
    ["frontend"]="Node + Rust (~1.2GB)"
)

#===============================================================================
# AVAILABLE DEPENDENCIES
#===============================================================================
declare -A DEPENDENCIES=(
    ["java"]="languages.java.enabled"
    ["nodejs"]="languages.nodejs.enabled"
    ["python"]="languages.python.enabled"
    ["rust"]="languages.rust.enabled"
    ["go"]="languages.go.enabled"
    ["maven"]="build_tools.maven.enabled"
    ["gradle"]="build_tools.gradle.enabled"
    ["gradle_enterprise"]="build_tools.gradle_enterprise.enabled"
    ["protoc"]="build_tools.protoc.enabled"
    ["development"]="system_packages.development.enabled"
    ["shells"]="system_packages.shells.enabled"
    ["utilities"]="system_packages.utilities.enabled"
    ["overlay"]="system_packages.overlay.enabled"
)

#===============================================================================
# GLOBAL STATE
#===============================================================================
CONFIG_FILE="$DEFAULT_CONFIG"
OUTPUT_FILE=""
DRY_RUN=false
JSON_OUTPUT=false
PROFILE=""
declare -a ENABLE_DEPS=()
declare -a DISABLE_DEPS=()
declare -a SET_VALUES=()
declare -a ADD_JAVA_VERSIONS=()
JSON_INPUT_FILE=""
CHANGES=()

#===============================================================================
# usage - Print help message
#===============================================================================
usage() {
    cat <<EOF
${BOLD}Usage:${NC} configure-deps.sh [mode] [options]

${BOLD}Modes:${NC}
  (default)             Interactive menu mode (TTY required)
  --profile <name>      Apply a preset profile
  --enable <dep>        Enable a dependency
  --disable <dep>       Disable a dependency
  --set <key=value>     Set a specific YAML value
  --add-java-version <v> Add a Java version (free text, e.g., 25.0.1-tem)
  --from-json <file>    Load configuration from JSON file

${BOLD}Options:${NC}
  -c, --config <file>   Config file to modify (default: configs/build-config.yaml)
  -o, --output <file>   Output file (default: modifies in-place)
  --dry-run             Preview changes without writing
  --json                Machine-readable JSON output
  --no-color            Disable ANSI colors
  --export              Export current config as JSON
  --list-profiles       List available profiles
  --list-deps           List available dependencies
  -h, --help            Show this help message

${BOLD}Profiles:${NC}
  minimal               Base image only (~500MB)
  java-dev              Java + Maven + GE (~1.5GB)
  java8-legacy          Java 8 only (~1.3GB)
  full-stack            Java + Node + Python (~2.1GB) [default]
  backend-go            Go + Python (~1.2GB)
  backend-rust          Rust + Python (~1.4GB)
  ml-python             Python + Node + Rust (~1.8GB)
  frontend              Node + Rust (~1.2GB)

${BOLD}Dependency Names:${NC}
  java, nodejs, python, rust, go
  maven, gradle, gradle_enterprise, protoc
  development, shells, utilities, overlay

${BOLD}Examples:${NC}
  # Interactive mode (humans)
  ${CYAN}configure-deps.sh${NC}

  # Apply java-dev profile
  ${CYAN}configure-deps.sh --profile java-dev${NC}

  # Enable Rust, disable Node.js
  ${CYAN}configure-deps.sh --enable rust --disable nodejs${NC}

  # Set specific Java versions
  ${CYAN}configure-deps.sh --set 'languages.java.default_version=8.0.422-zulu'${NC}

  # Add a custom Java version
  ${CYAN}configure-deps.sh --add-java-version "25.0.1-tem"${NC}

  # Load from JSON (AI agents)
  ${CYAN}configure-deps.sh --from-json config.json --json${NC}

  # Export current config as JSON
  ${CYAN}configure-deps.sh --export --json${NC}

  # Dry-run preview
  ${CYAN}configure-deps.sh --profile minimal --dry-run${NC}
EOF
}

#===============================================================================
# parse_args - Parse command line arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --enable)
                ENABLE_DEPS+=("$2")
                shift 2
                ;;
            --disable)
                DISABLE_DEPS+=("$2")
                shift 2
                ;;
            --set)
                SET_VALUES+=("$2")
                shift 2
                ;;
            --add-java-version)
                ADD_JAVA_VERSIONS+=("$2")
                shift 2
                ;;
            --from-json)
                JSON_INPUT_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --no-color)
                # shellcheck disable=SC2034  # YELLOW reserved for future use
                CYAN='' GREEN='' YELLOW='' RED='' BOLD='' NC=''
                shift
                ;;
            --export)
                export_config
                exit 0
                ;;
            --list-profiles)
                list_profiles
                exit 0
                ;;
            --list-deps)
                list_dependencies
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# list_profiles - List available profiles
#===============================================================================
list_profiles() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        local first=true
        for profile in "${!PROFILES[@]}"; do
            [[ "$first" != "true" ]] && echo ","
            echo "  \"$profile\": \"${PROFILES[$profile]}\""
            first=false
        done
        echo "}"
    else
        echo "${BOLD}Available Profiles:${NC}"
        for profile in minimal java-dev java8-legacy full-stack backend-go backend-rust ml-python frontend; do
            printf "  %-15s %s\n" "$profile" "${PROFILES[$profile]}"
        done
    fi
}

#===============================================================================
# list_dependencies - List available dependencies
#===============================================================================
list_dependencies() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        local first=true
        for dep in "${!DEPENDENCIES[@]}"; do
            [[ "$first" != "true" ]] && echo ","
            echo "  \"$dep\": \"${DEPENDENCIES[$dep]}\""
            first=false
        done
        echo "}"
    else
        echo "${BOLD}Available Dependencies:${NC}"
        echo "  Languages:"
        echo "    java, nodejs, python, rust, go"
        echo "  Build Tools:"
        echo "    maven, gradle, gradle_enterprise, protoc"
        echo "  System Packages:"
        echo "    development, shells, utilities, overlay"
    fi
}

#===============================================================================
# export_config - Export current configuration as JSON
#===============================================================================
export_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 2
    fi

    parse_build_config "$CONFIG_FILE"
    export_config_json
}

#===============================================================================
# apply_profile - Apply a profile preset
#===============================================================================
apply_profile() {
    local profile="$1"
    local profile_file="$PROFILES_DIR/${profile}.yaml"

    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile not found: $profile"
        log_error "Available profiles: ${!PROFILES[*]}"
        exit 3
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        CHANGES+=("Would apply profile: $profile")
        return
    fi

    local target="${OUTPUT_FILE:-$CONFIG_FILE}"
    cp "$profile_file" "$target"
    CHANGES+=("Applied profile: $profile")
}

#===============================================================================
# set_dependency - Enable or disable a dependency
#===============================================================================
set_dependency() {
    local dep="$1"
    local enabled="$2"

    if [[ -z "${DEPENDENCIES[$dep]:-}" ]]; then
        log_error "Unknown dependency: $dep"
        list_dependencies
        exit 3
    fi

    local yaml_path="${DEPENDENCIES[$dep]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        CHANGES+=("Would set $yaml_path = $enabled")
        return
    fi

    local target="${OUTPUT_FILE:-$CONFIG_FILE}"
    yq -i ".$yaml_path = $enabled" "$target"
    CHANGES+=("Set $yaml_path = $enabled")
}

#===============================================================================
# set_value - Set a specific YAML value
#===============================================================================
set_value() {
    local keyval="$1"
    local key="${keyval%%=*}"
    local value="${keyval#*=}"

    if [[ "$DRY_RUN" == "true" ]]; then
        CHANGES+=("Would set $key = $value")
        return
    fi

    local target="${OUTPUT_FILE:-$CONFIG_FILE}"

    # Detect if value is JSON array/object or scalar
    if [[ "$value" =~ ^\[.*\]$ ]] || [[ "$value" =~ ^\{.*\}$ ]]; then
        # JSON value
        yq -i ".$key = $value" "$target"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        # Numeric value
        yq -i ".$key = $value" "$target"
    elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        # Boolean value
        yq -i ".$key = $value" "$target"
    else
        # String value
        yq -i ".$key = \"$value\"" "$target"
    fi

    CHANGES+=("Set $key = $value")
}

#===============================================================================
# add_java_version - Add a Java version to the list
#===============================================================================
add_java_version() {
    local version="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        CHANGES+=("Would add Java version: $version")
        return
    fi

    local target="${OUTPUT_FILE:-$CONFIG_FILE}"

    # Check if version already exists
    local exists
    exists=$(yq ".languages.java.versions | contains([\"$version\"])" "$target")

    if [[ "$exists" == "true" ]]; then
        CHANGES+=("Java version already exists: $version")
        return
    fi

    yq -i ".languages.java.versions += [\"$version\"]" "$target"
    CHANGES+=("Added Java version: $version")
}

#===============================================================================
# apply_json_input - Apply configuration from JSON file
#===============================================================================
apply_json_input() {
    local json_file="$1"

    if [[ ! -f "$json_file" ]]; then
        log_error "JSON input file not found: $json_file"
        exit 2
    fi

    # Validate JSON
    if ! jq empty "$json_file" 2>/dev/null; then
        log_error "Invalid JSON in: $json_file"
        exit 3
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        CHANGES+=("Would apply JSON config from: $json_file")
        return
    fi

    local target="${OUTPUT_FILE:-$CONFIG_FILE}"

    # Extract and apply each field from JSON
    # Languages
    for lang in java nodejs python rust go; do
        local enabled
        enabled=$(jq -r ".languages.$lang.enabled // empty" "$json_file")
        if [[ -n "$enabled" ]]; then
            yq -i ".languages.$lang.enabled = $enabled" "$target"
            CHANGES+=("Set languages.$lang.enabled = $enabled")
        fi
    done

    # Java versions
    local java_versions
    java_versions=$(jq -r '.languages.java.versions // empty' "$json_file")
    if [[ -n "$java_versions" ]] && [[ "$java_versions" != "null" ]]; then
        yq -i ".languages.java.versions = $java_versions" "$target"
        CHANGES+=("Set languages.java.versions")
    fi

    # Build tools
    for tool in maven gradle gradle_enterprise protoc; do
        local enabled
        enabled=$(jq -r ".build_tools.$tool.enabled // empty" "$json_file")
        if [[ -n "$enabled" ]]; then
            yq -i ".build_tools.$tool.enabled = $enabled" "$target"
            CHANGES+=("Set build_tools.$tool.enabled = $enabled")
        fi
    done
}

#===============================================================================
# output_result - Output result (JSON or text)
#===============================================================================
output_result() {
    local success="$1"
    local target="${OUTPUT_FILE:-$CONFIG_FILE}"

    parse_build_config "$target"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local changes_json="[]"
        if [[ ${#CHANGES[@]} -gt 0 ]]; then
            changes_json=$(printf '%s\n' "${CHANGES[@]}" | jq -R . | jq -s .)
        fi

        # Determine profile name from target file if it's a profile
        local profile_name="null"
        if [[ "$target" == *"/build-profiles/"* ]]; then
            profile_name="\"$(basename "${target%.yaml}")\""
        fi

        cat <<EOF
{
  "success": $success,
  "profile": $profile_name,
  "config_file": "$target",
  "dry_run": $DRY_RUN,
  "changes": $changes_json,
  "estimated_size": "$(estimate_image_size)",
  "build_command": "./scripts/build-image.sh --build-config $target"
}
EOF
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            echo ""
            echo "${BOLD}Dry Run - Changes that would be made:${NC}"
        else
            echo ""
            echo "${BOLD}Changes applied:${NC}"
        fi

        for change in "${CHANGES[@]}"; do
            echo "  - $change"
        done

        echo ""
        print_config_summary
        echo ""
        echo "${GREEN}Estimated image size: $(estimate_image_size)${NC}"
        echo ""
        echo "Build command:"
        echo "  ${CYAN}./scripts/build-image.sh --build-config $target${NC}"
    fi
}

#===============================================================================
# INTERACTIVE MODE FUNCTIONS
#===============================================================================

#===============================================================================
# show_header - Display header box
#===============================================================================
show_header() {
    clear
    echo ""
    echo "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "${CYAN}║${NC}           ${BOLD}KAPSIS DEPENDENCY CONFIGURATION${NC}                         ${CYAN}║${NC}"
    echo "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#===============================================================================
# show_main_menu - Display main menu
#===============================================================================
show_main_menu() {
    parse_build_config "$CONFIG_FILE"

    show_header
    echo "Current config: ${CYAN}$CONFIG_FILE${NC}"
    echo "Estimated size: ${GREEN}$(estimate_image_size)${NC}"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}MAIN MENU${NC}                                                           │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│                                                                     │"
    echo "│  [${CYAN}1${NC}] Apply Profile Preset                                           │"
    echo "│  [${CYAN}2${NC}] Configure Languages                                            │"
    echo "│  [${CYAN}3${NC}] Configure Build Tools                                          │"
    echo "│  [${CYAN}4${NC}] Configure System Packages                                      │"
    echo "│  [${CYAN}5${NC}] Preview Changes                                                │"
    echo "│  [${CYAN}6${NC}] Save and Exit                                                  │"
    echo "│  [${CYAN}Q${NC}] Quit without saving                                            │"
    echo "│                                                                     │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select option [1-6, Q]: "
}

#===============================================================================
# show_profile_menu - Display profile selection menu
#===============================================================================
show_profile_menu() {
    show_header
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}SELECT PROFILE${NC}                                                      │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│                                                                     │"
    echo "│  [${CYAN}1${NC}] minimal       - Base only                      (~500MB)        │"
    echo "│  [${CYAN}2${NC}] java-dev      - Java + Maven + GE             (~1.5GB)        │"
    echo "│  [${CYAN}3${NC}] java8-legacy  - Java 8 only                   (~1.3GB)        │"
    echo "│  [${CYAN}4${NC}] full-stack    - Java + Node + Python          (~2.1GB)        │"
    echo "│  [${CYAN}5${NC}] backend-go    - Go + Python                   (~1.2GB)        │"
    echo "│  [${CYAN}6${NC}] backend-rust  - Rust + Python                 (~1.4GB)        │"
    echo "│  [${CYAN}7${NC}] ml-python     - Python + Node + Rust          (~1.8GB)        │"
    echo "│  [${CYAN}8${NC}] frontend      - Node + Rust                   (~1.2GB)        │"
    echo "│                                                                     │"
    echo "│  [${CYAN}B${NC}] Back to main menu                                              │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select profile [1-8, B]: "
}

#===============================================================================
# show_languages_menu - Display languages configuration menu
#===============================================================================
show_languages_menu() {
    parse_build_config "$CONFIG_FILE"

    local java_status="[${RED}disabled${NC}]"
    local nodejs_status="[${RED}disabled${NC}]"
    local python_status="[${RED}disabled${NC}]"
    local rust_status="[${RED}disabled${NC}]"
    local go_status="[${RED}disabled${NC}]"

    [[ "$ENABLE_JAVA" == "true" ]] && java_status="[${GREEN}ENABLED${NC}]"
    [[ "$ENABLE_NODEJS" == "true" ]] && nodejs_status="[${GREEN}ENABLED${NC}]"
    [[ "$ENABLE_PYTHON" == "true" ]] && python_status="[${GREEN}ENABLED${NC}]"
    [[ "$ENABLE_RUST" == "true" ]] && rust_status="[${GREEN}ENABLED${NC}]"
    [[ "$ENABLE_GO" == "true" ]] && go_status="[${GREEN}ENABLED${NC}]"

    show_header
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}CONFIGURE LANGUAGES${NC}                                                 │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│  [${CYAN}1${NC}] Java      %-12b   %-35s │\n" "$java_status" "$JAVA_DEFAULT"
    printf "│  [${CYAN}2${NC}] Node.js   %-12b   %-35s │\n" "$nodejs_status" "$NODEJS_VERSION"
    printf "│  [${CYAN}3${NC}] Python    %-12b   %-35s │\n" "$python_status" "system"
    printf "│  [${CYAN}4${NC}] Rust      %-12b   %-35s │\n" "$rust_status" "$RUST_CHANNEL"
    printf "│  [${CYAN}5${NC}] Go        %-12b   %-35s │\n" "$go_status" "$GO_VERSION"
    echo "│                                                                     │"
    echo "│  [${CYAN}B${NC}] Back to main menu                                              │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select [1-5] to toggle/configure, [B] to go back: "
}

#===============================================================================
# show_java_menu - Display Java configuration menu
#===============================================================================
show_java_menu() {
    parse_build_config "$CONFIG_FILE"

    show_header
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}CONFIGURE JAVA${NC}                                                      │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    echo "│                                                                     │"
    if [[ "$ENABLE_JAVA" == "true" ]]; then
        echo "│  Status: ${GREEN}ENABLED${NC}                                                    │"
    else
        echo "│  Status: ${RED}DISABLED${NC}                                                   │"
    fi
    echo "│  Default: ${CYAN}$JAVA_DEFAULT${NC}"
    echo "│                                                                     │"
    echo "│  Installed versions:                                                │"

    # Parse versions from JSON array (JAVA_VERSIONS is set by build-config.sh)
    local versions
    # shellcheck disable=SC2153  # JAVA_VERSIONS is exported from build-config.sh
    versions=$(echo "$JAVA_VERSIONS" | jq -r '.[]' 2>/dev/null || echo "")
    local i=1
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            local marker=" "
            [[ "$version" == "$JAVA_DEFAULT" ]] && marker="*"
            printf "│    %s %d. %-55s │\n" "$marker" "$i" "$version"
            ((i++))
        fi
    done <<< "$versions"

    echo "│                                                                     │"
    echo "│  Common distributions: ${CYAN}zulu, tem, amzn, librca, graalce, ms${NC}        │"
    echo "│                                                                     │"
    echo "│  [${CYAN}T${NC}] Toggle enabled/disabled                                        │"
    echo "│  [${CYAN}D${NC}] Change default version                                         │"
    echo "│  [${CYAN}A${NC}] Add custom version (free text, e.g., 25.0.1-tem)              │"
    echo "│  [${CYAN}R${NC}] Remove a version                                               │"
    echo "│  [${CYAN}B${NC}] Back                                                           │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select option: "
}

#===============================================================================
# interactive_mode - Run interactive menu mode
#===============================================================================
interactive_mode() {
    # Check if TTY is available
    if [[ ! -t 0 ]]; then
        log_error "Interactive mode requires a TTY"
        log_error "Use --profile, --enable, or --disable for non-interactive mode"
        exit 5
    fi

    local running=true

    while [[ "$running" == "true" ]]; do
        show_main_menu
        read -r choice

        case "${choice,,}" in
            1)
                profile_menu
                ;;
            2)
                languages_menu
                ;;
            3)
                build_tools_menu
                ;;
            4)
                system_packages_menu
                ;;
            5)
                preview_changes
                ;;
            6)
                save_and_exit
                running=false
                ;;
            q)
                echo ""
                echo "Exiting without saving."
                running=false
                ;;
            *)
                echo "${RED}Invalid option. Press Enter to continue.${NC}"
                read -r
                ;;
        esac
    done
}

#===============================================================================
# profile_menu - Handle profile selection
#===============================================================================
profile_menu() {
    local profiles_arr=(minimal java-dev java8-legacy full-stack backend-go backend-rust ml-python frontend)

    show_profile_menu
    read -r choice

    case "${choice,,}" in
        [1-8])
            local idx=$((choice - 1))
            local selected="${profiles_arr[$idx]}"
            apply_profile "$selected"
            echo ""
            echo "${GREEN}Applied profile: $selected${NC}"
            echo "Press Enter to continue."
            read -r
            ;;
        b)
            return
            ;;
        *)
            echo "${RED}Invalid option.${NC}"
            read -r
            ;;
    esac
}

#===============================================================================
# languages_menu - Handle language configuration
#===============================================================================
languages_menu() {
    local running=true

    while [[ "$running" == "true" ]]; do
        show_languages_menu
        read -r choice

        case "${choice,,}" in
            1)
                java_menu
                ;;
            2)
                toggle_dependency "nodejs"
                ;;
            3)
                toggle_dependency "python"
                ;;
            4)
                toggle_dependency "rust"
                ;;
            5)
                toggle_dependency "go"
                ;;
            b)
                running=false
                ;;
            *)
                echo "${RED}Invalid option.${NC}"
                read -r
                ;;
        esac
    done
}

#===============================================================================
# java_menu - Handle Java configuration
#===============================================================================
java_menu() {
    local running=true

    while [[ "$running" == "true" ]]; do
        show_java_menu
        read -r choice

        case "${choice,,}" in
            t)
                toggle_dependency "java"
                ;;
            d)
                echo -n "Enter new default version: "
                read -r new_default
                if [[ -n "$new_default" ]]; then
                    set_value "languages.java.default_version=$new_default"
                    echo "${GREEN}Default set to: $new_default${NC}"
                fi
                read -r
                ;;
            a)
                echo ""
                echo "Enter Java version (SDKMAN format, e.g., 25.0.1-tem):"
                echo -n "> "
                read -r new_version
                if [[ -n "$new_version" ]]; then
                    add_java_version "$new_version"
                    echo "${GREEN}Added version: $new_version${NC}"
                fi
                read -r
                ;;
            r)
                echo ""
                echo -n "Enter version to remove: "
                read -r rm_version
                if [[ -n "$rm_version" ]]; then
                    yq -i ".languages.java.versions -= [\"$rm_version\"]" "$CONFIG_FILE"
                    CHANGES+=("Removed Java version: $rm_version")
                    echo "${GREEN}Removed: $rm_version${NC}"
                fi
                read -r
                ;;
            b)
                running=false
                ;;
            *)
                echo "${RED}Invalid option.${NC}"
                read -r
                ;;
        esac
    done
}

#===============================================================================
# toggle_dependency - Toggle a dependency on/off
#===============================================================================
toggle_dependency() {
    local dep="$1"
    parse_build_config "$CONFIG_FILE"

    local current_var="ENABLE_${dep^^}"
    current_var="${current_var//-/_}"

    local current="${!current_var:-false}"
    local new_value="true"
    [[ "$current" == "true" ]] && new_value="false"

    set_dependency "$dep" "$new_value"
    echo ""
    echo "${GREEN}$dep is now: $new_value${NC}"
    echo "Press Enter to continue."
    read -r
}

#===============================================================================
# build_tools_menu - Handle build tools configuration (simplified)
#===============================================================================
build_tools_menu() {
    parse_build_config "$CONFIG_FILE"

    show_header
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}CONFIGURE BUILD TOOLS${NC}                                               │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│  [${CYAN}1${NC}] Maven              %-43s │\n" "[$([[ $ENABLE_MAVEN == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}2${NC}] Gradle             %-43s │\n" "[$([[ $ENABLE_GRADLE == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}3${NC}] Gradle Enterprise  %-43s │\n" "[$([[ $ENABLE_GRADLE_ENTERPRISE == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}4${NC}] Protoc             %-43s │\n" "[$([[ $ENABLE_PROTOC == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    echo "│                                                                     │"
    echo "│  [${CYAN}B${NC}] Back to main menu                                              │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select [1-4] to toggle, [B] to go back: "

    read -r choice
    case "${choice,,}" in
        1) toggle_dependency "maven" ;;
        2) toggle_dependency "gradle" ;;
        3) toggle_dependency "gradle_enterprise" ;;
        4) toggle_dependency "protoc" ;;
        b) return ;;
        *) echo "${RED}Invalid option.${NC}"; read -r ;;
    esac
}

#===============================================================================
# system_packages_menu - Handle system packages configuration (simplified)
#===============================================================================
system_packages_menu() {
    parse_build_config "$CONFIG_FILE"

    show_header
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│ ${BOLD}CONFIGURE SYSTEM PACKAGES${NC}                                           │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│  [${CYAN}1${NC}] Development tools  %-43s │\n" "[$([[ $ENABLE_DEV_TOOLS == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}2${NC}] Shells             %-43s │\n" "[$([[ $ENABLE_SHELLS == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}3${NC}] Utilities          %-43s │\n" "[$([[ $ENABLE_UTILITIES == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    printf "│  [${CYAN}4${NC}] Overlay (FUSE)     %-43s │\n" "[$([[ $ENABLE_OVERLAY == true ]] && echo "${GREEN}ENABLED${NC}" || echo "${RED}disabled${NC}")]"
    echo "│                                                                     │"
    echo "│  [${CYAN}B${NC}] Back to main menu                                              │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -n "Select [1-4] to toggle, [B] to go back: "

    read -r choice
    case "${choice,,}" in
        1) toggle_dependency "development" ;;
        2) toggle_dependency "shells" ;;
        3) toggle_dependency "utilities" ;;
        4) toggle_dependency "overlay" ;;
        b) return ;;
        *) echo "${RED}Invalid option.${NC}"; read -r ;;
    esac
}

#===============================================================================
# preview_changes - Show current configuration
#===============================================================================
preview_changes() {
    parse_build_config "$CONFIG_FILE"

    show_header
    print_config_summary
    echo ""
    echo "Press Enter to continue."
    read -r
}

#===============================================================================
# save_and_exit - Save configuration and exit
#===============================================================================
save_and_exit() {
    echo ""
    echo "${GREEN}Configuration saved to: $CONFIG_FILE${NC}"
    echo ""
    echo "Build your image with:"
    echo "  ${CYAN}./scripts/build-image.sh --build-config $CONFIG_FILE${NC}"
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    parse_args "$@"

    # Check if yq is available
    check_yq || exit 1

    # Ensure config file exists (copy default if not)
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ -f "$DEFAULT_CONFIG" ]]; then
            cp "$DEFAULT_CONFIG" "$CONFIG_FILE"
        else
            log_error "Config file not found: $CONFIG_FILE"
            exit 2
        fi
    fi

    # Set output file if not specified
    [[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="$CONFIG_FILE"

    # Handle non-interactive operations
    local has_operations=false

    # Apply profile if specified
    if [[ -n "$PROFILE" ]]; then
        apply_profile "$PROFILE"
        has_operations=true
    fi

    # Apply JSON input if specified
    if [[ -n "$JSON_INPUT_FILE" ]]; then
        apply_json_input "$JSON_INPUT_FILE"
        has_operations=true
    fi

    # Enable dependencies
    for dep in "${ENABLE_DEPS[@]}"; do
        set_dependency "$dep" "true"
        has_operations=true
    done

    # Disable dependencies
    for dep in "${DISABLE_DEPS[@]}"; do
        set_dependency "$dep" "false"
        has_operations=true
    done

    # Set values
    for keyval in "${SET_VALUES[@]}"; do
        set_value "$keyval"
        has_operations=true
    done

    # Add Java versions
    for version in "${ADD_JAVA_VERSIONS[@]}"; do
        add_java_version "$version"
        has_operations=true
    done

    # Output result if we had operations
    if [[ "$has_operations" == "true" ]]; then
        output_result "true"
        exit 0
    fi

    # If no operations and JSON output requested, just export
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        export_config
        exit 0
    fi

    # Otherwise, run interactive mode
    interactive_mode
}

main "$@"
