#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables used by sourcing scripts
#===============================================================================
# Kapsis - Version Management Library
#
# Provides version detection, comparison, and upgrade/downgrade capabilities.
#
# Functions:
#   detect_install_method   - Returns: homebrew|apt|rpm|script|git|unknown
#   get_current_version     - Returns current installed version
#   get_latest_version      - Queries GitHub API for latest release
#   list_available_versions - Lists N recent releases
#   compare_versions        - Compares two semver strings
#   get_upgrade_command     - Returns upgrade command for install method
#   perform_upgrade         - Executes upgrade
#   perform_downgrade       - Validates and executes downgrade
#   print_version           - Displays version info
#   check_upgrade_available - Checks if upgrade is available
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_VERSION_LOADED:-}" ]] && return 0
readonly _KAPSIS_VERSION_LOADED=1

# Source logging if available
_VERSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_VERSION_LIB_DIR/logging.sh" ]] && source "$_VERSION_LIB_DIR/logging.sh"

# Constants
readonly KAPSIS_GITHUB_REPO="aviadshiber/kapsis"
readonly KAPSIS_RELEASES_API="https://api.github.com/repos/$KAPSIS_GITHUB_REPO/releases"
readonly KAPSIS_INSTALL_SCRIPT="https://raw.githubusercontent.com/$KAPSIS_GITHUB_REPO/main/scripts/install.sh"

# Installation method identifiers
readonly INSTALL_HOMEBREW="homebrew"
readonly INSTALL_APT="apt"
readonly INSTALL_RPM="rpm"
readonly INSTALL_SCRIPT="script"
readonly INSTALL_GIT="git"
readonly INSTALL_UNKNOWN="unknown"

#===============================================================================
# INSTALLATION DETECTION
#===============================================================================

# Detect installation method
# Returns: homebrew, apt, rpm, script, git, or unknown
detect_install_method() {
    local kapsis_root="${KAPSIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # Check Homebrew (macOS and Linux)
    if command -v brew &>/dev/null && brew list kapsis &>/dev/null 2>&1; then
        echo "$INSTALL_HOMEBREW"
        return 0
    fi

    # Check Debian/APT
    if command -v dpkg &>/dev/null && dpkg -l kapsis 2>/dev/null | grep -q "^ii"; then
        echo "$INSTALL_APT"
        return 0
    fi

    # Check RPM/DNF
    if command -v rpm &>/dev/null && rpm -q kapsis &>/dev/null 2>&1; then
        echo "$INSTALL_RPM"
        return 0
    fi

    # Check universal script install
    if [[ -n "${KAPSIS_PREFIX:-}" ]] || [[ -d "$HOME/.local/lib/kapsis" ]]; then
        echo "$INSTALL_SCRIPT"
        return 0
    fi

    # Check git clone
    if [[ -d "$kapsis_root/.git" ]]; then
        echo "$INSTALL_GIT"
        return 0
    fi

    echo "$INSTALL_UNKNOWN"
}

#===============================================================================
# VERSION QUERIES
#===============================================================================

# Get current installed version
# Returns: version string (e.g., "0.16.0") or "unknown"
get_current_version() {
    local install_method
    install_method=$(detect_install_method)
    local kapsis_root="${KAPSIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    case "$install_method" in
        "$INSTALL_HOMEBREW")
            brew info kapsis 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
            ;;
        "$INSTALL_APT")
            dpkg -l kapsis 2>/dev/null | grep "^ii" | awk '{print $3}' | sed 's/-[0-9]*$//'
            ;;
        "$INSTALL_RPM")
            rpm -q kapsis --queryformat '%{VERSION}' 2>/dev/null
            ;;
        "$INSTALL_SCRIPT"|"$INSTALL_GIT")
            local version=""
            if [[ -d "$kapsis_root/.git" ]]; then
                # Try git describe first
                version=$(git -C "$kapsis_root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

                # If empty (shallow clone or no tags), try fetching tags
                if [[ -z "$version" ]]; then
                    git -C "$kapsis_root" fetch --tags --depth=1 2>/dev/null || true
                    version=$(git -C "$kapsis_root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
                fi
            fi

            # Fallback to VERSION file
            if [[ -z "$version" ]] && [[ -f "$kapsis_root/VERSION" ]]; then
                version=$(cat "$kapsis_root/VERSION")
            fi

            # Fallback to parsing CHANGELOG.md for latest version
            if [[ -z "$version" ]] && [[ -f "$kapsis_root/CHANGELOG.md" ]]; then
                version=$(grep -oE '## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$kapsis_root/CHANGELOG.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
            fi

            echo "${version:-unknown}"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Get latest release version from GitHub
# Returns: version string (e.g., "0.17.0") or empty on error
get_latest_version() {
    local response
    local timeout=10

    if command -v curl &>/dev/null; then
        response=$(curl -fsSL --connect-timeout "$timeout" "$KAPSIS_RELEASES_API/latest" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        response=$(wget -qO- --timeout="$timeout" "$KAPSIS_RELEASES_API/latest" 2>/dev/null)
    else
        echo "error: neither curl nor wget available" >&2
        return 1
    fi

    if [[ -z "$response" ]]; then
        echo "error: could not fetch latest version" >&2
        return 1
    fi

    # Parse tag_name from JSON
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.tag_name // empty' | sed 's/^v//'
    else
        # Fallback: grep/sed parsing
        echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            head -1 | sed 's/.*"v\?\([^"]*\)".*/\1/'
    fi
}

# List available versions from GitHub
# Arguments: $1 - max versions to list (default 10)
# Returns: newline-separated list of versions
list_available_versions() {
    local max="${1:-10}"
    local response
    local timeout=10

    if command -v curl &>/dev/null; then
        response=$(curl -fsSL --connect-timeout "$timeout" "$KAPSIS_RELEASES_API?per_page=$max" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        response=$(wget -qO- --timeout="$timeout" "$KAPSIS_RELEASES_API?per_page=$max" 2>/dev/null)
    else
        echo "error: neither curl nor wget available" >&2
        return 1
    fi

    if [[ -z "$response" ]]; then
        echo "error: could not fetch versions" >&2
        return 1
    fi

    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.[].tag_name // empty' | sed 's/^v//'
    else
        echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"v\?\([^"]*\)".*/\1/'
    fi
}

# Validate version string is safe semver format
# Arguments: $1 - version string
# Returns: 0 if valid, 1 if invalid
# Security: Prevents command injection by ensuring version is strictly numeric with dots
validate_version_format() {
    local version="$1"

    # Remove 'v' prefix if present
    version="${version#v}"

    # Must match strict semver pattern: MAJOR.MINOR.PATCH (all numeric)
    # This prevents command injection via $(cmd), `cmd`, ;cmd, etc.
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid version format '$version'" >&2
        echo "Version must be in format: X.Y.Z (e.g., 1.2.3 or v1.2.3)" >&2
        return 1
    fi
    return 0
}

# Compare two semantic versions
# Arguments: $1 - version1, $2 - version2
# Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    # Remove 'v' prefix if present
    v1="${v1#v}"
    v2="${v2#v}"

    if [[ "$v1" == "$v2" ]]; then
        echo 0
        return
    fi

    # Parse major.minor.patch
    local v1_major v1_minor v1_patch
    local v2_major v2_minor v2_patch

    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"

    # Default to 0 if empty
    v1_major="${v1_major:-0}"
    v1_minor="${v1_minor:-0}"
    v1_patch="${v1_patch:-0}"
    v2_major="${v2_major:-0}"
    v2_minor="${v2_minor:-0}"
    v2_patch="${v2_patch:-0}"

    # Compare major
    if (( v1_major < v2_major )); then
        echo -1
        return
    elif (( v1_major > v2_major )); then
        echo 1
        return
    fi

    # Compare minor
    if (( v1_minor < v2_minor )); then
        echo -1
        return
    elif (( v1_minor > v2_minor )); then
        echo 1
        return
    fi

    # Compare patch
    if (( v1_patch < v2_patch )); then
        echo -1
        return
    elif (( v1_patch > v2_patch )); then
        echo 1
        return
    fi

    echo 0
}

#===============================================================================
# UPGRADE/DOWNGRADE COMMANDS
#===============================================================================

# Generate upgrade command for the detected install method
# Arguments: $1 - target version (optional, defaults to latest)
# Returns: command string to execute
get_upgrade_command() {
    local target_version="${1:-}"
    local install_method
    install_method=$(detect_install_method)
    local kapsis_root="${KAPSIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # Security: Validate version format if specified (defense-in-depth)
    if [[ -n "$target_version" ]]; then
        if ! validate_version_format "$target_version"; then
            echo "echo 'Error: Invalid version format'"
            return 1
        fi
    fi

    case "$install_method" in
        "$INSTALL_HOMEBREW")
            if [[ -n "$target_version" ]]; then
                # Homebrew doesn't easily support specific versions
                cat <<EOF
# Homebrew doesn't support easy version pinning
# For specific version, reinstall from GitHub release:
brew uninstall kapsis
KAPSIS_VERSION=$target_version curl -fsSL $KAPSIS_INSTALL_SCRIPT | bash
EOF
            else
                echo "brew update && brew upgrade kapsis"
            fi
            ;;
        "$INSTALL_APT")
            if [[ -n "$target_version" ]]; then
                echo "sudo apt-get update && sudo apt-get install -y kapsis=$target_version"
            else
                echo "sudo apt-get update && sudo apt-get upgrade -y kapsis"
            fi
            ;;
        "$INSTALL_RPM")
            if [[ -n "$target_version" ]]; then
                echo "sudo dnf makecache && sudo dnf install -y kapsis-$target_version"
            else
                echo "sudo dnf makecache && sudo dnf upgrade -y kapsis"
            fi
            ;;
        "$INSTALL_SCRIPT")
            if [[ -n "$target_version" ]]; then
                echo "KAPSIS_VERSION=$target_version curl -fsSL $KAPSIS_INSTALL_SCRIPT | bash"
            else
                echo "curl -fsSL $KAPSIS_INSTALL_SCRIPT | bash"
            fi
            ;;
        "$INSTALL_GIT")
            if [[ -n "$target_version" ]]; then
                echo "cd $kapsis_root && git fetch --tags && git checkout v$target_version && ./scripts/build-image.sh"
            else
                echo "cd $kapsis_root && git pull origin main && ./scripts/build-image.sh"
            fi
            ;;
        *)
            cat <<EOF
# Unknown installation method. Manual upgrade required.
# Download from: https://github.com/$KAPSIS_GITHUB_REPO/releases
EOF
            ;;
    esac
}

# Check if upgrade is available
# Returns: 0 if upgrade available, 1 otherwise
# Outputs: current and latest versions
check_upgrade_available() {
    local current
    local latest

    current=$(get_current_version)
    latest=$(get_latest_version)

    if [[ -z "$latest" || "$latest" == error* ]]; then
        echo "Could not fetch latest version from GitHub" >&2
        echo "Check your network connection or try again later." >&2
        return 1
    fi

    echo "Current version: $current"
    echo "Latest version:  $latest"

    local cmp
    cmp=$(compare_versions "$current" "$latest")

    if [[ "$cmp" == "-1" ]]; then
        echo ""
        echo "Upgrade available! Run: kapsis --upgrade"
        return 0
    else
        echo ""
        echo "You are on the latest version."
        return 1
    fi
}

# Perform upgrade
# Arguments: $1 - target version (optional), $2 - dry_run flag (true/false)
perform_upgrade() {
    local target_version="${1:-}"
    local dry_run="${2:-false}"
    local install_method
    local upgrade_to_latest=false

    install_method=$(detect_install_method)

    # Get latest if no target specified
    if [[ -z "$target_version" ]]; then
        echo "Fetching latest version..."
        target_version=$(get_latest_version)
        if [[ -z "$target_version" || "$target_version" == error* ]]; then
            echo "Error: Could not fetch latest version from GitHub" >&2
            return 1
        fi
        upgrade_to_latest=true
    fi

    # Remove 'v' prefix if present
    target_version="${target_version#v}"

    # Security: Validate version format to prevent command injection
    if ! validate_version_format "$target_version"; then
        return 1
    fi

    local current
    current=$(get_current_version)

    echo "Installation method: $install_method"
    echo "Current version:     $current"
    echo "Target version:      $target_version"
    echo ""

    # Check if already on target version
    local cmp
    cmp=$(compare_versions "$current" "$target_version")
    if [[ "$cmp" == "0" ]]; then
        echo "Already on version $target_version"
        return 0
    fi

    # When upgrading to latest, use simple upgrade command (no version arg)
    # When upgrading to specific version, pass the version
    local cmd
    if [[ "$upgrade_to_latest" == "true" ]]; then
        cmd=$(get_upgrade_command)
    else
        cmd=$(get_upgrade_command "$target_version")
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY-RUN] Would execute:"
        echo ""
        echo "$cmd"
        return 0
    fi

    # Check if sudo is required
    local needs_sudo=false
    case "$install_method" in
        "$INSTALL_APT"|"$INSTALL_RPM")
            needs_sudo=true
            ;;
    esac

    if [[ "$needs_sudo" == "true" ]] && [[ "$(id -u)" -ne 0 ]]; then
        echo "This upgrade requires elevated privileges."
        echo ""
        echo "Command to execute:"
        echo "  $cmd"
        echo ""
        read -p "Execute now? [y/N]: " -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Upgrade cancelled. Run the command manually when ready."
            return 1
        fi
    fi

    echo "Executing upgrade..."
    echo ""
    eval "$cmd"
}

# Get the previous version (one version older than current)
# Returns: previous version string or empty if not found
get_previous_version() {
    local current
    current=$(get_current_version)

    if [[ -z "$current" || "$current" == "unknown" ]]; then
        echo "error: could not determine current version" >&2
        return 1
    fi

    # Fetch available versions
    local versions
    versions=$(list_available_versions 20)

    if [[ -z "$versions" ]]; then
        echo "error: could not fetch version list" >&2
        return 1
    fi

    # Find the first version that's older than current
    local version
    while IFS= read -r version; do
        local cmp
        cmp=$(compare_versions "$version" "$current")
        if [[ "$cmp" == "-1" ]]; then
            echo "$version"
            return 0
        fi
    done <<< "$versions"

    echo "error: no older version found" >&2
    return 1
}

# Perform downgrade (validates version is older, then upgrades)
# Arguments: $1 - target version (optional, defaults to previous version), $2 - dry_run flag (true/false)
perform_downgrade() {
    local target_version="${1:-}"
    local dry_run="${2:-false}"

    local current
    current=$(get_current_version)

    # If no version specified, find the previous version
    if [[ -z "$target_version" ]]; then
        echo "No version specified, finding previous version..."
        target_version=$(get_previous_version)
        if [[ -z "$target_version" || "$target_version" == error* ]]; then
            echo "Error: Could not find a previous version to downgrade to" >&2
            echo "" >&2
            echo "Available versions:" >&2
            list_available_versions 5 | sed 's/^/  /' >&2
            return 1
        fi
        echo "Found previous version: $target_version"
        echo ""
    fi

    # Remove 'v' prefix if present
    target_version="${target_version#v}"

    # Security: Validate version format to prevent command injection
    if ! validate_version_format "$target_version"; then
        return 1
    fi

    # Validate target is actually older
    local cmp
    cmp=$(compare_versions "$target_version" "$current")

    if [[ "$cmp" == "0" ]]; then
        echo "Error: Target version $target_version is the same as current version" >&2
        return 1
    fi

    if [[ "$cmp" == "1" ]]; then
        echo "Error: Target version $target_version is newer than current version $current" >&2
        echo "Use --upgrade to install a newer version" >&2
        return 1
    fi

    echo "Downgrade: $current -> $target_version"
    echo ""

    # Downgrade uses the same mechanism as upgrade
    perform_upgrade "$target_version" "$dry_run"
}

#===============================================================================
# VERSION DISPLAY
#===============================================================================

# Print version information
print_version() {
    local current
    local install_method

    current=$(get_current_version)
    install_method=$(detect_install_method)

    echo "Kapsis $current"
    echo ""
    echo "Installation method: $install_method"

    # Show installation path for git/script installs
    case "$install_method" in
        "$INSTALL_GIT")
            local kapsis_root="${KAPSIS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
            echo "Installation path:   $kapsis_root"
            ;;
        "$INSTALL_SCRIPT")
            local prefix="${KAPSIS_PREFIX:-$HOME/.local}"
            echo "Installation prefix: $prefix"
            ;;
    esac
}
