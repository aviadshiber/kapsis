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
  -H, --health    Health diagnostics (requires project and agent-id)
  -c, --cleanup   Clean up completed status files older than 24 hours

Arguments:
  project         Project name (optional)
  agent-id        Agent ID (optional, requires project)

Examples:
  $cmd_name                    # List all agents
  $cmd_name products 1         # Show specific agent
  $cmd_name --watch            # Live monitoring
  $cmd_name --json             # JSON output for scripting
  $cmd_name --health products 1      # Health diagnostics
  $cmd_name --health --json products 1  # Health as JSON
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
        printf "${CYAN}%-15s %-8s %-12s %5s %-40s${NC}\n" "PROJECT" "AGENT" "PHASE" "PROG" "STATUS"
        printf "%-15s %-8s %-12s %5s %-40s\n" "-------" "-----" "-----" "----" "------"

        for file in "${files[@]}"; do
            [[ -f "$file" ]] || continue
            local content
            content=$(cat "$file")

            local project agent phase progress message gist
            project=$(json_get "$content" "project")
            agent=$(json_get "$content" "agent_id")
            phase=$(json_get "$content" "phase")
            progress=$(json_get_num "$content" "progress")
            message=$(json_get "$content" "message")
            gist=$(json_get "$content" "gist")

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

            # Prefer gist over message if available, otherwise use message
            local display_status
            if [[ -n "$gist" && "$gist" != "null" ]]; then
                display_status="${gist:0:40}"
            else
                display_status="${message:0:40}"
            fi

            printf "${color}%-15s %-8s %-12s %4s%% %-40s${NC}\n" \
                "${project:0:15}" "${agent:0:8}" "$phase" "$progress" "$display_status"
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
        local gist gist_updated_at

        project_name=$(json_get "$content" "project")
        agent_id=$(json_get "$content" "agent_id")
        branch=$(json_get "$content" "branch")
        sandbox_mode=$(json_get "$content" "sandbox_mode")
        phase=$(json_get "$content" "phase")
        progress=$(json_get_num "$content" "progress")
        message=$(json_get "$content" "message")
        gist=$(json_get "$content" "gist")
        gist_updated_at=$(json_get "$content" "gist_updated_at")
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
        if [[ -n "$gist" && "$gist" != "null" ]]; then
            echo ""
            echo -e "${CYAN}--- Agent Activity ---${NC}"
            echo ""
            echo "  $gist"
            [[ -n "$gist_updated_at" && "$gist_updated_at" != "null" ]] && echo "  (updated: $gist_updated_at)"
        fi
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
            elif [[ "$exit_code" == "4" ]]; then
                echo -e "  Exit Code:    ${RED}$exit_code (mount failure)${NC}"
            else
                echo -e "  Exit Code:    ${RED}$exit_code (failed)${NC}"
            fi
            [[ -n "$error" && "$error" != "null" ]] && echo -e "  Error:        ${RED}$error${NC}"
            [[ -n "$pr_url" && "$pr_url" != "null" ]] && echo "  PR URL:       $pr_url"
            echo ""

            # Mount failure recovery guidance (Issue #248)
            if [[ "$exit_code" == "4" ]]; then
                echo -e "${YELLOW}--- Mount Failure Recovery ---${NC}"
                echo ""
                echo "  The /workspace virtio-fs mount was lost during execution."
                echo "  To recover:"
                echo "    1. podman machine stop"
                echo "    2. podman machine start"
                echo "    3. Re-run the agent"
                echo ""
            fi
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
# HEALTH DIAGNOSTICS
#===============================================================================
show_health() {
    local project="$1"
    local agent="$2"
    local json_mode="${3:-false}"

    local file="$KAPSIS_STATUS_DIR/kapsis-${project}-${agent}.json"

    if [[ ! -f "$file" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            # Sanitize project/agent for safe JSON embedding (strip quotes)
            local safe_proj="${project//\"/}"
            local safe_agent="${agent//\"/}"
            echo "{\"error\": \"not_found\", \"message\": \"No status found for ${safe_proj} agent ${safe_agent}\"}"
        else
            echo "No status found for project '$project' agent '$agent'"
        fi
        return 1
    fi

    local content
    content=$(cat "$file")

    # Parse status fields
    local phase progress updated_at started_at heartbeat_at message gist
    phase=$(json_get "$content" "phase")
    progress=$(json_get_num "$content" "progress")
    updated_at=$(json_get "$content" "updated_at")
    started_at=$(json_get "$content" "started_at")
    heartbeat_at=$(json_get "$content" "heartbeat_at")
    message=$(json_get "$content" "message")
    gist=$(json_get "$content" "gist")

    # Calculate staleness
    local now hook_stale_secs heartbeat_stale_secs uptime_secs
    now=$(date -u +%s)

    hook_stale_secs="null"
    if [[ -n "$updated_at" && "$updated_at" != "null" ]]; then
        local updated_epoch
        updated_epoch=$(_health_ts_to_epoch "$updated_at")
        if [[ "$updated_epoch" -gt 0 ]]; then
            hook_stale_secs=$((now - updated_epoch))
        fi
    fi

    heartbeat_stale_secs="null"
    if [[ -n "$heartbeat_at" && "$heartbeat_at" != "null" ]]; then
        local hb_epoch
        hb_epoch=$(_health_ts_to_epoch "$heartbeat_at")
        if [[ "$hb_epoch" -gt 0 ]]; then
            heartbeat_stale_secs=$((now - hb_epoch))
        fi
    fi

    uptime_secs=0
    if [[ -n "$started_at" && "$started_at" != "null" ]]; then
        local started_epoch
        started_epoch=$(_health_ts_to_epoch "$started_at")
        if [[ "$started_epoch" -gt 0 ]]; then
            uptime_secs=$((now - started_epoch))
        fi
    fi

    # Container diagnostics (requires running container)
    local process_state="unknown" io_read=0 io_write=0 tcp_established=0
    local memory_mib="null" cpu_percent="null"
    local container_id=""

    # Find container by label
    if command -v podman &>/dev/null; then
        container_id=$(podman ps --filter "label=kapsis.agent-id=${agent}" --format "{{.ID}}" 2>/dev/null | head -1)
    fi

    if [[ -n "$container_id" ]]; then
        # Process state
        local proc_status
        proc_status=$(podman exec "$container_id" cat /proc/1/status 2>/dev/null || echo "")
        if [[ -n "$proc_status" ]]; then
            process_state=$(echo "$proc_status" | awk '/^State:/ {print $2, $3}')
        fi

        # I/O stats
        local proc_io
        proc_io=$(podman exec "$container_id" cat /proc/1/io 2>/dev/null || echo "")
        if [[ -n "$proc_io" ]]; then
            io_read=$(echo "$proc_io" | awk '/^read_bytes:/ {print $2}')
            io_write=$(echo "$proc_io" | awk '/^write_bytes:/ {print $2}')
        fi

        # TCP connections (count ESTABLISHED = state 01 in /proc/net/tcp)
        tcp_established=$(podman exec "$container_id" sh -c 'cat /proc/net/tcp 2>/dev/null | awk "NR>1 && \$4==\"01\" {c++} END {print c+0}"' 2>/dev/null || echo "0")

        # Memory and CPU from podman stats
        local stats_json
        stats_json=$(podman stats --no-stream --format json "$container_id" 2>/dev/null || echo "[]")
        if [[ "$stats_json" != "[]" && "$stats_json" != "" ]]; then
            memory_mib=$(echo "$stats_json" | python3 -c "
import json, sys, re
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        mem = data[0].get('mem_usage', data[0].get('MemUsage', '0'))
        # Parse '245.3MiB / 8GiB' format
        match = re.match(r'([\d.]+)\s*([KMG]i?B)', str(mem))
        if match:
            val, unit = float(match.group(1)), match.group(2)
            if 'G' in unit: val *= 1024
            elif 'K' in unit: val /= 1024
            print(int(val))
        else: print('null')
    else: print('null')
except: print('null')
" 2>/dev/null || echo "null")
            cpu_percent=$(echo "$stats_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        cpu = data[0].get('cpu_percent', data[0].get('CPUPerc', '0'))
        print(str(cpu).rstrip('%'))
    else: print('null')
except: print('null')
" 2>/dev/null || echo "null")
        fi
    fi

    # Determine health status
    local health="HEALTHY"
    local health_exit_code
    health_exit_code=$(json_get_num "$content" "exit_code")
    if [[ "$health_exit_code" == "4" ]]; then
        health="MOUNT_FAILURE"
    elif [[ "$phase" == "complete" || "$phase" == "killed" ]]; then
        health="STOPPED"
    elif [[ "$hook_stale_secs" != "null" && "$hook_stale_secs" -ge 1800 ]]; then
        health="CRITICAL"
    elif [[ "$hook_stale_secs" != "null" && "$hook_stale_secs" -ge 300 ]]; then
        health="WARNING"
    fi

    if [[ "$json_mode" == "true" ]]; then
        # JSON output
        cat << HEALTHJSON
{
  "agent_id": "$agent",
  "project": "$project",
  "process_state": "$process_state",
  "uptime_seconds": $uptime_secs,
  "last_hook_fire": $(if [[ "$updated_at" != "null" && -n "$updated_at" ]]; then echo "\"$updated_at\""; else echo "null"; fi),
  "last_heartbeat": $(if [[ "$heartbeat_at" != "null" && -n "$heartbeat_at" ]]; then echo "\"$heartbeat_at\""; else echo "null"; fi),
  "hook_staleness_seconds": $hook_stale_secs,
  "heartbeat_staleness_seconds": $heartbeat_stale_secs,
  "phase": "$phase",
  "progress": ${progress:-0},
  "io": {"read_bytes": ${io_read:-0}, "write_bytes": ${io_write:-0}},
  "tcp_established": ${tcp_established:-0},
  "memory_mib": $memory_mib,
  "cpu_percent": $cpu_percent,
  "health": "$(echo "$health" | tr '[:upper:]' '[:lower:]')"
}
HEALTHJSON
    else
        # Pretty output
        local health_color="$GREEN"
        case "$health" in
            CRITICAL|MOUNT_FAILURE) health_color="$RED" ;;
            WARNING) health_color="$YELLOW" ;;
            STOPPED) health_color="$NC" ;;
        esac

        echo ""
        echo -e "${CYAN}=== Agent Health: ${project}/${agent} ===${NC}"
        echo ""
        echo "  Process:        $process_state"
        echo "  Uptime:         $(_health_format_duration "$uptime_secs")"
        echo ""

        # Hook staleness with color
        if [[ "$updated_at" != "null" && -n "$updated_at" ]]; then
            local hook_color="$GREEN"
            if [[ "$hook_stale_secs" != "null" ]]; then
                [[ "$hook_stale_secs" -ge 1800 ]] && hook_color="$RED"
                [[ "$hook_stale_secs" -ge 300 && "$hook_stale_secs" -lt 1800 ]] && hook_color="$YELLOW"
                echo -e "  Last Hook Fire: ${hook_color}${updated_at} ($(_health_format_duration "$hook_stale_secs") ago)${NC}"
            else
                echo "  Last Hook Fire: $updated_at"
            fi
        else
            echo "  Last Hook Fire: (none)"
        fi

        if [[ "$heartbeat_at" != "null" && -n "$heartbeat_at" ]]; then
            echo "  Last Heartbeat: ${heartbeat_at} ($(_health_format_duration "$heartbeat_stale_secs") ago)"
        else
            echo "  Last Heartbeat: (none — liveness monitor not active)"
        fi

        echo "  Status Phase:   $phase (${progress:-0}%)"
        if [[ -n "$gist" && "$gist" != "null" ]]; then
            echo "  Activity:       ${gist:0:60}"
        fi
        echo ""

        if [[ -n "$container_id" ]]; then
            echo -e "${CYAN}--- Container Diagnostics ---${NC}"
            echo ""
            echo "  I/O Activity:"
            echo "    read_bytes:   ${io_read:-0}"
            echo "    write_bytes:  ${io_write:-0}"
            echo "  TCP Established: ${tcp_established:-0}"
            if [[ "$memory_mib" != "null" ]]; then
                echo "  Memory:         ${memory_mib} MiB"
            fi
            if [[ "$cpu_percent" != "null" ]]; then
                echo "  CPU:            ${cpu_percent}%"
            fi
            echo ""
        else
            echo "  (Container not running — diagnostics unavailable)"
            echo ""
        fi

        echo -e "  Health:         ${health_color}${health}${NC}"
        echo ""
    fi
}

# Convert ISO 8601 timestamp to epoch seconds
_health_ts_to_epoch() {
    local ts="$1"
    ts="${ts%Z}"
    ts="${ts/T/ }"
    date -u -d "$ts" +%s 2>/dev/null || \
        date -u -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || \
        echo "0"
}

# Format seconds as human-readable duration
_health_format_duration() {
    local secs="$1"
    [[ "$secs" == "null" || -z "$secs" ]] && echo "unknown" && return
    if [[ "$secs" -ge 3600 ]]; then
        echo "$((secs / 3600))h $((secs % 3600 / 60))m"
    elif [[ "$secs" -ge 60 ]]; then
        echo "$((secs / 60))m $((secs % 60))s"
    else
        echo "${secs}s"
    fi
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
    local health_mode=false
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
            -H|--health)
                health_mode=true
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
    if [[ "$health_mode" == "true" ]]; then
        if [[ -z "$project" || -z "$agent" ]]; then
            echo "Error: --health requires project and agent-id"
            echo "Usage: $(basename "$0") --health <project> <agent-id>"
            exit 1
        fi
        show_health "$project" "$agent" "$json_mode"
        return 0
    fi

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
