#!/usr/bin/env bash
#===============================================================================
# Kapsis - Environment Variable Builder
#
# Generates environment variable arrays for container launch.
# Splits variables into two categories:
#   ENV_VARS: non-secret variables (visible in dry-run, use -e flags)
#   SECRET_ENV_VARS: secret variables (written to temp file, use --env-file)
#
# Extracted from launch-agent.sh to comply with single-responsibility
# and 80-line function limits.
#
# Dependencies (must be sourced before this file):
#   - scripts/lib/logging.sh   (log_debug, log_info, log_warn, log_success)
#   - scripts/lib/secret-store.sh (query_secret_store_with_fallbacks)
#   - is_secret_var_name() from logging.sh
#
# Reads globals: ENV_PASSTHROUGH, ENV_KEYCHAIN, AGENT_ID, PROJECT_PATH,
#   SANDBOX_MODE, WORKTREE_PATH, SANDBOX_DIR, BRANCH, REMOTE_BRANCH,
#   BASE_BRANCH, GIT_REMOTE, DO_PUSH, TASK_INLINE, STAGED_CONFIGS,
#   CLAUDE_HOOKS_INCLUDE, CLAUDE_MCP_INCLUDE, INJECT_GIST, ENV_SET,
#   CONFIG_FILE, AGENT_NAME, IMAGE_NAME, KAPSIS_ROOT,
#   GLOBAL_INJECT_TO
#
# Writes globals: ENV_VARS[@], SECRET_ENV_VARS[@]
#===============================================================================

# Guard against multiple sourcing
[[ -n "${_KAPSIS_ENV_BUILDER_LOADED:-}" ]] && return 0
readonly _KAPSIS_ENV_BUILDER_LOADED=1

#===============================================================================
# PASSTHROUGH VARIABLES
# Process environment variables listed in config's environment.passthrough
#===============================================================================
_env_process_passthrough() {
    if [[ -z "${ENV_PASSTHROUGH:-}" ]]; then
        return 0
    fi

    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        if [[ -n "${!var:-}" ]]; then
            if is_secret_var_name "$var"; then
                SECRET_ENV_VARS+=("${var}=${!var}")
            else
                ENV_VARS+=("-e" "${var}=${!var}")
            fi
        fi
    done <<< "$ENV_PASSTHROUGH"
}

#===============================================================================
# KEYCHAIN-BACKED VARIABLES
# Resolve secrets from system keychain (macOS Keychain / Linux secret-tool)
# Returns: CREDENTIAL_FILES and SECRET_STORE_ENTRIES strings
#===============================================================================
_env_process_keychain() {
    local -n _credential_files_ref=$1
    local -n _secret_store_entries_ref=$2

    if [[ -z "${ENV_KEYCHAIN:-}" ]]; then
        return 0
    fi

    log_info "Resolving secrets from system keychain..."
    while IFS='|' read -r var_name service account inject_to_file file_mode inject_to; do
        [[ -z "$var_name" || -z "$service" ]] && continue

        # Expand variables in account (e.g., ${USER})
        # Security: Use parameter expansion instead of eval to prevent injection
        if [[ -n "$account" ]]; then
            account="${account//\$\{USER\}/${USER}}"
            account="${account//\$USER/${USER}}"
            account="${account//\$\{HOME\}/${HOME}}"
            account="${account//\$HOME/${HOME}}"
            account="${account//\$\{LOGNAME\}/${LOGNAME:-$USER}}"
            account="${account//\$LOGNAME/${LOGNAME:-$USER}}"
        fi

        # Skip if already set via passthrough
        if _env_is_already_set "$var_name"; then
            log_debug "Skipping $var_name - already set via passthrough"
            continue
        fi

        # Validate inject_to value before proceeding
        if [[ -n "${inject_to:-}" ]] && [[ "$inject_to" != "secret_store" ]] && [[ "$inject_to" != "env" ]]; then
            log_warn "Unknown inject_to value '$inject_to' for $var_name — defaulting to env"
            inject_to="env"
        fi

        # Query secret store (keychain/secret-tool) with fallback account support
        local value
        if value=$(query_secret_store_with_fallbacks "$service" "$account" "$var_name"); then
            # Keychain values are always secrets
            SECRET_ENV_VARS+=("${var_name}=${value}")
            log_success "Loaded $var_name from secret store (service: $service)"

            # Track secret store injection if requested (default: secret_store)
            if [[ "${inject_to:-secret_store}" == "secret_store" ]]; then
                local ss_entry="${var_name}|${service}|${account:-kapsis}"
                if [[ -n "$_secret_store_entries_ref" ]]; then
                    _secret_store_entries_ref="${_secret_store_entries_ref},${ss_entry}"
                else
                    _secret_store_entries_ref="${ss_entry}"
                fi
                log_debug "Will inject $var_name to container secret store"
            fi

            # Track file injection if specified (orthogonal to inject_to)
            if [[ -n "$inject_to_file" ]]; then
                if [[ -n "$_credential_files_ref" ]]; then
                    _credential_files_ref="${_credential_files_ref},${var_name}|${inject_to_file}|${file_mode:-0600}"
                else
                    _credential_files_ref="${var_name}|${inject_to_file}|${file_mode:-0600}"
                fi
                log_debug "Will inject $var_name to file: $inject_to_file"
            fi
        else
            log_warn "Secret not found: $service (for $var_name)"
        fi
    done <<< "$ENV_KEYCHAIN"
}

# Check if a variable name is already set in ENV_VARS or SECRET_ENV_VARS
_env_is_already_set() {
    local var_name="$1"
    if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
        for existing in "${ENV_VARS[@]}"; do
            if [[ "$existing" == "${var_name}="* ]]; then
                return 0
            fi
        done
    fi
    if [[ ${#SECRET_ENV_VARS[@]} -gt 0 ]]; then
        for existing in "${SECRET_ENV_VARS[@]}"; do
            if [[ "$existing" == "${var_name}="* ]]; then
                return 0
            fi
        done
    fi
    return 1
}

#===============================================================================
# KAPSIS CORE ENVIRONMENT VARIABLES
# These are always set regardless of configuration
#===============================================================================
_env_add_kapsis_core() {
    ENV_VARS+=("-e" "KAPSIS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_SANDBOX_MODE=${SANDBOX_MODE}")

    # Status reporting
    ENV_VARS+=("-e" "KAPSIS_STATUS_PROJECT=$(basename "$PROJECT_PATH")")
    ENV_VARS+=("-e" "KAPSIS_STATUS_AGENT_ID=${AGENT_ID}")
    ENV_VARS+=("-e" "KAPSIS_STATUS_BRANCH=${BRANCH:-}")
    ENV_VARS+=("-e" "KAPSIS_INJECT_GIST=${INJECT_GIST:-false}")
}

#===============================================================================
# AGENT TYPE RESOLUTION
# Resolves and sets agent type for status tracking hooks
#===============================================================================
_env_resolve_agent_type() {
    local agent_type="${AGENT_NAME:-unknown}"
    local agent_types_lib="$KAPSIS_ROOT/scripts/lib/agent-types.sh"
    if [[ -f "$agent_types_lib" ]]; then
        # shellcheck source=agent-types.sh
        source "$agent_types_lib"
        agent_type=$(normalize_agent_type "$agent_type")
    fi

    # Infer from image name if still unknown
    if [[ "$agent_type" == "unknown" && -n "$IMAGE_NAME" ]]; then
        case "$IMAGE_NAME" in
            *claude-cli*)  agent_type="claude-cli" ;;
            *codex-cli*)   agent_type="codex-cli" ;;
            *gemini-cli*)  agent_type="gemini-cli" ;;
            *aider*)       agent_type="aider" ;;
        esac
        log_debug "Inferred agent type from image name: $agent_type"
    fi
    ENV_VARS+=("-e" "KAPSIS_AGENT_TYPE=${agent_type}")
    log_debug "Agent type for status tracking: $agent_type"
}

#===============================================================================
# MODE-SPECIFIC VARIABLES
# Variables that differ based on sandbox mode
#===============================================================================
_env_add_mode_specific() {
    if [[ "$SANDBOX_MODE" == "worktree" ]]; then
        ENV_VARS+=("-e" "KAPSIS_WORKTREE_MODE=true")
    else
        ENV_VARS+=("-e" "KAPSIS_SANDBOX_DIR=${SANDBOX_DIR}")
    fi
}

#===============================================================================
# GIT VARIABLES
# Branch, remote, push settings
#===============================================================================
_env_add_git_vars() {
    if [[ -n "$BRANCH" ]]; then
        ENV_VARS+=("-e" "KAPSIS_BRANCH=${BRANCH}")
        ENV_VARS+=("-e" "KAPSIS_GIT_REMOTE=${GIT_REMOTE}")
        ENV_VARS+=("-e" "KAPSIS_DO_PUSH=${DO_PUSH}")
        if [[ -n "$REMOTE_BRANCH" ]]; then
            ENV_VARS+=("-e" "KAPSIS_REMOTE_BRANCH=${REMOTE_BRANCH}")
        fi
        if [[ -n "$BASE_BRANCH" ]]; then
            ENV_VARS+=("-e" "KAPSIS_BASE_BRANCH=${BASE_BRANCH}")
        fi
    fi
}

#===============================================================================
# TASK, CONFIG, AND WHITELIST VARIABLES
#===============================================================================
_env_add_task_and_config() {
    if [[ -n "$TASK_INLINE" ]]; then
        ENV_VARS+=("-e" "KAPSIS_TASK=${TASK_INLINE}")
    fi

    if [[ -n "$STAGED_CONFIGS" ]]; then
        ENV_VARS+=("-e" "KAPSIS_STAGED_CONFIGS=${STAGED_CONFIGS}")
    fi

    if [[ -n "${CLAUDE_HOOKS_INCLUDE:-}" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CLAUDE_HOOKS_INCLUDE=${CLAUDE_HOOKS_INCLUDE}")
    fi
    if [[ -n "${CLAUDE_MCP_INCLUDE:-}" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CLAUDE_MCP_INCLUDE=${CLAUDE_MCP_INCLUDE}")
    fi
}

#===============================================================================
# EXPLICIT SET VARIABLES
# Process environment.set from config (key=value pairs)
#===============================================================================
_env_process_explicit_set() {
    if [[ -z "$ENV_SET" ]] || [[ "$ENV_SET" == "{}" ]]; then
        return 0
    fi

    log_debug "Processing environment.set variables..."
    local set_vars
    set_vars=$(yq -o=props '.environment.set' "$CONFIG_FILE" 2>/dev/null | grep -v '^#' || echo "")
    if [[ -n "$set_vars" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key value
            key=$(echo "$line" | cut -d'=' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [[ -n "$key" ]]; then
                if is_secret_var_name "$key"; then
                    SECRET_ENV_VARS+=("${key}=${value}")
                else
                    ENV_VARS+=("-e" "${key}=${value}")
                fi
            fi
        done <<< "$set_vars"
    fi
}

#===============================================================================
# MAIN ORCHESTRATOR
# Assembles all environment variables for container launch
# Writes: ENV_VARS[@], SECRET_ENV_VARS[@]
#===============================================================================
generate_env_vars() {
    ENV_VARS=()
    SECRET_ENV_VARS=()

    _env_process_passthrough

    local CREDENTIAL_FILES=""
    local SECRET_STORE_ENTRIES=""
    _env_process_keychain CREDENTIAL_FILES SECRET_STORE_ENTRIES

    # Pass credential file injection metadata
    if [[ -n "$CREDENTIAL_FILES" ]]; then
        ENV_VARS+=("-e" "KAPSIS_CREDENTIAL_FILES=${CREDENTIAL_FILES}")
    fi

    # Pass secret store injection metadata
    if [[ -n "$SECRET_STORE_ENTRIES" ]]; then
        ENV_VARS+=("-e" "KAPSIS_SECRET_STORE_ENTRIES=${SECRET_STORE_ENTRIES}")
    fi

    _env_add_kapsis_core
    _env_resolve_agent_type
    _env_add_mode_specific
    _env_add_git_vars
    _env_add_task_and_config
    _env_process_explicit_set
}
