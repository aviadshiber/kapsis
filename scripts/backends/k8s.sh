#!/usr/bin/env bash
#===============================================================================
# Kapsis Backend: Kubernetes
#
# Implements the backend interface for K8s Pod execution via AgentRequest CRD.
# Creates CRs instead of running local Podman containers.
#
# Backend Interface:
#   backend_validate      - Check kubectl is available and CRD exists
#   backend_build_spec    - Generate AgentRequest CR YAML
#   backend_run           - Apply CR and poll until completion
#   backend_get_exit_code - Get the exit code from the last run
#   backend_cleanup       - Clean up K8s resources and temp files
#   backend_supports      - Check feature support
#===============================================================================

# Guard against multiple sourcing
if [[ -n "${_KAPSIS_BACKEND_K8S_LOADED:-}" ]]; then
    return 0
fi
readonly _KAPSIS_BACKEND_K8S_LOADED=1

# Source the K8s config translator (double-source guard prevents re-execution)
source "$SCRIPT_DIR/lib/k8s-config.sh"

# K8s backend state
_BACKEND_EXIT_CODE=1
_K8S_CR_NAME=""
_K8S_CR_FILE=""
_K8S_NAMESPACE="${KAPSIS_K8S_NAMESPACE:-${KAPSIS_K8S_DEFAULT_NAMESPACE}}"

#===============================================================================
# BACKEND INTERFACE FUNCTIONS
#===============================================================================

# Validate that kubectl is available and CRD exists
backend_validate() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "Skipping K8s checks (dry-run mode)"
        return 0
    fi

    log_debug "Checking kubectl availability..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        return 1
    fi
    log_debug "kubectl found at: $(command -v kubectl)"

    # Check kubeconfig is valid
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        return 1
    fi

    # Check AgentRequest CRD is installed
    if ! kubectl get crd agentrequests.kapsis.io &>/dev/null; then
        log_error "AgentRequest CRD not found. Install the kapsis operator first."
        log_error "  kubectl apply -f operator/config/crd/bases/kapsis.io_agentrequests.yaml"
        return 1
    fi

    return 0
}

# Build the AgentRequest CR YAML
# Sets global: _K8S_CR_FILE, _K8S_CR_NAME
backend_build_spec() {
    log_info "K8s backend: generating AgentRequest CR"

    _K8S_CR_NAME="kapsis-${AGENT_ID}"
    _K8S_CR_FILE=$(mktemp)

    generate_agent_request_cr > "$_K8S_CR_FILE"

    # For dry-run, output the CR YAML
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN - AgentRequest CR that would be applied:"
        echo ""
        cat "$_K8S_CR_FILE"
        echo ""
    fi
}

# Apply the CR and poll until completion
# Arguments: $1 = output file path
backend_run() {
    local container_output="$1"

    log_info "Applying AgentRequest CR: $_K8S_CR_NAME"
    kubectl apply -f "$_K8S_CR_FILE" -n "$_K8S_NAMESPACE"

    local poll_interval="${KAPSIS_K8S_POLL_INTERVAL:-${KAPSIS_K8S_DEFAULT_POLL_INTERVAL}}"
    local max_timeout="${KAPSIS_K8S_TIMEOUT:-${KAPSIS_K8S_DEFAULT_TIMEOUT}}"
    local start_seconds=$SECONDS
    local consecutive_failures=0
    local max_consecutive_failures=10

    while true; do
        # Timeout check (safety net for stuck CRs)
        local elapsed=$(( SECONDS - start_seconds ))
        if (( elapsed >= max_timeout )); then
            log_error "K8s backend: timeout after ${elapsed}s waiting for CR $_K8S_CR_NAME"
            _BACKEND_EXIT_CODE=124
            return 0
        fi

        # Single kubectl call for all status fields (consolidated)
        local cr_status
        cr_status=$(kubectl get agentrequest "$_K8S_CR_NAME" -n "$_K8S_NAMESPACE" \
            -o jsonpath='{.status.phase}{"\t"}{.status.progress}{"\t"}{.status.message}{"\t"}{.status.gist}' 2>/dev/null) || cr_status=""

        # Track consecutive kubectl failures
        if [[ -z "$cr_status" ]]; then
            ((consecutive_failures++)) || true
            if (( consecutive_failures >= max_consecutive_failures )); then
                log_error "K8s backend: kubectl failed ${max_consecutive_failures} consecutive times, giving up"
                _BACKEND_EXIT_CODE=1
                return 0
            elif (( consecutive_failures >= 3 )); then
                log_warn "K8s backend: kubectl failed ${consecutive_failures} consecutive times"
            fi
            sleep "$poll_interval"
            continue
        fi
        consecutive_failures=0

        local phase progress message gist
        IFS=$'\t' read -r phase progress message gist <<< "$cr_status"

        # Bridge CR status to local kapsis status system
        case "$phase" in
            Pending)        status_phase "preparing" "${progress:-5}" "${message:-Waiting for pod}" ;;
            Initializing)   status_phase "initializing" "${progress:-10}" "${message:-Pod initializing}" ;;
            Running)        status_phase "running" "${progress:-50}" "${message:-Agent running}" ;;
            PostProcessing) status_phase "committing" "${progress:-85}" "${message:-Post-processing}" ;;
            Complete|Failed) break ;;
        esac

        [[ -n "$gist" ]] && status_set_gist "$gist"

        sleep "$poll_interval"
    done

    # Single kubectl call for final status fields (consolidated)
    local final_status
    final_status=$(kubectl get agentrequest "$_K8S_CR_NAME" -n "$_K8S_NAMESPACE" \
        -o jsonpath='{.status.exitCode}{"\t"}{.status.podName}' 2>/dev/null) || final_status=""

    local exit_code_str pod_name
    IFS=$'\t' read -r exit_code_str pod_name <<< "$final_status"
    _BACKEND_EXIT_CODE="${exit_code_str:-1}"

    # Capture pod logs for error reporting
    if [[ -n "$pod_name" ]]; then
        kubectl logs "$pod_name" -n "$_K8S_NAMESPACE" > "$container_output" 2>&1 || true
    fi
}

# Get the exit code from the last backend_run()
backend_get_exit_code() {
    echo "${_BACKEND_EXIT_CODE:-1}"
}

# Clean up K8s resources
backend_cleanup() {
    [[ -n "${_K8S_CR_FILE:-}" && -f "$_K8S_CR_FILE" ]] && rm -f "$_K8S_CR_FILE"

    # Delete the CR (cascades to Pod via ownerReferences)
    if [[ -n "${_K8S_CR_NAME:-}" ]]; then
        kubectl delete agentrequest "$_K8S_CR_NAME" -n "$_K8S_NAMESPACE" --ignore-not-found 2>/dev/null || true
    fi
}

# Check if this backend supports a given feature
# Returns: 0 if supported, 1 if not
backend_supports() {
    local feature="$1"
    case "$feature" in
        worktree) return 0 ;;  # K8s pods clone and handle git
        interactive|overlay|dns-filtering) return 1 ;;
        *) return 1 ;;
    esac
}
