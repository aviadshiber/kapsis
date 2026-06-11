#!/usr/bin/env bash
#===============================================================================
# Kapsis - Workflow Orchestrator (Issue #85 / Phase 4)
#
# Launches a multi-stage privileged-separated workflow, running each stage in
# its own isolated container with per-stage network mode, security profile, and
# credential set. No stage has all three "Lethal Trifecta" risk factors at once.
#
# Usage:
#   ./scripts/workflow-orchestrator.sh <project-path> [options]
#
# Options:
#   --workflow <file>        Workflow YAML file (overrides agent-sandbox.yaml)
#   --start-from <stage>     Resume from a specific stage (skips earlier stages)
#   --approve-policy <p>     Global approval policy override
#                              Policies: small_changes, docs_only, tests_only, always, never
#   --dry-run                Show what would run without executing
#   --agent <name>           Agent shortcut for all stages (claude, codex, …)
#   --branch <name>          Git branch for the implementation stage
#   --push                   Push changes after the implementation stage
#   [pass-through args]      All other args forwarded to launch-agent.sh
#
# Examples:
#   ./scripts/workflow-orchestrator.sh ~/project --workflow ./workflow.yaml
#   ./scripts/workflow-orchestrator.sh ~/project --start-from implementation
#   ./scripts/workflow-orchestrator.sh ~/project --approve-policy always --dry-run
#
# Exit codes:
#   0 - All stages completed successfully
#   1 - A stage failed
#   3 - Approval gate denied transition
#   7 - Workflow aborted by operator
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/logging.sh"
log_init "workflow-orchestrator"

source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/staged-workflows.sh"

#===============================================================================
# DEFAULTS
#===============================================================================

PROJECT_PATH=""
WORKFLOW_CONFIG=""
START_FROM_STAGE=""
APPROVE_POLICY_OVERRIDE=""
DRY_RUN=false
PASSTHROUGH_ARGS=()

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage 1
    fi
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage 0
    fi

    PROJECT_PATH="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workflow)
                WORKFLOW_CONFIG="$2"
                shift 2
                ;;
            --start-from)
                START_FROM_STAGE="$2"
                shift 2
                ;;
            --approve-policy)
                APPROVE_POLICY_OVERRIDE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                PASSTHROUGH_ARGS+=("--dry-run")
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                # Forward everything else to launch-agent.sh
                PASSTHROUGH_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

usage() {
    cat << 'EOF'
Usage: workflow-orchestrator.sh <project-path> [options]

Runs a privilege-separated multi-stage Kapsis workflow. Each stage executes in
its own isolated container with a tailored network mode, security profile, and
credential set — no stage has all three Lethal Trifecta risk factors at once.

Options:
  --workflow <file>        Workflow YAML / agent-sandbox.yaml with a 'workflow:' section
  --start-from <stage>     Skip stages before this one (for resuming after failure)
  --approve-policy <p>     Override all approval gates: always | small_changes |
                           docs_only | tests_only | never (interactive)
  --dry-run                Print plan without executing
  -h, --help               Show this help

All other flags are forwarded to launch-agent.sh (--agent, --branch, --push, …).

Examples:
  ./scripts/workflow-orchestrator.sh ~/project \
      --workflow ./agent-sandbox.yaml --branch feature/DEV-42 --push

  # Resume after implementation failed:
  ./scripts/workflow-orchestrator.sh ~/project --start-from publish
EOF
    exit "${1:-0}"
}

#===============================================================================
# WORKFLOW STATE
#===============================================================================

WORKFLOW_ID=""
WORKFLOW_STATE_DIR=""
WORKFLOW_STATE_FILE=""

_init_workflow_state() {
    local ts
    ts=$(date +"%Y%m%d-%H%M%S" 2>/dev/null || date +"%s")
    WORKFLOW_ID="workflow-${ts}-$$"
    WORKFLOW_STATE_DIR="${HOME}/.kapsis/workflows/${WORKFLOW_ID}"
    WORKFLOW_STATE_FILE="${WORKFLOW_STATE_DIR}/state.json"

    mkdir -p "$WORKFLOW_STATE_DIR"

    cat > "$WORKFLOW_STATE_FILE" << EOF
{
  "workflow_id": "$WORKFLOW_ID",
  "started_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "running",
  "stages": {}
}
EOF
    log_info "Workflow state: $WORKFLOW_STATE_FILE"
}

_update_stage_state() {
    local stage_name="$1"
    local status="$2"
    local exit_code="${3:-}"
    local agent_id="${4:-}"

    [[ ! -f "$WORKFLOW_STATE_FILE" ]] && return 0

    # Use python3 to safely update JSON (jq not always available)
    python3 -c "
import json, sys
with open('$WORKFLOW_STATE_FILE', 'r') as f:
    state = json.load(f)

from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

stage_entry = state['stages'].get('$stage_name', {})
stage_entry['status'] = '$status'
if '$exit_code':
    stage_entry['exit_code'] = int('$exit_code') if '$exit_code'.isdigit() else '$exit_code'
if '$agent_id':
    stage_entry['agent_id'] = '$agent_id'
if '$status' == 'running':
    stage_entry['started_at'] = now
elif '$status' in ('complete', 'failed'):
    stage_entry['completed_at'] = now

state['stages']['$stage_name'] = stage_entry

with open('$WORKFLOW_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || log_warn "Could not update workflow state for stage '$stage_name'"
}

#===============================================================================
# STAGE EXECUTION
#===============================================================================

_run_stage() {
    local stage_name="$1"
    local config_file="$2"
    local prev_stage="${3:-}"
    shift 3
    local extra_args=("$@")

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Stage: $stage_name"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Generate a fresh agent ID for this stage
    local agent_id
    agent_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-6 || printf '%x' "$$" | cut -c1-6)

    _update_stage_state "$stage_name" "running" "" "$agent_id"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would launch stage '$stage_name' (agent_id=$agent_id)"
        log_info "[DRY-RUN] launch-agent.sh $PROJECT_PATH --stage $stage_name --config $config_file ${extra_args[*]:-}"
        _update_stage_state "$stage_name" "complete" "0" "$agent_id"
        return 0
    fi

    # Safety: use env -i so the orchestrator's credentials don't leak into Research stage.
    # Launch-agent.sh re-reads credential config from YAML; this prevents the host
    # environment from bypassing stage-based credential filtering.
    local safe_env=(
        "HOME=$HOME"
        "PATH=$PATH"
        "USER=${USER:-developer}"
        "TERM=${TERM:-xterm}"
        "KAPSIS_DEBUG=${KAPSIS_DEBUG:-}"
        "KAPSIS_LOG_LEVEL=${KAPSIS_LOG_LEVEL:-}"
    )

    # Preserve any KAPSIS_* vars the user explicitly set for this workflow run
    # (but not secrets — those come from YAML keychain)
    while IFS='=' read -r key val; do
        case "$key" in
            KAPSIS_NETWORK_MODE|KAPSIS_SECURITY_PROFILE|KAPSIS_PREVENT_SLEEP|\
            KAPSIS_KEEP_WORKTREE|KAPSIS_KEEP_VOLUMES|KAPSIS_IMAGE|\
            KAPSIS_LOG_LEVEL|KAPSIS_DEBUG)
                safe_env+=("${key}=${val}")
                ;;
        esac
    done < <(env | grep '^KAPSIS_')

    local exit_code=0
    env -i "${safe_env[@]}" \
        "$SCRIPT_DIR/launch-agent.sh" \
        "$PROJECT_PATH" \
        --stage "$stage_name" \
        --config "$config_file" \
        "${extra_args[@]}" \
        "${PASSTHROUGH_ARGS[@]}" \
        || exit_code=$?

    _update_stage_state "$stage_name" "$([ "$exit_code" -eq 0 ] && echo complete || echo failed)" "$exit_code" "$agent_id"

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Stage '$stage_name' failed with exit code $exit_code"
        return "$exit_code"
    fi

    log_success "Stage '$stage_name' completed"

    # Write handoff (best-effort: if worktree not found, just skip)
    local worktree_path=""
    # Try to find the most recent worktree for this agent
    worktree_path=$(find "${HOME}/.kapsis/worktrees" -maxdepth 2 -name "*${agent_id}*" -type d 2>/dev/null | head -1 || true)

    stage_write_handoff "$stage_name" "$agent_id" "$worktree_path" \
        "Stage '$stage_name' completed successfully" >/dev/null 2>&1 || true

    return 0
}

#===============================================================================
# MAIN ORCHESTRATION LOOP
#===============================================================================

main() {
    parse_args "$@"

    # Resolve config file
    local config_file="${WORKFLOW_CONFIG:-}"
    if [[ -z "$config_file" ]]; then
        # Use same config resolution as launch-agent.sh
        for candidate in \
            "${PROJECT_PATH}/agent-sandbox.yaml" \
            "${PROJECT_PATH}/.kapsis/config.yaml" \
            "${HOME}/.config/kapsis/default.yaml"; do
            if [[ -f "$candidate" ]]; then
                config_file="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_warn "No config file found; using built-in stage defaults"
        config_file="/dev/null"
    fi

    # Load staged workflow config
    stage_load_config "$config_file"

    local all_stages
    all_stages=$(stage_list)
    if [[ -z "$all_stages" ]]; then
        log_error "No stages defined. Add a 'workflow.stages' section to your config."
        exit 1
    fi

    # Override approval policy if requested
    if [[ -n "$APPROVE_POLICY_OVERRIDE" ]]; then
        _SW_APPROVAL_POLICIES=("$APPROVE_POLICY_OVERRIDE")
        _SW_APPROVAL_REQUIRE_MANUAL="false"
        log_info "Approval policy override: $APPROVE_POLICY_OVERRIDE"
    fi

    log_info "Workflow: $all_stages"
    _init_workflow_state

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Workflow plan:"
        stage_print_summary
    fi

    # Determine starting point
    local skip_until="${START_FROM_STAGE:-}"
    local prev_stage=""
    local stage_array
    read -ra stage_array <<< "$all_stages"

    for stage_name in "${stage_array[@]}"; do
        # Skip stages before start-from
        if [[ -n "$skip_until" && "$stage_name" != "$skip_until" ]]; then
            log_info "Skipping stage '$stage_name' (--start-from $skip_until)"
            prev_stage="$stage_name"
            continue
        fi
        skip_until=""  # clear once we've reached the start-from stage

        # Check approval gate before running this stage
        if [[ -n "$prev_stage" ]]; then
            log_info "Checking approval gate: $prev_stage → $stage_name"
            if ! stage_check_approval_gate "$KAPSIS_HANDOFF_DIR" "$prev_stage" "$stage_name" "$WORKFLOW_ID"; then
                log_error "Approval gate denied transition: $prev_stage → $stage_name"
                exit 3
            fi
        fi

        # Run the stage; pass any stage-specific extra args
        local stage_exit=0
        _run_stage "$stage_name" "$config_file" "$prev_stage" || stage_exit=$?

        if [[ "$stage_exit" -ne 0 ]]; then
            log_error "Workflow failed at stage '$stage_name' (exit $stage_exit)"
            log_error "Resume with: $0 $PROJECT_PATH --start-from $stage_name [options]"
            exit "$stage_exit"
        fi

        prev_stage="$stage_name"
    done

    log_success "Workflow completed: all stages passed"
    log_info "State saved to: $WORKFLOW_STATE_FILE"
}

main "$@"
