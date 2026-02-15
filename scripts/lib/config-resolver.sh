#!/usr/bin/env bash
#===============================================================================
# Kapsis - Configuration Resolver
#
# Provides unified configuration resolution logic used by multiple scripts:
#   - launch-agent.sh (agent config resolution)
#   - build-image.sh (build config resolution)
#   - build-agent-image.sh (build config resolution)
#
# Eliminates duplicated resolution logic across these scripts.
#
# Dependencies (must be sourced before this file):
#   - scripts/lib/logging.sh (log_debug, log_info, log_warn, log_error)
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_CONFIG_RESOLVER_LOADED:-}" ]] && return 0
readonly _KAPSIS_CONFIG_RESOLVER_LOADED=1

#===============================================================================
# AGENT CONFIG RESOLUTION
#
# Resolves agent configuration file using priority order:
#   1. Explicit --config path
#   2. --agent shortcut (configs/<agent>.yaml)
#   3. ./agent-sandbox.yaml
#   4. ./.kapsis/config.yaml
#   5. <project>/.kapsis/config.yaml
#   6. ~/.config/kapsis/default.yaml
#   7. <kapsis_root>/configs/claude.yaml (default agent)
#
# Arguments:
#   $1 - config_file (explicit --config value, may be empty)
#   $2 - agent_name (explicit --agent value, may be empty)
#   $3 - project_path
#   $4 - kapsis_root
#   $5 - output variable name for resolved config file (nameref)
#   $6 - output variable name for resolved agent name (nameref)
#===============================================================================
resolve_agent_config() {
    local config_file="$1"
    local agent_name="$2"
    local project_path="$3"
    local kapsis_root="$4"
    local -n _resolved_config=$5
    local -n _resolved_agent=$6

    # --config takes precedence
    if [[ -n "$config_file" ]]; then
        log_debug "Using explicit config file: $config_file"
        if [[ ! -f "$config_file" ]]; then
            log_error "Config file not found: $config_file"
            exit 1
        fi
        _resolved_config="$config_file"
        if [[ -z "$agent_name" ]]; then
            _resolved_agent=$(basename "$config_file" .yaml)
            log_debug "Extracted agent name from config: $_resolved_agent"
        else
            _resolved_agent="$agent_name"
        fi
        return
    fi

    # --agent shortcut: look for configs/<agent>.yaml
    if [[ -n "$agent_name" ]]; then
        local agent_config="$kapsis_root/configs/${agent_name}.yaml"
        if [[ -f "$agent_config" ]]; then
            _resolved_config="$agent_config"
            _resolved_agent="$agent_name"
            log_info "Using agent: ${agent_name}"
            return
        else
            log_error "Unknown agent: $agent_name"
            log_error "Available agents: claude, codex, aider, interactive"
            log_error "Or use --config for custom config file"
            exit 1
        fi
    fi

    # Resolution order (when no --agent or --config specified)
    local config_locations=(
        "./agent-sandbox.yaml"
        "./.kapsis/config.yaml"
        "$project_path/agent-sandbox.yaml"
        "$project_path/.kapsis/config.yaml"
        "$HOME/.config/kapsis/default.yaml"
        "$kapsis_root/configs/claude.yaml"
    )

    for loc in "${config_locations[@]}"; do
        if [[ -f "$loc" ]]; then
            _resolved_config="$loc"
            if [[ -z "$agent_name" ]]; then
                _resolved_agent=$(basename "$loc" .yaml)
            else
                _resolved_agent="$agent_name"
            fi
            log_info "Using agent: ${_resolved_agent} (${loc})"
            return
        fi
    done

    log_error "No config file found."
    log_error "Use --agent <name> or --config <file>"
    log_error "Available agents: claude, codex, aider, interactive"
    exit 1
}

#===============================================================================
# BUILD CONFIG RESOLUTION
#
# Resolves build configuration file for container image builds.
# Used by both build-image.sh and build-agent-image.sh.
#
# Priority order:
#   1. Explicit --build-config path
#   2. --profile shortcut (configs/build-profiles/<profile>.yaml)
#   3. Default config (configs/build-config.yaml)
#
# Arguments:
#   $1 - build_config (explicit --build-config value, may be empty)
#   $2 - profile (--profile value, may be empty)
#   $3 - kapsis_root
#   $4 - output variable name for resolved config file (nameref)
#
# Returns: 0 on success, exits on critical error
#===============================================================================
resolve_build_config_file() {
    local build_config="$1"
    local profile="$2"
    local kapsis_root="$3"
    local -n _resolved_build_config=$4

    if [[ -n "$build_config" ]]; then
        _resolved_build_config="$build_config"
    elif [[ -n "$profile" ]]; then
        _resolved_build_config="$kapsis_root/configs/build-profiles/${profile}.yaml"
    elif [[ -f "$kapsis_root/configs/build-config.yaml" ]]; then
        _resolved_build_config="$kapsis_root/configs/build-config.yaml"
    else
        _resolved_build_config=""
        return 0
    fi

    # Validate file exists if we resolved one
    if [[ -n "$_resolved_build_config" ]] && [[ ! -f "$_resolved_build_config" ]]; then
        if [[ -n "$build_config" ]]; then
            log_error "Build config file not found: $build_config"
            exit 2
        elif [[ -n "$profile" ]]; then
            log_error "Unknown profile: $profile"
            log_error "Available profiles: minimal, java-dev, java8-legacy, full-stack, backend-go, backend-rust, ml-python, frontend"
            exit 2
        fi
        log_warn "Default config not found, using built-in defaults"
        _resolved_build_config=""
    fi
}
