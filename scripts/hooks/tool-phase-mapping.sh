#!/usr/bin/env bash
#===============================================================================
# Tool-to-Phase Mapping for Kapsis Status Hooks
#
# Maps AI agent tool calls to semantic phases for progress tracking.
# This module is sourced by kapsis-status-hook.sh.
#
# Configuration:
#   Loads from configs/tool-phase-mapping.yaml (requires yq)
#   Pattern format matches Claude Code settings.json style: "Tool(pattern)"
#
# Categories:
#   exploring    - Reading files, searching, understanding codebase
#   implementing - Writing code, editing files
#   building     - Compilation, builds, dependency installation
#   testing      - Running tests, test commands
#   committing   - Git commit operations
#   other        - Miscellaneous operations
#===============================================================================

# Config file location - check multiple paths
_find_config_file() {
    local config_paths=(
        "${TOOL_MAPPING_CONFIG:-}"
        "${KAPSIS_HOME:-/opt/kapsis}/configs/tool-phase-mapping.yaml"
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../configs/tool-phase-mapping.yaml"
    )

    for path in "${config_paths[@]}"; do
        if [[ -n "$path" && -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Cache for config-based lookups
declare -A _TOOL_PATTERNS 2>/dev/null || true      # pattern -> category
declare -A _PHASE_RANGES 2>/dev/null || true       # phase -> "[min,max]"
declare -a _PATTERN_ORDER 2>/dev/null || true       # ordered list of patterns
_CONFIG_LOADED=false
_DEFAULT_CATEGORY="other"

#===============================================================================
# Config Loading
#===============================================================================

# Load tool mappings from config file into cache
# Only called once, results are cached
_load_config() {
    [[ "$_CONFIG_LOADED" == "true" ]] && return 0

    local config_file
    if ! config_file=$(_find_config_file); then
        echo "ERROR: Config file not found" >&2
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required for config loading" >&2
        return 1
    fi

    # Load patterns by category (testing first for proper precedence)
    local categories=("testing" "committing" "exploring" "implementing" "building" "other")

    for category in "${categories[@]}"; do
        # shellcheck disable=SC1087 # Not a bash array, yq syntax for array access
        while IFS= read -r pattern; do
            if [[ -n "$pattern" && "$pattern" != "null" ]]; then
                _TOOL_PATTERNS["$pattern"]="$category"
                _PATTERN_ORDER+=("$pattern")
            fi
        done < <(yq -r ".patterns.${category}[]" "$config_file" 2>/dev/null || true)
    done

    # Load phase ranges
    while IFS='=' read -r phase range; do
        [[ -n "$phase" && -n "$range" ]] && _PHASE_RANGES["$phase"]="$range"
    done < <(yq '.phase_ranges | to_entries | .[] | .key + "=" + (.value | @json)' "$config_file" 2>/dev/null || true)

    # Load default category
    local default
    default=$(yq -r '.default_category // "other"' "$config_file" 2>/dev/null)
    [[ -n "$default" && "$default" != "null" ]] && _DEFAULT_CATEGORY="$default"

    _CONFIG_LOADED=true
    return 0
}

#===============================================================================
# Pattern Matching
#===============================================================================

# Convert glob pattern to regex
# Bash(*) -> matches "Bash" tool with any command containing pattern
_glob_to_regex() {
    local pattern="$1"
    local regex

    # Escape regex special chars except *
    # Note: Use [.] instead of \. for better bash compatibility
    regex="$pattern"
    regex="${regex//./\\.}"
    regex="${regex//[/\\[}"
    regex="${regex//]/\\]}"
    regex="${regex//+/\\+}"
    regex="${regex//\?/\\?}"
    regex="${regex//\{/\\{}"
    regex="${regex//\}/\\}}"
    regex="${regex//|/\\|}"
    regex="${regex//\$/\\$}"
    # Convert * to .* for glob matching
    regex="${regex//\*/.*}"

    echo "$regex"
}

# Check if tool+command matches a pattern
# Pattern format: "Tool" or "Tool(command pattern)"
_matches_pattern() {
    local tool_name="$1"
    local command="$2"
    local pattern="$3"

    # Check if pattern has command part: Tool(command)
    # Use case pattern matching instead of regex with ^$
    case "$pattern" in
        *"("*")"*)
            # Extract tool name and command pattern
            local pattern_tool="${pattern%%(*}"
            local pattern_cmd="${pattern#*(}"
            pattern_cmd="${pattern_cmd%)}"

            # Tool name must match
            if [[ "$tool_name" != "$pattern_tool" ]]; then
                return 1
            fi

            # Use case statement for glob matching (lowercase command)
            local cmd_lower="${command,,}"
            # shellcheck disable=SC2254 # Intentional glob matching
            case "$cmd_lower" in
                $pattern_cmd)
                    return 0
                    ;;
            esac
            return 1
            ;;
        *"*"*)
            # Pattern has glob in tool name - use case for matching
            # shellcheck disable=SC2254 # Intentional glob matching
            case "$tool_name" in
                $pattern)
                    return 0
                    ;;
            esac
            return 1
            ;;
        *)
            # Exact tool name match
            [[ "$tool_name" == "$pattern" ]]
            ;;
    esac
}

#===============================================================================
# Tool Name to Category Mapping
#===============================================================================

# Map tool name and optional command to a category
# Arguments:
#   $1 - tool_name (e.g., "Bash", "Read", "Edit", "Write")
#   $2 - command (for Bash tool, the actual command being run)
# Returns:
#   Category name via stdout
map_tool_to_category() {
    local tool_name="$1"
    local command="${2:-}"

    _load_config || {
        echo "$_DEFAULT_CATEGORY"
        return
    }

    # Try patterns in order (first match wins)
    for pattern in "${_PATTERN_ORDER[@]}"; do
        if _matches_pattern "$tool_name" "$command" "$pattern"; then
            echo "${_TOOL_PATTERNS[$pattern]}"
            return
        fi
    done

    # No pattern matched
    echo "$_DEFAULT_CATEGORY"
}

# Convenience function for bash command mapping
map_bash_command_to_category() {
    local command="$1"
    map_tool_to_category "Bash" "$command"
}

#===============================================================================
# Phase to Progress Range Mapping
#===============================================================================

# Get the progress range for a phase
# Arguments:
#   $1 - phase name
# Returns:
#   min,max progress values
get_phase_progress_range() {
    local phase="$1"

    _load_config || {
        echo "25,50"
        return
    }

    local range="${_PHASE_RANGES[$phase]:-}"
    if [[ -n "$range" ]]; then
        # Parse JSON array [min, max] -> "min,max"
        local min max
        min=$(echo "$range" | sed 's/\[//;s/\].*//' | cut -d',' -f1)
        max=$(echo "$range" | sed 's/.*,//;s/\]//')
        echo "$min,$max"
    else
        echo "25,50"
    fi
}

#===============================================================================
# Phase Display Names
#===============================================================================

# Get human-readable phase name
get_phase_display_name() {
    local phase="$1"

    case "$phase" in
        exploring)
            echo "Exploring"
            ;;
        implementing)
            echo "Implementing"
            ;;
        building)
            echo "Building"
            ;;
        testing)
            echo "Testing"
            ;;
        committing)
            echo "Committing"
            ;;
        *)
            echo "Working"
            ;;
    esac
}
