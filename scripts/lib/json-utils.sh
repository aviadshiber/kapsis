#!/usr/bin/env bash
#===============================================================================
# Kapsis JSON Utilities
#===============================================================================
# Provides minimal JSON parsing utilities without requiring jq.
# These are basic regex-based parsers suitable for simple, flat JSON structures.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/json-utils.sh"
#   value=$(json_get_string "$json" "key_name")
#   number=$(json_get_number "$json" "key_name")
#===============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_JSON_UTILS_LOADED:-}" ]] && return 0
_KAPSIS_JSON_UTILS_LOADED=1

#===============================================================================
# STRING VALUE EXTRACTION
#===============================================================================

# Extract a string value from JSON
# Usage: json_get_string <json> <key>
# Returns: The string value, or empty string if not found/null
json_get_string() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\": *\"[^\"]*\"" 2>/dev/null | \
        sed "s/\"$key\": *\"\([^\"]*\)\"/\1/" | head -1 || true
}

#===============================================================================
# NUMBER VALUE EXTRACTION
#===============================================================================

# Extract a numeric value from JSON (including null)
# Usage: json_get_number <json> <key>
# Returns: The number value, "null", or empty string if not found
json_get_number() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\": *[0-9null-]*" 2>/dev/null | \
        sed "s/\"$key\": *\([0-9null-]*\)/\1/" | head -1 || true
}

#===============================================================================
# BOOLEAN VALUE EXTRACTION
#===============================================================================

# Extract a boolean value from JSON
# Usage: json_get_bool <json> <key>
# Returns: "true", "false", or empty string if not found
json_get_bool() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\": *\(true\|false\)" 2>/dev/null | \
        sed "s/\"$key\": *\(true\|false\)/\1/" | head -1 || true
}

#===============================================================================
# JSON STRING ESCAPING
#===============================================================================

# Escape a string for safe inclusion in JSON
# Usage: escaped=$(json_escape_string "string with \"quotes\"")
json_escape_string() {
    local str="$1"
    # Escape backslashes first, then quotes, then control characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

#===============================================================================
# JSON VALIDATION (basic)
#===============================================================================

# Check if a string looks like valid JSON (basic check)
# Usage: if json_is_valid "$json"; then ...
json_is_valid() {
    local json="$1"
    # Basic checks: starts with { or [, ends with } or ]
    if [[ "$json" =~ ^[[:space:]]*[\{\[] && "$json" =~ [\}\]][[:space:]]*$ ]]; then
        return 0
    fi
    return 1
}
