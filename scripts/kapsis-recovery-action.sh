#!/usr/bin/env bash
#===============================================================================
# Kapsis Recovery Action — Determine recovery action from agent error_type
#
# Reads a completed Kapsis agent's status JSON and outputs the recommended
# recovery action based on the structured error_type field (Issue #262).
#
# Callers (slack-bot, CI pipelines, orchestration scripts) can branch on
# the exit code without parsing output:
#
#   Exit codes:
#     0  Action is 'retry' or 'retry_push' — safe to automate
#     1  Action is 'notify_human'           — manual intervention required
#     2  Action is 'restart_and_retry'      — restart Podman VM, then retry
#     3  Error: status file not found, agent still running, or CLI usage error
#
# Usage:
#   kapsis-recovery-action <project> <agent-id>
#   kapsis-recovery-action --status-file <path>
#   kapsis-recovery-action --json <project> <agent-id>
#
# Examples:
#   # Bash caller branching on exit code:
#   kapsis-recovery-action myproject 42
#   case $? in
#     0) run_agent_again ;;
#     1) notify_slack "needs human review" ;;
#     2) restart_podman_vm && run_agent_again ;;
#   esac
#
#   # Machine-parseable JSON for rich downstream handling:
#   kapsis-recovery-action --json myproject 42 | jq '.action'
#
# Error type → action mapping:
#   agent_failure       → retry
#   push_failure        → retry_push
#   mount_failure       → restart_and_retry
#   agent_partial       → notify_human
#   commit_failure      → notify_human
#   uncommitted_work    → notify_human
#   hung_after_completion (work committed)   → notify_human
#   hung_after_completion (work uncommitted) → retry
#   <unknown>           → notify_human
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# json_escape_string (handles \r, \n, \t, backslash, quotes) and json_get_*
source "$SCRIPT_DIR/lib/json-utils.sh"

KAPSIS_STATUS_DIR="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Max bytes to read from a status file (1 MiB) — guards against huge files
# ballooning memory during the multiple json_get_* regex passes.
_MAX_STATUS_BYTES=1048576

#===============================================================================
# USAGE
# $1 — exit code (default 0); pass 3 for error paths so CLI typos don't
#      return 0 and silently satisfy callers that branch on "exit 0 = retry".
#===============================================================================

usage() {
    local exit_code="${1:-0}"
    local cmd="${KAPSIS_CMD_NAME:-$(basename "$0")}"
    cat << EOF
Usage: $cmd [--json] <project> <agent-id>
       $cmd [--json] --status-file <path>

Determine the recommended recovery action for a failed Kapsis agent run.

Options:
  -h, --help              Show this help message
  -j, --json              Output machine-readable JSON
  -f, --status-file PATH  Read status from a specific JSON file path
                          When supplied, positional project/agent-id are ignored.

Arguments:
  project    Project name (alphanumeric, dots, hyphens, underscores only)
  agent-id   Agent ID  (alphanumeric, dots, hyphens, underscores only)

Exit codes:
  0  Action is 'retry' or 'retry_push'  — caller can automate
  1  Action is 'notify_human'           — manual intervention required
  2  Action is 'restart_and_retry'      — restart Podman VM first, then retry
  3  Error: status file not found, unreadable, agent still running, or bad CLI args

Examples:
  $cmd myproject 42                          # human-readable guidance
  $cmd --json myproject 42                   # machine-parseable JSON
  $cmd --status-file ~/.kapsis/status/kapsis-myproject-42.json

  # Branch on exit code in a caller script:
  if $cmd myproject 42; then
    echo "Safe to retry automatically"
  fi
EOF
    exit "$exit_code"
}

#===============================================================================
# INPUT VALIDATION
# project and agent_id are interpolated into file paths; validate them
# strictly to prevent directory traversal / arbitrary file reads.
#===============================================================================

_validate_id() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: $name must contain only alphanumeric characters, dots, hyphens, or underscores" >&2
        echo "Got: '$value'" >&2
        exit 3
    fi
}

#===============================================================================
# ACTION RESOLUTION
# Maps error_type → action, taking commit_status into account for
# hung_after_completion where the right action depends on whether work
# was committed before the agent hung.
#===============================================================================

_resolve_action() {
    local error_type="$1"
    local commit_status="$2"

    case "$error_type" in
        agent_failure)
            echo "retry"
            ;;
        push_failure)
            echo "retry_push"
            ;;
        mount_failure)
            echo "restart_and_retry"
            ;;
        hung_after_completion)
            # Work was committed — no need to re-run the agent
            if [[ "$commit_status" == "success" || "$commit_status" == "no_changes" ]]; then
                echo "notify_human"
            else
                echo "retry"
            fi
            ;;
        agent_partial|commit_failure|uncommitted_work)
            echo "notify_human"
            ;;
        *)
            echo "notify_human"
            ;;
    esac
}

_describe_action() {
    local action="$1"
    local error_type="${2:-unknown}"

    case "$action" in
        retry)
            echo "The agent failed but no work was lost. It is safe to retry automatically."
            ;;
        retry_push)
            echo "The agent's work is committed locally. Only the git push needs to be retried."
            ;;
        restart_and_retry)
            echo "The Podman VM's virtio-fs mount failed. Restart the VM before retrying."
            ;;
        notify_human)
            case "$error_type" in
                agent_partial)
                    echo "The agent completed partial work that was committed. Review the branch before deciding to continue."
                    ;;
                commit_failure)
                    echo "The agent produced changes but git commit failed. The staged worktree is preserved for manual recovery."
                    ;;
                uncommitted_work)
                    echo "The agent exited with uncommitted changes in the worktree. Manual commit is required."
                    ;;
                hung_after_completion)
                    echo "The agent completed and committed its work before hanging. Review the branch — no retry needed."
                    ;;
                *)
                    echo "The failure mode requires human review. Do NOT retry automatically."
                    ;;
            esac
            ;;
    esac
}

#===============================================================================
# NEXT-STEP GUIDANCE
# Per-error-type concrete shell commands to guide recovery.
#
# Dynamic values (branch, worktree_path, push_fallback) that appear inside
# suggested shell commands are single-quoted so that shell metacharacters in
# those values do not execute when a user copies the suggestion verbatim.
#
# Caller must declare 'local -a next_steps=()' before calling this function.
#===============================================================================

_build_next_steps() {
    local error_type="$1"
    local action="$2"
    local worktree_path="$3"
    local push_fallback="$4"
    local branch="$5"

    case "$error_type" in
        agent_failure)
            next_steps+=("Re-run the agent with the same task")
            ;;
        agent_partial)
            if [[ -n "$branch" && "$branch" != "null" ]]; then
                next_steps+=("git log 'origin/${branch}' --oneline  # review committed work")
            fi
            next_steps+=("Decide whether to continue with a new agent run or handle manually")
            next_steps+=("Do NOT retry blindly — partial work is already on the branch")
            ;;
        commit_failure)
            if [[ -n "$worktree_path" && "$worktree_path" != "null" ]]; then
                next_steps+=("cd '${worktree_path}'")
                next_steps+=("git status              # see what is staged")
                next_steps+=("git diff --cached       # review staged changes")
                next_steps+=("git commit -m 'fix: manual recovery commit'")
            else
                next_steps+=("Locate the preserved worktree (check ~/.kapsis/logs for worktree path)")
                next_steps+=("git status && git diff --cached")
                next_steps+=("git commit -m 'fix: manual recovery commit'")
            fi
            ;;
        push_failure)
            if [[ -n "$push_fallback" && "$push_fallback" != "null" ]]; then
                next_steps+=("${push_fallback}  # push fallback from status.json")
            else
                if [[ -n "$worktree_path" && "$worktree_path" != "null" ]]; then
                    next_steps+=("cd '${worktree_path}'")
                fi
                next_steps+=("git push -u origin <branch>  # work is committed; just push")
            fi
            ;;
        mount_failure)
            next_steps+=("podman machine stop")
            next_steps+=("podman machine start")
            next_steps+=("Re-run the agent with the same task")
            ;;
        hung_after_completion)
            if [[ "$action" == "notify_human" ]]; then
                if [[ -n "$branch" && "$branch" != "null" ]]; then
                    next_steps+=("git log 'origin/${branch}' --oneline  # verify committed work")
                fi
                next_steps+=("Review the committed changes and create a PR if satisfied")
                next_steps+=("Do NOT retry — work was already committed before the hang")
            else
                next_steps+=("The agent hung before committing. Re-run with the same task.")
            fi
            ;;
        uncommitted_work)
            if [[ -n "$worktree_path" && "$worktree_path" != "null" ]]; then
                next_steps+=("cd '${worktree_path}'")
                next_steps+=("git status              # see what is uncommitted")
                next_steps+=("git add -A && git commit -m 'fix: manual recovery commit'")
            else
                next_steps+=("Locate the worktree (check ~/.kapsis/logs for worktree path)")
                next_steps+=("git add -A && git commit -m 'fix: manual recovery commit'")
            fi
            ;;
        *)
            next_steps+=("Review the agent logs: tail -100 ~/.kapsis/logs/kapsis-launch-agent.log")
            next_steps+=("Inspect status file for more details")
            next_steps+=("Alert the team for manual review")
            ;;
    esac
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    local json_mode=false
    local status_file=""
    local project=""
    local agent_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -j|--json)
                json_mode=true
                shift
                ;;
            -f|--status-file)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --status-file requires a path argument" >&2
                    exit 3
                fi
                status_file="$2"
                shift 2
                ;;
            -*)
                # Unknown option — exit 3, not 0, so CLI typos don't look like
                # "retry" to callers that branch on exit code.
                echo "Error: unknown option '$1'" >&2
                usage 3
                ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$agent_id" ]]; then
                    agent_id="$1"
                else
                    echo "Error: unexpected argument '$1'" >&2
                    usage 3
                fi
                shift
                ;;
        esac
    done

    # Resolve status file path from positional args (only when --status-file not given)
    if [[ -z "$status_file" ]]; then
        if [[ -z "$project" || -z "$agent_id" ]]; then
            echo "Error: project and agent-id are required (or use --status-file)" >&2
            echo "Run with --help for usage." >&2
            exit 3
        fi
        # Validate before interpolating into a file path (prevent path traversal)
        _validate_id "project" "$project"
        _validate_id "agent-id" "$agent_id"
        status_file="${KAPSIS_STATUS_DIR}/kapsis-${project}-${agent_id}.json"
    fi

    # Validate status file exists
    if [[ ! -f "$status_file" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            local escaped_path
            escaped_path=$(json_escape_string "$status_file")
            printf '{"error":"not_found","message":"Status file not found: %s"}\n' "$escaped_path"
        else
            echo "Error: Status file not found: $status_file" >&2
            echo "Run 'kapsis-status' to list available agents." >&2
        fi
        return 3
    fi

    # Cap read to 1 MiB — prevents multi-MB files from ballooning memory across
    # the several json_get_* regex passes that follow.
    local content
    content=$(head -c "$_MAX_STATUS_BYTES" "$status_file")

    # Parse all relevant fields from status.json
    local phase error_type exit_code commit_status push_fallback worktree_path branch
    phase=$(json_get_string "$content" "phase")
    error_type=$(json_get_string "$content" "error_type")
    exit_code=$(json_get_number "$content" "exit_code")
    commit_status=$(json_get_string "$content" "commit_status")
    push_fallback=$(json_get_string "$content" "push_fallback_command")
    worktree_path=$(json_get_string "$content" "worktree_path")
    branch=$(json_get_string "$content" "branch")

    # Sanitise exit_code: json_get_number returns "" when the field is absent.
    # An empty or non-numeric value in the JSON output produces invalid JSON.
    if [[ ! "$exit_code" =~ ^-?[0-9]+$ && "$exit_code" != "null" ]]; then
        exit_code="null"
    fi

    # Only give recovery guidance for completed agents
    if [[ "$phase" != "complete" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            local escaped_phase
            escaped_phase=$(json_escape_string "$phase")
            printf '{"error":"still_running","phase":"%s","message":"Agent has not completed — no recovery action needed"}\n' \
                "$escaped_phase"
        else
            echo "Agent has not completed (phase: ${phase:-unknown}). No recovery action needed." >&2
        fi
        return 3
    fi

    # Success: no recovery needed
    if [[ "$exit_code" == "0" || "$exit_code" == "null" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo '{"action":"none","description":"Agent completed successfully","exit_code":0,"next_steps":[]}'
        else
            echo -e "${GREEN}Agent completed successfully. No recovery needed.${NC}"
        fi
        return 0
    fi

    # Resolve action and build next steps
    local action description
    action=$(_resolve_action "$error_type" "$commit_status")
    description=$(_describe_action "$action" "$error_type")

    local -a next_steps=()
    _build_next_steps "$error_type" "$action" "$worktree_path" "$push_fallback" "$branch"

    if [[ "$json_mode" == "true" ]]; then
        # Build JSON next_steps array
        local steps_json=""
        local first=true
        for step in "${next_steps[@]}"; do
            [[ "$first" == "true" ]] && first=false || steps_json="${steps_json},"
            steps_json="${steps_json}\"$(json_escape_string "$step")\""
        done

        # Nullable fields: emit JSON null when the parsed value is empty or
        # the literal string "null" (which json_get_string returns for JSON null).
        local worktree_json="null"
        [[ -n "$worktree_path" && "$worktree_path" != "null" ]] && \
            worktree_json="\"$(json_escape_string "$worktree_path")\""

        local push_fallback_json="null"
        [[ -n "$push_fallback" && "$push_fallback" != "null" ]] && \
            push_fallback_json="\"$(json_escape_string "$push_fallback")\""

        local branch_json="null"
        [[ -n "$branch" && "$branch" != "null" ]] && \
            branch_json="\"$(json_escape_string "$branch")\""

        # commit_status: same nullable pattern — keep type consistent across all fields
        local commit_status_json="null"
        [[ -n "$commit_status" && "$commit_status" != "null" ]] && \
            commit_status_json="\"$(json_escape_string "$commit_status")\""

        cat << EOF
{
  "action": "$(json_escape_string "$action")",
  "error_type": "$(json_escape_string "$error_type")",
  "description": "$(json_escape_string "$description")",
  "exit_code": ${exit_code},
  "commit_status": ${commit_status_json},
  "branch": ${branch_json},
  "worktree_path": ${worktree_json},
  "push_fallback_command": ${push_fallback_json},
  "next_steps": [${steps_json}]
}
EOF
    else
        # Human-readable output — use the basename of the status file as a
        # fallback identifier when --status-file is used without project/agent-id.
        echo ""
        local label="${project:+${project}/${agent_id}}"
        if [[ -z "$label" ]]; then
            label="$(basename "$status_file" .json)"
        fi
        echo -e "${CYAN}=== Recovery Action: ${label} ===${NC}"
        echo ""

        local action_color="$GREEN"
        [[ "$action" == "restart_and_retry" ]] && action_color="$YELLOW"
        [[ "$action" == "notify_human" ]] && action_color="$RED"

        echo -e "  Action:       ${action_color}${action}${NC}"
        echo "  Error Type:   ${error_type:-unknown}"
        echo "  Exit Code:    ${exit_code}"
        [[ -n "$branch" && "$branch" != "null" ]] && echo "  Branch:       ${branch}"
        echo ""
        echo "  ${description}"
        echo ""

        if [[ ${#next_steps[@]} -gt 0 ]]; then
            echo -e "${CYAN}--- Next Steps ---${NC}"
            echo ""
            local i=1
            for step in "${next_steps[@]}"; do
                echo "  ${i}. ${step}"
                ((i++)) || true
            done
            echo ""
        fi
    fi

    # Exit code encodes the action class for caller branching
    case "$action" in
        retry|retry_push)
            return 0
            ;;
        restart_and_retry)
            return 2
            ;;
        *)
            # notify_human
            return 1
            ;;
    esac
}

main "$@"
