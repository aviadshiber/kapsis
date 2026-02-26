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

# Generate YAML env: block from a bash array variable name
# Arguments: $1 = name of the array variable (not the array itself)
# Output: YAML lines for env entries
generate_env_yaml() {
    local -n arr_ref="$1"
    local entry name value
    for entry in "${arr_ref[@]}"; do
        name="${entry%%=*}"
        value="${entry#*=}"
        echo "      - name: $name"
        echo "        value: \"$value\""
    done
}

#===============================================================================
# CR GENERATOR
#===============================================================================

# Generate a complete AgentRequest CR YAML from launch-agent.sh globals
# Required globals: AGENT_ID, IMAGE_NAME, AGENT_NAME, RESOURCE_MEMORY,
#   RESOURCE_CPUS, BRANCH, TASK_DESCRIPTION, NETWORK_MODE, SECURITY_PROFILE,
#   AGENT_COMMAND[]
# Optional globals: INLINE_SPEC_FILE, GIT_REMOTE_URL, BASE_BRANCH, DO_PUSH
generate_agent_request_cr() {
    local k8s_memory k8s_cpu
    k8s_memory=$(translate_memory_to_k8s "${RESOURCE_MEMORY:-8g}")
    k8s_cpu=$(translate_cpus_to_k8s "${RESOURCE_CPUS:-4}")

    # Build command array YAML
    local cmd_yaml=""
    if [[ ${#AGENT_COMMAND[@]} -gt 0 ]]; then
        cmd_yaml="    command:"
        local arg
        for arg in "${AGENT_COMMAND[@]}"; do
            cmd_yaml="$cmd_yaml
      - \"$arg\""
        done
    fi

    cat <<YAML
apiVersion: kapsis.io/v1alpha1
kind: AgentRequest
metadata:
  name: kapsis-${AGENT_ID}
  labels:
    kapsis.io/agent-type: ${AGENT_NAME}
    kapsis.io/agent-id: ${AGENT_ID}
spec:
  image: ${IMAGE_NAME}
  agent:
    type: ${AGENT_NAME}
${cmd_yaml}
    workdir: /workspace
  resources:
    memory: "${k8s_memory}"
    cpu: "${k8s_cpu}"
YAML

    # Git section (only if branch is set)
    if [[ -n "${BRANCH:-}" ]]; then
        cat <<YAML
  git:
    branch: ${BRANCH}
    baseBranch: ${BASE_BRANCH:-main}
    push: ${DO_PUSH:-false}
YAML
        # Add repoUrl if available
        if [[ -n "${GIT_REMOTE_URL:-}" ]]; then
            echo "    repoUrl: ${GIT_REMOTE_URL}"
        fi
    fi

    # Task section
    if [[ -n "${TASK_DESCRIPTION:-}" ]]; then
        cat <<YAML
  task:
    inline: "${TASK_DESCRIPTION}"
YAML
    fi

    # Environment section
    cat <<YAML
  environment:
    vars:
      - name: KAPSIS_BACKEND
        value: k8s
      - name: KAPSIS_AGENT_ID
        value: "${AGENT_ID}"
      - name: KAPSIS_AGENT_TYPE
        value: "${AGENT_NAME}"
YAML

    # Network section
    cat <<YAML
  network:
    mode: ${NETWORK_MODE:-filtered}
  security:
    profile: ${SECURITY_PROFILE:-standard}
    serviceAccountName: kapsis-agent
  ttl: 3600
YAML
}
