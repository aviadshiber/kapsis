#!/usr/bin/env bash
#===============================================================================
# Kapsis - Stage Approval CLI (Issue #85 / Phase 4)
#
# Approve or reject a pending approval gate for a staged workflow transition.
# Works in both interactive (TTY) and unattended (CI/Slack-bot) modes.
#
# Usage:
#   ./scripts/kapsis-approve.sh --workflow <id> --stage <name> --approve
#   ./scripts/kapsis-approve.sh --workflow <id> --stage <name> --reject [--reason "msg"]
#   ./scripts/kapsis-approve.sh --list         # Show pending approvals
#
# Examples:
#   # Approve transition to 'implementation' stage
#   ./scripts/kapsis-approve.sh --workflow workflow-20260611-143022-12345 \
#       --stage research --approve
#
#   # Reject with a reason
#   ./scripts/kapsis-approve.sh --workflow workflow-20260611-143022-12345 \
#       --stage research --reject --reason "Findings incomplete, re-run research"
#
#   # List all pending approvals
#   ./scripts/kapsis-approve.sh --list
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
log_init "kapsis-approve"

#===============================================================================
# DEFAULTS
#===============================================================================

WORKFLOW_ID=""
STAGE_NAME=""
ACTION=""           # approve | reject | list
REASON=""
WORKFLOWS_DIR="${HOME}/.kapsis/workflows"

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

usage() {
    cat << 'EOF'
Usage: kapsis-approve.sh [options]

Approve or reject a pending Kapsis staged workflow gate.

Options:
  --workflow <id>     Workflow ID (from workflow state directory name)
  --stage <name>      Stage name whose gate is pending approval
  --approve           Mark gate as approved
  --reject            Mark gate as rejected
  --reason <msg>      Rejection reason (optional, recorded in audit)
  --list              List all pending approval gates
  -h, --help          Show this help

Examples:
  kapsis-approve.sh --list
  kapsis-approve.sh --workflow workflow-20260611-143022-123 --stage research --approve
  kapsis-approve.sh --workflow workflow-20260611-143022-123 --stage research --reject \
      --reason "Findings are incomplete"
EOF
    exit "${1:-0}"
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workflow)
                WORKFLOW_ID="$2"
                shift 2
                ;;
            --stage)
                STAGE_NAME="$2"
                shift 2
                ;;
            --approve)
                ACTION="approve"
                shift
                ;;
            --reject)
                ACTION="reject"
                shift
                ;;
            --reason)
                REASON="$2"
                shift 2
                ;;
            --list)
                ACTION="list"
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage 1
                ;;
        esac
    done
}

#===============================================================================
# LIST PENDING APPROVALS
#===============================================================================

list_pending() {
    local found=0
    local workflow_dir

    if [[ ! -d "$WORKFLOWS_DIR" ]]; then
        echo "No workflows found (directory does not exist: $WORKFLOWS_DIR)"
        return 0
    fi

    for workflow_dir in "${WORKFLOWS_DIR}"/*/; do
        [[ -d "$workflow_dir" ]] || continue
        local wf_id
        wf_id=$(basename "$workflow_dir")
        local pending_dir="${workflow_dir}approvals"

        [[ -d "$pending_dir" ]] || continue

        local pending_file
        for pending_file in "${pending_dir}"/*.pending.json; do
            [[ -f "$pending_file" ]] || continue
            found=$((found + 1))
            local stage_from_file
            stage_from_file=$(basename "$pending_file" .pending.json)

            echo "Workflow: $wf_id"
            echo "  Stage:     $stage_from_file"
            echo "  State:     PENDING APPROVAL"
            echo "  File:      $pending_file"
            if command -v python3 &>/dev/null; then
                python3 -c "
import json
try:
    d = json.load(open('$pending_file'))
    print('  Requested: ' + d.get('requested_at', 'unknown'))
    files = d.get('files_changed', 'unknown')
    lines = d.get('lines_changed', 'unknown')
    print(f'  Changes:   {files} files, {lines} lines')
except Exception:
    pass
" 2>/dev/null || true
            fi
            echo ""
            echo "  To approve: $(basename "$0") --workflow $wf_id --stage $stage_from_file --approve"
            echo "  To reject:  $(basename "$0") --workflow $wf_id --stage $stage_from_file --reject"
            echo ""
        done
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No pending approval gates found."
    fi
}

#===============================================================================
# APPROVE / REJECT
#===============================================================================

do_approve() {
    local workflow_dir="${WORKFLOWS_DIR}/${WORKFLOW_ID}"
    if [[ ! -d "$workflow_dir" ]]; then
        log_error "Workflow not found: $WORKFLOW_ID"
        log_error "List workflows: ls $WORKFLOWS_DIR"
        exit 1
    fi

    local pending_dir="${workflow_dir}/approvals"
    local pending_file="${pending_dir}/${STAGE_NAME}.pending.json"

    if [[ ! -f "$pending_file" ]]; then
        log_error "No pending approval for stage '$STAGE_NAME' in workflow '$WORKFLOW_ID'"
        log_error "List pending: $(basename "$0") --list"
        exit 1
    fi

    local approved_file="${pending_dir}/${STAGE_NAME}.approved.json"
    local approver="${USER:-operator}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$approved_file" << EOF
{
  "approved_by": "$approver",
  "approved_at": "$ts",
  "workflow_id": "$WORKFLOW_ID",
  "stage": "$STAGE_NAME",
  "comment": ""
}
EOF

    log_success "Gate approved: $WORKFLOW_ID / $STAGE_NAME → transition may proceed"
}

do_reject() {
    local workflow_dir="${WORKFLOWS_DIR}/${WORKFLOW_ID}"
    if [[ ! -d "$workflow_dir" ]]; then
        log_error "Workflow not found: $WORKFLOW_ID"
        exit 1
    fi

    local pending_dir="${workflow_dir}/approvals"
    local pending_file="${pending_dir}/${STAGE_NAME}.pending.json"

    if [[ ! -f "$pending_file" ]]; then
        log_error "No pending approval for stage '$STAGE_NAME' in workflow '$WORKFLOW_ID'"
        exit 1
    fi

    local rejected_file="${pending_dir}/${STAGE_NAME}.rejected.json"
    local rejecter="${USER:-operator}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    # Sanitize reason for JSON embedding
    local safe_reason="${REASON//\\/\\\\}"
    safe_reason="${safe_reason//\"/\\\"}"

    cat > "$rejected_file" << EOF
{
  "rejected_by": "$rejecter",
  "rejected_at": "$ts",
  "workflow_id": "$WORKFLOW_ID",
  "stage": "$STAGE_NAME",
  "reason": "$safe_reason"
}
EOF

    log_warn "Gate rejected: $WORKFLOW_ID / $STAGE_NAME — workflow will abort"
    [[ -n "$REASON" ]] && log_warn "Reason: $REASON"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    parse_args "$@"

    case "$ACTION" in
        list)
            list_pending
            ;;
        approve)
            if [[ -z "$WORKFLOW_ID" || -z "$STAGE_NAME" ]]; then
                log_error "--workflow and --stage are required for --approve"
                usage 1
            fi
            do_approve
            ;;
        reject)
            if [[ -z "$WORKFLOW_ID" || -z "$STAGE_NAME" ]]; then
                log_error "--workflow and --stage are required for --reject"
                usage 1
            fi
            do_reject
            ;;
        "")
            usage 0
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage 1
            ;;
    esac
}

main "$@"
