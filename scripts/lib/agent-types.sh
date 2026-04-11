#!/usr/bin/env bash
#===============================================================================
# Kapsis Agent Type Definitions and Parser
#
# Provides centralized agent type normalization and capability detection.
# Import this library in any script that needs to work with agent types.
#
# Usage:
#   source /opt/kapsis/lib/agent-types.sh
#   agent_type=$(normalize_agent_type "claude")
#   if agent_supports_hooks "$agent_type"; then
#       setup_hooks
#   fi
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_AGENT_TYPES_LOADED:-}" ]] && return 0
_KAPSIS_AGENT_TYPES_LOADED=1

#===============================================================================
# Agent Type Constants (Enum-like)
#===============================================================================
# Canonical agent type identifiers
readonly AGENT_TYPE_CLAUDE_CLI="claude-cli"
readonly AGENT_TYPE_CODEX_CLI="codex-cli"
readonly AGENT_TYPE_GEMINI_CLI="gemini-cli"
readonly AGENT_TYPE_AIDER="aider"
readonly AGENT_TYPE_PYTHON="python"
readonly AGENT_TYPE_INTERACTIVE="interactive"
readonly AGENT_TYPE_UNKNOWN="unknown"

# Array of all known agent types
KNOWN_AGENT_TYPES=(
    "$AGENT_TYPE_CLAUDE_CLI"
    "$AGENT_TYPE_CODEX_CLI"
    "$AGENT_TYPE_GEMINI_CLI"
    "$AGENT_TYPE_AIDER"
    "$AGENT_TYPE_PYTHON"
    "$AGENT_TYPE_INTERACTIVE"
)

# Agents that support native hooks for status tracking
HOOK_SUPPORTED_AGENTS=(
    "$AGENT_TYPE_CLAUDE_CLI"
    "$AGENT_TYPE_CODEX_CLI"
    "$AGENT_TYPE_GEMINI_CLI"
)

# Agents that can use Python status library directly
PYTHON_STATUS_AGENTS=(
    "$AGENT_TYPE_PYTHON"
)

#===============================================================================
# Agent Type Normalization
#===============================================================================

# Normalize agent type string to canonical form
# Arguments:
#   $1 - Raw agent type string (e.g., "claude", "claude-cli", "Claude Code")
# Returns:
#   Canonical agent type constant
normalize_agent_type() {
    local raw_type="$1"
    local normalized

    # Convert to lowercase and remove extra whitespace
    normalized=$(echo "$raw_type" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Map various aliases to canonical types
    case "$normalized" in
        # Claude Code variants
        claude|claude-cli|"claude code"|claudecode|"claude-code")
            echo "$AGENT_TYPE_CLAUDE_CLI"
            ;;

        # Codex CLI variants
        codex|codex-cli|"codex cli"|"openai codex"|"openai-codex")
            echo "$AGENT_TYPE_CODEX_CLI"
            ;;

        # Gemini CLI variants
        gemini|gemini-cli|"gemini cli"|"google gemini"|"google-gemini")
            echo "$AGENT_TYPE_GEMINI_CLI"
            ;;

        # Aider variants
        aider|"aider chat"|aider-chat)
            echo "$AGENT_TYPE_AIDER"
            ;;

        # Python/API variants
        python|claude-api|"claude api"|anthropic|"anthropic sdk")
            echo "$AGENT_TYPE_PYTHON"
            ;;

        # Interactive/bash variants
        interactive|bash|shell|manual)
            echo "$AGENT_TYPE_INTERACTIVE"
            ;;

        # Unknown
        *)
            echo "$AGENT_TYPE_UNKNOWN"
            ;;
    esac
}

# Check if an agent type is known/valid
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   0 if known, 1 if unknown
is_known_agent_type() {
    local agent_type="$1"

    for known in "${KNOWN_AGENT_TYPES[@]}"; do
        if [[ "$agent_type" == "$known" ]]; then
            return 0
        fi
    done

    return 1
}

#===============================================================================
# Capability Detection
#===============================================================================

# Check if agent supports native hooks for status tracking
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   0 if hooks supported, 1 otherwise
agent_supports_hooks() {
    local agent_type="$1"

    for supported in "${HOOK_SUPPORTED_AGENTS[@]}"; do
        if [[ "$agent_type" == "$supported" ]]; then
            return 0
        fi
    done

    return 1
}

# Check if agent requires fallback progress monitor
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   0 if fallback needed, 1 otherwise
agent_needs_fallback() {
    local agent_type="$1"

    # If hooks are supported, no fallback needed
    if agent_supports_hooks "$agent_type"; then
        return 1
    fi

    # If it's a Python agent, it uses its own status library
    for python_agent in "${PYTHON_STATUS_AGENTS[@]}"; do
        if [[ "$agent_type" == "$python_agent" ]]; then
            return 1
        fi
    done

    # All others need fallback
    return 0
}

# Check if agent can use Python status library
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   0 if Python status supported, 1 otherwise
agent_uses_python_status() {
    local agent_type="$1"

    for python_agent in "${PYTHON_STATUS_AGENTS[@]}"; do
        if [[ "$agent_type" == "$python_agent" ]]; then
            return 0
        fi
    done

    return 1
}

#===============================================================================
# Hook Configuration
#===============================================================================

# Get the hook configuration path for an agent type
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   Hook config path or empty string if not applicable
get_agent_hook_config_path() {
    local agent_type="$1"

    case "$agent_type" in
        "$AGENT_TYPE_CLAUDE_CLI")
            echo "${HOME}/.claude/settings.local.json"
            ;;
        "$AGENT_TYPE_CODEX_CLI")
            echo "${HOME}/.codex/kapsis-hooks.yaml"
            ;;
        "$AGENT_TYPE_GEMINI_CLI")
            echo "${HOME}/.gemini/hooks"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get the hook types supported by an agent
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   Space-separated list of hook types
get_agent_hook_types() {
    local agent_type="$1"

    case "$agent_type" in
        "$AGENT_TYPE_CLAUDE_CLI")
            echo "PreToolUse PostToolUse Stop"
            ;;
        "$AGENT_TYPE_CODEX_CLI")
            echo "exec.pre exec.post item.create item.update item.delete completion"
            ;;
        "$AGENT_TYPE_GEMINI_CLI")
            echo "tool_call completion error"
            ;;
        *)
            echo ""
            ;;
    esac
}

#===============================================================================
# Display Helpers
#===============================================================================

# Get human-readable agent name
# Arguments:
#   $1 - Agent type (should be normalized)
# Returns:
#   Human-readable name
get_agent_display_name() {
    local agent_type="$1"

    case "$agent_type" in
        "$AGENT_TYPE_CLAUDE_CLI")
            echo "Claude Code CLI"
            ;;
        "$AGENT_TYPE_CODEX_CLI")
            echo "OpenAI Codex CLI"
            ;;
        "$AGENT_TYPE_GEMINI_CLI")
            echo "Google Gemini CLI"
            ;;
        "$AGENT_TYPE_AIDER")
            echo "Aider"
            ;;
        "$AGENT_TYPE_PYTHON")
            echo "Python Agent"
            ;;
        "$AGENT_TYPE_INTERACTIVE")
            echo "Interactive Shell"
            ;;
        *)
            echo "Unknown Agent"
            ;;
    esac
}

# List all known agent types
# Returns:
#   Newline-separated list of agent types
list_agent_types() {
    for agent in "${KNOWN_AGENT_TYPES[@]}"; do
        echo "$agent"
    done
}

# List all hook-supporting agents
# Returns:
#   Newline-separated list of agent types
list_hook_agents() {
    for agent in "${HOOK_SUPPORTED_AGENTS[@]}"; do
        echo "$agent"
    done
}

#===============================================================================
# Self-test (when run directly)
#===============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Agent Types Library Test ==="
    echo ""

    echo "Testing normalization:"
    for test_input in "claude" "Claude Code" "codex-cli" "GEMINI" "aider" "unknown-agent"; do
        result=$(normalize_agent_type "$test_input")
        echo "  '$test_input' -> '$result'"
    done
    echo ""

    echo "Hook support:"
    for agent in "${KNOWN_AGENT_TYPES[@]}"; do
        if agent_supports_hooks "$agent"; then
            echo "  $agent: hooks supported"
        else
            echo "  $agent: no hooks"
        fi
    done
    echo ""

    echo "All known agent types:"
    list_agent_types | while read -r agent; do
        echo "  - $agent ($(get_agent_display_name "$agent"))"
    done
fi
