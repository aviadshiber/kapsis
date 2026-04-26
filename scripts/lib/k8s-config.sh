#!/usr/bin/env bash
#===============================================================================
# Kapsis - K8s Config Translator
#
# Translates launch-agent.sh internal variables into AgentRequest CR YAML.
# This library bridges the shared config layer with the K8s backend.
#
# Functions:
#   translate_memory_to_k8s  - Convert Docker-style memory to K8s format
#   translate_cpus_to_k8s    - Convert CPU count to K8s format
#   generate_env_yaml        - Generate YAML env: block from array
#   generate_agent_request_cr - Generate full AgentRequest CR YAML
#===============================================================================

# Guard against multiple sourcing
if [[ -n "${_KAPSIS_K8S_CONFIG_LOADED:-}" ]]; then
    return 0
fi
readonly _KAPSIS_K8S_CONFIG_LOADED=1

#===============================================================================
# TRANSLATORS
#===============================================================================

# Convert Docker-style memory notation to K8s notation
# Docker: 8g, 512m  ->  K8s: 8Gi, 512Mi
# Already-K8s notation (Gi, Mi) passes through unchanged
translate_memory_to_k8s() {
    local mem="$1"
    if [[ "$mem" =~ ^([0-9]+)[gG]$ ]]; then
        echo "${BASH_REMATCH[1]}Gi"
    elif [[ "$mem" =~ ^([0-9]+)[mM]$ ]]; then
        echo "${BASH_REMATCH[1]}Mi"
    elif [[ "$mem" =~ ^[0-9]+(Gi|Mi|Ki)$ ]]; then
        echo "$mem"
    else
        echo "$mem"
    fi
}

# Convert CPU count to K8s format (passthrough)
translate_cpus_to_k8s() {
    echo "$1"
}

# Escape a string for YAML double-quoted context.
# Handles \, ", newline, tab, and carriage return.
_yaml_escape() {
    local s="$1"
    s="${s//\\/\\\\}"       # \ -> \\  (must be first)
    s="${s//\"/\\\"}"       # " -> \"
    s="${s//$'\n'/\\n}"     # newline -> \n
    s="${s//$'\t'/\\t}"     # tab -> \t
    s="${s//$'\r'/\\r}"     # CR -> \r
    printf '%s\n' "$s"
}

# Generate YAML env: block from a bash array variable name.
# Arguments: $1 = name of the array variable (not the array itself)
# Output: YAML lines for env entries
# Uses nameref (bash 4.3+) — avoids eval and shell-injection risk.
generate_env_yaml() {
    local -n _gen_arr="$1"  # nameref — safe, no eval needed
    local entry name value
    for entry in "${_gen_arr[@]}"; do
        name="${entry%%=*}"
        value="${entry#*=}"
        echo "      - name: \"$(_yaml_escape "$name")\""
        echo "        value: \"$(_yaml_escape "$value")\""
    done
}

#===============================================================================
# CR GENERATOR
#===============================================================================

# Generate a complete AgentRequest CR YAML from launch-agent.sh globals.
# Required globals: AGENT_ID, IMAGE_NAME, AGENT_NAME, RESOURCE_MEMORY,
#   RESOURCE_CPUS, BRANCH, TASK_INLINE, NETWORK_MODE, SECURITY_PROFILE,
#   AGENT_COMMAND (string — agent command from config)
# Optional globals: INLINE_SPEC_FILE, GIT_REMOTE_URL, BASE_BRANCH, DO_PUSH
# Optional: KAPSIS_K8S_GIT_CRED_SECRET (Secret name, defaults to kapsis-git-creds)
# Optional argument: $1 = name of extra env vars array (entries as KEY=VALUE)
generate_agent_request_cr() {
    local extra_env_var_name="${1:-}"
    local k8s_memory k8s_cpu
    k8s_memory=$(translate_memory_to_k8s "${RESOURCE_MEMORY:-8g}")
    k8s_cpu=$(translate_cpus_to_k8s "${RESOURCE_CPUS:-4}")

    # Build command YAML from AGENT_COMMAND string
    local cmd_yaml=""
    if [[ -n "${AGENT_COMMAND:-}" ]]; then
        cmd_yaml="    command:
      - \"bash\"
      - \"-c\"
      - \"$(_yaml_escape "$AGENT_COMMAND")\""
    fi

    cat <<YAML
apiVersion: kapsis.aviadshiber.github.io/v1alpha1
kind: AgentRequest
metadata:
  name: "kapsis-$(_yaml_escape "$AGENT_ID")"
  labels:
    kapsis.aviadshiber.github.io/agent-type: "$(_yaml_escape "${AGENT_CONFIG_TYPE:-${AGENT_NAME}}")"
    kapsis.aviadshiber.github.io/agent-id: "$(_yaml_escape "$AGENT_ID")"
spec:
  agent:
    type: "$(_yaml_escape "${AGENT_CONFIG_TYPE:-${AGENT_NAME}}")"
    image: "$(_yaml_escape "$IMAGE_NAME")"
${cmd_yaml}
    workdir: /workspace
  resources:
    memory: "${k8s_memory}"
    cpu: "${k8s_cpu}"
YAML

    # Workspace / git section (only when a branch is configured)
    if [[ -n "${BRANCH:-}" ]]; then
        local git_cred_secret="${KAPSIS_K8S_GIT_CRED_SECRET:-kapsis-git-creds}"
        cat <<YAML
  workspace:
    git:
      branch: "$(_yaml_escape "$BRANCH")"
      baseBranch: "$(_yaml_escape "${BASE_BRANCH:-main}")"
      push: ${DO_PUSH:-false}
      credentialSecretRef: "$(_yaml_escape "$git_cred_secret")"
YAML
        # Add git URL if available
        if [[ -n "${GIT_REMOTE_URL:-}" ]]; then
            echo "      url: \"$(_yaml_escape "$GIT_REMOTE_URL")\""
        fi
    fi

    # Task section
    if [[ -n "${TASK_INLINE:-}" ]]; then
        cat <<YAML
  task:
    inline: "$(_yaml_escape "$TASK_INLINE")"
YAML
    fi

    # Environment section — user vars first, then Kapsis-controlled vars.
    # Kapsis vars are appended last at the operator level too (security invariant).
    cat <<YAML
  environment:
    vars:
      - name: "KAPSIS_BACKEND"
        value: "k8s"
      - name: "KAPSIS_AGENT_ID"
        value: "$(_yaml_escape "$AGENT_ID")"
      - name: "KAPSIS_AGENT_TYPE"
        value: "$(_yaml_escape "$AGENT_NAME")"
      - name: "KAPSIS_STATUS_PROJECT"
        value: "$(_yaml_escape "${KAPSIS_STATUS_PROJECT:-}")"
      - name: "KAPSIS_STATUS_AGENT_ID"
        value: "$(_yaml_escape "$AGENT_ID")"
      - name: "KAPSIS_STATUS_BRANCH"
        value: "$(_yaml_escape "${BRANCH:-}")"
      - name: "KAPSIS_INJECT_GIST"
        value: "${INJECT_GIST:-false}"
YAML

    # Audit environment variables (if enabled)
    if [[ "${KAPSIS_AUDIT_ENABLED:-${KAPSIS_DEFAULT_AUDIT_ENABLED}}" == "true" ]]; then
        cat <<YAML
      - name: "KAPSIS_AUDIT_ENABLED"
        value: "true"
YAML
    fi

    # Optional: additional env vars from caller
    if [[ -n "$extra_env_var_name" ]]; then
        local -n _extra_arr="$extra_env_var_name"  # nameref (bash 4.3+)
        if (( ${#_extra_arr[@]} > 0 )); then
            generate_env_yaml "$extra_env_var_name"
        fi
    fi

    # Liveness section (if enabled)
    if [[ "${LIVENESS_ENABLED:-false}" == "true" ]]; then
        cat <<YAML
  liveness:
    enabled: true
    timeoutSeconds: ${LIVENESS_TIMEOUT:-900}
    gracePeriodSeconds: ${LIVENESS_GRACE_PERIOD:-300}
YAML
    fi

    # Network and security
    cat <<YAML
  network:
    mode: "$(_yaml_escape "${NETWORK_MODE:-filtered}")"
  security:
    profile: "$(_yaml_escape "${SECURITY_PROFILE:-standard}")"
    serviceAccountName: kapsis-agent
  ttl: 3600
YAML
}
