#!/usr/bin/env bash
#===============================================================================
# Kapsis Status - Query Agent Status
#
# Query and monitor the status of running Kapsis agents.
#
# Usage:
#   kapsis-status                      # List all agent statuses
#   kapsis-status <project> <agent-id> # Get specific agent status
#   kapsis-status --watch              # Watch all agents (live updates)
#   kapsis-status --json               # Raw JSON output
#   kapsis-status --cleanup            # Clean up old completed status files
#
# Examples:
#   kapsis-status
#   kapsis-status products 1
#   kapsis-status --watch
#   kapsis-status --json | jq '.[] | select(.phase != "complete")'
#===============================================================================

set -euo pipefail

# Script directory
KAPSIS_STATUS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source JSON utilities
source "$KAPSIS_STATUS_SCRIPT_DIR/lib/json-utils.sh"

KAPSIS_STATUS_DIR="${KAPSIS_STATUS_DIR:-$HOME/.kapsis/status}"

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

#===============================================================================
# HELP
#===============================================================================
usage() {
    local cmd_name="${KAPSIS_CMD_NAME:-$(basename "$0")}"
    cat << EOF
Usage: $cmd_name [options] [project] [agent-id]

Query and monitor Kapsis agent status.

Options:
  -h, --help      Show this help message
  -w, --watch     Watch mode - continuously update display
  -j, --json      Output raw JSON (for all agents or specific agent)
  -c, --cleanup   Clean up completed status files older than 24 hours

Arguments:
  project         Project name (optional)
  agent-id        Agent ID (optional, requires project)

Examples:
  $cmd_name                    # List all agents
  $cmd_name products 1         # Show specific agent
  $cmd_name --watch            # Live monitoring
  $cmd_name --json             # JSON output for scripting
  $cmd_name --cleanup          # Remove old status files

Status Files Location: $KAPSIS_STATUS_DIR
EOF
    exit 0
}

#===============================================================================
# JSON ALIASES (for convenience - uses lib/json-utils.sh)
#===============================================================================
# Alias for json_get_string from json-utils.sh
json_get() { json_get_string "$@"; }

# Alias for json_get_number from json-utils.sh
json_get_num() { json_get_number "$@"; }

#===============================================================================
# LIST ALL AGENTS
#===============================================================================
list_all() {
    local json_mode="${1:-false}"

    if [[ ! -d "$KAPSIS_STATUS_DIR" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "[]"
        else
            echo "No status directory found at $KAPSIS_STATUS_DIR"
            echo "Status files are created when agents are launched."
        fi
        return 0
    fi

    local files=("$KAPSIS_STATUS_DIR"/kapsis-*.json)
    if [[ ! -f "${files[0]}" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "[]"
        else
            echo "No agent status files found."
        fi
        return 0
    fi

    if [[ "$json_mode" == "true" ]]; then
        # Output JSON array
        echo "["
        local first=true
        for file in "${files[@]}"; do
            [[ -f "$file" ]] || continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            cat "$file"
        done
        echo "]"
    else
        # Pretty table output
        printf "${CYAN}%-15s %-8s %-12s %5s %-30s${NC}\n" "PROJECT" "AGENT" "PHASE" "PROG" "MESSAGE"
        printf "%-15s %-8s %-12s %5s %-30s\n" "-------" "-----" "-----" "----" "-------"

        for file in "${files[@]}"; do
            [[ -f "$file" ]] || continue
            local content
            content=$(cat "$file")

            local project agent phase progress message
            project=$(json_get "$content" "project")
            agent=$(json_get "$content" "agent_id")
            phase=$(json_get "$content" "phase")
            progress=$(json_get_num "$content" "progress")
            message=$(json_get "$content" "message")

            # Color based on phase
            local color="$NC"
            case "$phase" in
                complete) color="$GREEN" ;;
                running) color="$CYAN" ;;
                committing|pushing) color="$YELLOW" ;;
                *) color="$NC" ;;
            esac

            # Check for errors
            local exit_code
            exit_code=$(json_get_num "$content" "exit_code")
            if [[ -n "$exit_code" && "$exit_code" != "null" && "$exit_code" != "0" ]]; then
                color="$RED"
            fi

            # Truncate message if too long
            message="${message:0:30}"

            printf "${color}%-15s %-8s %-12s %4s%% %-30s${NC}\n" \
                "${project:0:15}" "${agent:0:8}" "$phase" "$progress" "$message"
        done
    fi
}

#===============================================================================
# GET SPECIFIC AGENT STATUS
#===============================================================================
get_status() {
    local project="$1"
    local agent="$2"
    local json_mode="${3:-false}"

    local file="$KAPSIS_STATUS_DIR/kapsis-${project}-${agent}.json"

    if [[ ! -f "$file" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo '{"error": "not_found", "message": "No status found for '"$project"' agent '"$agent"'"}'
        else
            echo "No status found for project '$project' agent '$agent'"
            echo "File not found: $file"
        fi
        return 1
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat "$file"
    else
        local content
        content=$(cat "$file")

        # Parse all fields
        local project_name agent_id branch sandbox_mode phase progress message
        local started_at updated_at exit_code error worktree_path pr_url

        project_name=$(json_get "$content" "project")
        agent_id=$(json_get "$content" "agent_id")
        branch=$(json_get "$content" "branch")
        sandbox_mode=$(json_get "$content" "sandbox_mode")
        phase=$(json_get "$content" "phase")
        progress=$(json_get_num "$content" "progress")
        message=$(json_get "$content" "message")
        started_at=$(json_get "$content" "started_at")
        updated_at=$(json_get "$content" "updated_at")
        exit_code=$(json_get_num "$content" "exit_code")
        error=$(json_get "$content" "error")
        worktree_path=$(json_get "$content" "worktree_path")
        pr_url=$(json_get "$content" "pr_url")

        # Pretty output
        echo ""
        echo -e "${CYAN}=== Agent Status ===${NC}"
        echo ""
        echo "  Project:      $project_name"
        echo "  Agent ID:     $agent_id"
        [[ -n "$branch" && "$branch" != "null" ]] && echo "  Branch:       $branch"
        echo "  Sandbox Mode: $sandbox_mode"
        echo ""
        echo -e "${CYAN}--- Progress ---${NC}"
        echo ""
        echo "  Phase:        $phase"
        echo "  Progress:     ${progress}%"
        echo "  Message:      $message"
        echo ""
        echo -e "${CYAN}--- Timing ---${NC}"
        echo ""
        echo "  Started:      $started_at"
        echo "  Updated:      $updated_at"
        echo ""

        if [[ -n "$exit_code" && "$exit_code" != "null" ]]; then
            echo -e "${CYAN}--- Result ---${NC}"
            echo ""
            if [[ "$exit_code" == "0" ]]; then
                echo -e "  Exit Code:    ${GREEN}$exit_code (success)${NC}"
            else
                echo -e "  Exit Code:    ${RED}$exit_code (failed)${NC}"
            fi
            [[ -n "$error" && "$error" != "null" ]] && echo -e "  Error:        ${RED}$error${NC}"
            [[ -n "$pr_url" && "$pr_url" != "null" ]] && echo "  PR URL:       $pr_url"
            echo ""
        fi

        [[ -n "$worktree_path" && "$worktree_path" != "null" ]] && echo "  Worktree:     $worktree_path"
        echo ""
    fi
}

#===============================================================================
# WATCH MODE
#===============================================================================
watch_all() {
    local interval="${1:-2}"

    echo "Watching agent status (Ctrl+C to stop)..."
    echo ""

    while true; do
        clear
        echo -e "${CYAN}=== Kapsis Agent Status ($(date '+%Y-%m-%d %H:%M:%S')) ===${NC}"
        echo ""
        list_all false
        echo ""
        echo -e "${CYAN}Refreshing every ${interval}s... (Ctrl+C to stop)${NC}"
        sleep "$interval"
    done
}

#===============================================================================
# CLEANUP OLD STATUS FILES
#===============================================================================
cleanup_old() {
    if [[ ! -d "$KAPSIS_STATUS_DIR" ]]; then
        echo "No status directory found."
        return 0
    fi

    echo "Cleaning up completed status files older than 24 hours..."

    local count=0
    while IFS= read -r -d '' file; do
        # Check if completed
        if grep -q '"phase": *"complete"' "$file" 2>/dev/null; then
            echo "  Removing: $(basename "$file")"
            rm -f "$file"
            ((count++)) || true
        fi
    done < <(find "$KAPSIS_STATUS_DIR" -name "kapsis-*.json" -mtime +1 -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        echo "No old completed status files to clean up."
    else
        echo "Cleaned up $count status file(s)."
    fi
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    local json_mode=false
    local watch_mode=false
    local cleanup_mode=false
    local project=""
    local agent=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -j|--json)
                json_mode=true
                shift
                ;;
            -w|--watch)
                watch_mode=true
                shift
                ;;
            -c|--cleanup)
                cleanup_mode=true
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$agent" ]]; then
                    agent="$1"
                else
                    echo "Too many arguments"
                    usage
                fi
                shift
                ;;
        esac
    done

    # Handle modes
    if [[ "$cleanup_mode" == "true" ]]; then
        cleanup_old
        return 0
    fi

    if [[ "$watch_mode" == "true" ]]; then
        watch_all 2
        return 0
    fi

    # Get specific agent or list all
    if [[ -n "$project" && -n "$agent" ]]; then
        get_status "$project" "$agent" "$json_mode"
    elif [[ -n "$project" ]]; then
        echo "Error: agent-id required when project is specified"
        echo "Usage: $(basename "$0") <project> <agent-id>"
        exit 1
    else
        list_all "$json_mode"
    fi
}

main "$@"
