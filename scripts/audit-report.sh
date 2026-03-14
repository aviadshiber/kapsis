#!/usr/bin/env bash
#===============================================================================
# Kapsis Audit Report - Generate structured reports from audit JSONL files
#
# Reads audit trail JSONL files produced by the Kapsis audit system and
# generates human-readable or machine-parseable reports covering session
# summary, security alerts, event statistics, credential access, and
# filesystem impact.
#
# Usage:
#   audit-report.sh <audit-file>
#   audit-report.sh --agent-id <id>
#   audit-report.sh --latest
#
# Options:
#   --format text|json     Output format (default: text)
#   --verify               Verify hash chain integrity
#   --summary              Brief summary only
#   --alerts-only          Show only triggered alerts
#   -h, --help             Show usage
#
# Examples:
#   audit-report.sh ~/.kapsis/audit/abc123-20250101-120000-1234.audit.jsonl
#   audit-report.sh --agent-id abc123
#   audit-report.sh --latest --format json
#   audit-report.sh --latest --verify
#   audit-report.sh --latest --alerts-only
#   audit-report.sh --latest --summary
#===============================================================================

set -euo pipefail

# Script directory for sourcing libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/json-utils.sh"
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/audit.sh"

# Suppress console logging — this script outputs directly to stdout
export KAPSIS_LOG_CONSOLE=false

# Audit directory
KAPSIS_AUDIT_DIR="${KAPSIS_AUDIT_DIR:-$HOME/.kapsis/audit}"

# Colors for text output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Detect if stdout supports colors
_use_colors=true
if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
    _use_colors=false
    CYAN=""
    GREEN=""
    YELLOW=""
    RED=""
    BOLD=""
    NC=""
fi

#===============================================================================
# HELP
#===============================================================================
usage() {
    local cmd_name="${KAPSIS_CMD_NAME:-$(basename "$0")}"
    cat <<EOF
Usage: $cmd_name <audit-file>
       $cmd_name --agent-id <id>
       $cmd_name --latest

Generate structured reports from Kapsis audit trail JSONL files.

Options:
  --format text|json     Output format (default: text)
  --verify               Verify hash chain integrity
  --summary              Brief summary only
  --alerts-only          Show only triggered alerts
  -h, --help             Show usage

Finding audit files:
  <audit-file>           Direct path to .audit.jsonl file
  --agent-id <id>        Find latest file matching \${id}-*.audit.jsonl
  --latest               Find the most recently modified .audit.jsonl

Audit directory: ${KAPSIS_AUDIT_DIR}

Examples:
  $cmd_name ~/.kapsis/audit/abc-20250101-120000-1234.audit.jsonl
  $cmd_name --agent-id abc123
  $cmd_name --latest --format json
  $cmd_name --latest --verify
  $cmd_name --latest --alerts-only
  $cmd_name --latest --summary
EOF
    exit 0
}

#===============================================================================
# AUDIT FILE RESOLUTION
#===============================================================================

# Find audit file by agent ID (latest matching file)
# Arguments: $1 - agent ID
# Outputs: path to the latest matching audit file
find_by_agent_id() {
    local agent_id="$1"

    if [[ ! -d "$KAPSIS_AUDIT_DIR" ]]; then
        log_error "Audit directory not found: $KAPSIS_AUDIT_DIR"
        return 1
    fi

    local latest_file=""
    local latest_mtime=0

    for f in "$KAPSIS_AUDIT_DIR"/"${agent_id}"-*.audit.jsonl; do
        [[ -f "$f" ]] || continue
        local mtime
        mtime=$(get_file_mtime "$f")
        [[ -z "$mtime" ]] && continue
        if [[ "$mtime" -gt "$latest_mtime" ]]; then
            latest_mtime="$mtime"
            latest_file="$f"
        fi
    done

    if [[ -z "$latest_file" ]]; then
        log_error "No audit file found for agent: $agent_id"
        return 1
    fi

    echo "$latest_file"
}

# Find the most recently modified audit file
# Outputs: path to the latest audit file
find_latest() {
    if [[ ! -d "$KAPSIS_AUDIT_DIR" ]]; then
        log_error "Audit directory not found: $KAPSIS_AUDIT_DIR"
        return 1
    fi

    local latest_file=""
    local latest_mtime=0

    for f in "$KAPSIS_AUDIT_DIR"/*.audit.jsonl; do
        [[ -f "$f" ]] || continue
        local mtime
        mtime=$(get_file_mtime "$f")
        [[ -z "$mtime" ]] && continue
        if [[ "$mtime" -gt "$latest_mtime" ]]; then
            latest_mtime="$mtime"
            latest_file="$f"
        fi
    done

    if [[ -z "$latest_file" ]]; then
        log_error "No audit files found in $KAPSIS_AUDIT_DIR"
        return 1
    fi

    echo "$latest_file"
}

#===============================================================================
# DATA EXTRACTION
#===============================================================================

# Parse all events from an audit JSONL file into structured data.
# Populates global arrays used by report sections.
#
# Global arrays populated:
#   _event_types[]        - event_type for each event
#   _tool_names[]         - tool_name for each event
#   _timestamps[]         - timestamp for each event
#   _lines[]              - raw JSONL lines
#
# Global scalars populated:
#   _agent_id, _project, _agent_type, _session_id
#   _total_events, _first_timestamp, _last_timestamp
parse_audit_file() {
    local audit_file="$1"

    # Arrays for event data
    _event_types=()
    _tool_names=()
    _timestamps=()
    _lines=()

    # Scalars
    _agent_id=""
    _project=""
    _agent_type=""
    _session_id=""
    _total_events=0
    _first_timestamp=""
    _last_timestamp=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local event_type
        event_type=$(json_get_string "$line" "event_type")
        local tool_name
        tool_name=$(json_get_string "$line" "tool_name")
        local timestamp
        timestamp=$(json_get_string "$line" "timestamp")

        _event_types+=("$event_type")
        _tool_names+=("$tool_name")
        _timestamps+=("$timestamp")
        _lines+=("$line")
        ((_total_events++)) || true

        # Capture metadata from first event
        if [[ -z "$_agent_id" ]]; then
            _agent_id=$(json_get_string "$line" "agent_id")
            _project=$(json_get_string "$line" "project")
            _agent_type=$(json_get_string "$line" "agent_type")
            _session_id=$(json_get_string "$line" "session_id")
        fi

        # Track timestamps
        if [[ -z "$_first_timestamp" ]]; then
            _first_timestamp="$timestamp"
        fi
        _last_timestamp="$timestamp"
    done < "$audit_file"
}

# Calculate duration between two ISO timestamps.
# Arguments: $1 - start timestamp, $2 - end timestamp
# Outputs: human-readable duration string
calculate_duration() {
    local start="$1"
    local end="$2"

    if [[ -z "$start" || -z "$end" ]]; then
        echo "unknown"
        return
    fi

    # Convert ISO timestamps to epoch seconds
    local start_epoch end_epoch
    if is_macos; then
        start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start" "+%s" 2>/dev/null) || { echo "unknown"; return; }
        end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end" "+%s" 2>/dev/null) || { echo "unknown"; return; }
    else
        start_epoch=$(date -d "$start" "+%s" 2>/dev/null) || { echo "unknown"; return; }
        end_epoch=$(date -d "$end" "+%s" 2>/dev/null) || { echo "unknown"; return; }
    fi

    local diff=$((end_epoch - start_epoch))
    if [[ "$diff" -lt 0 ]]; then
        diff=$(( -diff ))
    fi

    local hours=$((diff / 3600))
    local minutes=$(( (diff % 3600) / 60 ))
    local seconds=$((diff % 60))

    if [[ "$hours" -gt 0 ]]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
    elif [[ "$minutes" -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

# Count occurrences of a value in an array, output sorted by frequency.
# Arguments: array values via stdin (one per line)
# Outputs: "count value" lines, sorted descending by count
count_and_sort() {
    sort | uniq -c | sort -rn
}

#===============================================================================
# TEXT REPORT SECTIONS
#===============================================================================

# Section 1: Session Summary
report_session_summary_text() {
    local audit_file="$1"
    local duration
    duration=$(calculate_duration "$_first_timestamp" "$_last_timestamp")

    echo -e "${BOLD}${CYAN}=== Session Summary ===${NC}"
    echo ""
    echo "  Agent ID:       $_agent_id"
    echo "  Project:        $_project"
    echo "  Agent Type:     $_agent_type"
    echo "  Session ID:     $_session_id"
    echo "  Audit File:     $(basename "$audit_file")"
    echo "  Duration:       $duration"
    echo "  Start:          $_first_timestamp"
    echo "  End:            $_last_timestamp"
    echo "  Total Events:   $_total_events"
    echo ""

    # Events by type breakdown
    echo -e "  ${BOLD}Events by Type:${NC}"
    local type_counts
    type_counts=$(printf '%s\n' "${_event_types[@]}" | count_and_sort)
    while IFS= read -r count_line; do
        [[ -z "$count_line" ]] && continue
        local count type
        read -r count type <<< "$count_line"
        printf "    %-25s %s\n" "$type" "$count"
    done <<< "$type_counts"
    echo ""
}

# Section 2: Hash Chain Verification (only with --verify)
report_chain_verification_text() {
    local audit_file="$1"

    echo -e "${BOLD}${CYAN}=== Hash Chain Verification ===${NC}"
    echo ""

    # Capture both stdout and stderr from audit_verify_chain
    local verify_output
    local verify_rc=0
    verify_output=$(audit_verify_chain "$audit_file" 2>&1) || verify_rc=$?

    if [[ "$verify_rc" -eq 0 ]]; then
        echo -e "  Result: ${GREEN}VALID${NC}"
        echo "  $verify_output"
    else
        echo -e "  Result: ${RED}BROKEN${NC}"
        # Show the error details
        while IFS= read -r err_line; do
            echo "  $err_line"
        done <<< "$verify_output"
    fi
    echo ""
}

# Section 3: Security Alerts
report_alerts_text() {
    local audit_file="$1"

    echo -e "${BOLD}${CYAN}=== Security Alerts ===${NC}"
    echo ""

    # Derive alerts file path from audit file
    local alerts_file
    alerts_file="${audit_file%.audit.jsonl}-alerts.jsonl"

    if [[ ! -f "$alerts_file" ]]; then
        echo "  No alerts file found."
        echo "  Expected: $(basename "$alerts_file")"
        echo ""
        return
    fi

    local alert_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((alert_count++)) || true

        local severity
        severity=$(json_get_string "$line" "severity")
        local description
        description=$(json_get_string "$line" "description")
        local pattern_name
        pattern_name=$(json_get_string "$line" "pattern_name")
        local timestamp
        timestamp=$(json_get_string "$line" "timestamp")

        # Color by severity
        local sev_color="$NC"
        case "$severity" in
            critical) sev_color="$RED" ;;
            high)     sev_color="$RED" ;;
            medium)   sev_color="$YELLOW" ;;
            low)      sev_color="$CYAN" ;;
        esac

        echo -e "  ${sev_color}[${severity^^}]${NC} ${pattern_name:-alert}"
        echo "    Time:        $timestamp"
        echo "    Description: $description"
        echo ""
    done < "$alerts_file"

    if [[ "$alert_count" -eq 0 ]]; then
        echo -e "  ${GREEN}No alerts triggered.${NC}"
        echo ""
    else
        echo "  Total alerts: $alert_count"
        echo ""
    fi
}

# Section 4: Event Statistics
report_statistics_text() {
    echo -e "${BOLD}${CYAN}=== Event Statistics ===${NC}"
    echo ""

    # Top 10 commands by frequency
    echo -e "  ${BOLD}Top 10 Commands:${NC}"
    local cmd_lines=""
    local i
    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "shell_command" ]]; then
            local command
            command=$(json_get_string "${_lines[$i]}" "command")
            if [[ -n "$command" ]]; then
                cmd_lines+="${command}"$'\n'
            fi
        fi
    done

    if [[ -n "$cmd_lines" ]]; then
        local sorted_cmds
        sorted_cmds=$(printf '%s' "$cmd_lines" | count_and_sort | head -10)
        while IFS= read -r count_line; do
            [[ -z "$count_line" ]] && continue
            local count cmd
            # Read just the count, rest is the command
            count=$(echo "$count_line" | awk '{print $1}')
            cmd=$(echo "$count_line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
            printf "    %4s  %s\n" "$count" "${cmd:0:70}"
        done <<< "$sorted_cmds"
    else
        echo "    (no shell commands recorded)"
    fi
    echo ""

    # Most accessed files (top 10)
    echo -e "  ${BOLD}Most Accessed Files (Top 10):${NC}"
    local file_lines=""
    for i in "${!_lines[@]}"; do
        local file_path
        file_path=$(json_get_string "${_lines[$i]}" "file_path")
        if [[ -n "$file_path" ]]; then
            file_lines+="${file_path}"$'\n'
        fi
    done

    if [[ -n "$file_lines" ]]; then
        local sorted_files
        sorted_files=$(printf '%s' "$file_lines" | count_and_sort | head -10)
        while IFS= read -r count_line; do
            [[ -z "$count_line" ]] && continue
            local count fpath
            count=$(echo "$count_line" | awk '{print $1}')
            fpath=$(echo "$count_line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
            printf "    %4s  %s\n" "$count" "${fpath:0:70}"
        done <<< "$sorted_files"
    else
        echo "    (no file access recorded)"
    fi
    echo ""

    # Tool usage distribution
    echo -e "  ${BOLD}Tool Usage Distribution:${NC}"
    local tool_counts
    tool_counts=$(printf '%s\n' "${_tool_names[@]}" | count_and_sort)
    while IFS= read -r count_line; do
        [[ -z "$count_line" ]] && continue
        local count tool
        read -r count tool <<< "$count_line"
        printf "    %-25s %s\n" "$tool" "$count"
    done <<< "$tool_counts"
    echo ""

    # Event type distribution
    echo -e "  ${BOLD}Event Type Distribution:${NC}"
    local type_counts
    type_counts=$(printf '%s\n' "${_event_types[@]}" | count_and_sort)
    while IFS= read -r count_line; do
        [[ -z "$count_line" ]] && continue
        local count etype
        read -r count etype <<< "$count_line"
        printf "    %-25s %s\n" "$etype" "$count"
    done <<< "$type_counts"
    echo ""
}

# Section 5: Credential Access Log
report_credential_access_text() {
    echo -e "${BOLD}${CYAN}=== Credential Access Log ===${NC}"
    echo ""

    local cred_count=0
    local i
    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "credential_access" ]]; then
            ((cred_count++)) || true
            local timestamp="${_timestamps[$i]}"
            local tool="${_tool_names[$i]}"
            local command
            command=$(json_get_string "${_lines[$i]}" "command")

            printf "  [%s] tool=%-15s" "$timestamp" "$tool"
            if [[ -n "$command" ]]; then
                printf " cmd=%s" "${command:0:50}"
            fi
            echo ""
        fi
    done

    if [[ "$cred_count" -eq 0 ]]; then
        echo -e "  ${GREEN}No credential access events.${NC}"
    else
        echo ""
        echo "  Total credential access events: $cred_count"
    fi
    echo ""
}

# Section 6: Filesystem Impact
report_filesystem_impact_text() {
    echo -e "${BOLD}${CYAN}=== Filesystem Impact ===${NC}"
    echo ""

    local fs_count=0
    local -a unique_paths=()
    local i

    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "filesystem_op" ]]; then
            ((fs_count++)) || true
            local file_path
            file_path=$(json_get_string "${_lines[$i]}" "file_path")
            if [[ -n "$file_path" ]]; then
                # Track unique paths
                local already_seen=false
                local p
                for p in "${unique_paths[@]+"${unique_paths[@]}"}"; do
                    if [[ "$p" == "$file_path" ]]; then
                        already_seen=true
                        break
                    fi
                done
                if [[ "$already_seen" != "true" ]]; then
                    unique_paths+=("$file_path")
                fi
            fi
        fi
    done

    echo "  Filesystem operation events: $fs_count"
    echo "  Unique files modified:       ${#unique_paths[@]}"

    if [[ "${#unique_paths[@]}" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Modified Files:${NC}"
        local p
        for p in "${unique_paths[@]}"; do
            echo "    $p"
        done
    fi
    echo ""
}

#===============================================================================
# JSON REPORT
#===============================================================================

# Generate the full report as a JSON object
report_json() {
    local audit_file="$1"
    local do_verify="$2"

    local duration
    duration=$(calculate_duration "$_first_timestamp" "$_last_timestamp")

    # Build type counts JSON
    local type_counts_json="{"
    local type_first=true
    local type_counts
    type_counts=$(printf '%s\n' "${_event_types[@]}" | count_and_sort)
    while IFS= read -r count_line; do
        [[ -z "$count_line" ]] && continue
        local count etype
        read -r count etype <<< "$count_line"
        if [[ "$type_first" == "true" ]]; then
            type_first=false
        else
            type_counts_json+=","
        fi
        type_counts_json+="\"$(json_escape_string "$etype")\":${count}"
    done <<< "$type_counts"
    type_counts_json+="}"

    # Build summary JSON
    local summary_json
    summary_json="{\"agent_id\":\"$(json_escape_string "$_agent_id")\",\"project\":\"$(json_escape_string "$_project")\",\"agent_type\":\"$(json_escape_string "$_agent_type")\",\"session_id\":\"$(json_escape_string "$_session_id")\",\"duration\":\"$(json_escape_string "$duration")\",\"start\":\"$(json_escape_string "$_first_timestamp")\",\"end\":\"$(json_escape_string "$_last_timestamp")\",\"total_events\":${_total_events},\"events_by_type\":${type_counts_json}}"

    # Build alerts JSON array
    local alerts_json="[]"
    local alerts_file
    alerts_file="${audit_file%.audit.jsonl}-alerts.jsonl"
    if [[ -f "$alerts_file" ]]; then
        alerts_json="["
        local alert_first=true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$alert_first" == "true" ]]; then
                alert_first=false
            else
                alerts_json+=","
            fi
            alerts_json+="$line"
        done < "$alerts_file"
        alerts_json+="]"
    fi

    # Build statistics JSON
    # Tool usage counts
    local tool_counts_json="{"
    local tool_first=true
    local tool_counts
    tool_counts=$(printf '%s\n' "${_tool_names[@]}" | count_and_sort)
    while IFS= read -r count_line; do
        [[ -z "$count_line" ]] && continue
        local count tool
        read -r count tool <<< "$count_line"
        if [[ "$tool_first" == "true" ]]; then
            tool_first=false
        else
            tool_counts_json+=","
        fi
        tool_counts_json+="\"$(json_escape_string "$tool")\":${count}"
    done <<< "$tool_counts"
    tool_counts_json+="}"

    # Top commands
    local top_cmds_json="["
    local cmd_lines=""
    local i
    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "shell_command" ]]; then
            local command
            command=$(json_get_string "${_lines[$i]}" "command")
            if [[ -n "$command" ]]; then
                cmd_lines+="${command}"$'\n'
            fi
        fi
    done
    if [[ -n "$cmd_lines" ]]; then
        local cmd_first=true
        local sorted_cmds
        sorted_cmds=$(printf '%s' "$cmd_lines" | count_and_sort | head -10)
        while IFS= read -r count_line; do
            [[ -z "$count_line" ]] && continue
            local count cmd
            count=$(echo "$count_line" | awk '{print $1}')
            cmd=$(echo "$count_line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
            if [[ "$cmd_first" == "true" ]]; then
                cmd_first=false
            else
                top_cmds_json+=","
            fi
            top_cmds_json+="{\"command\":\"$(json_escape_string "$cmd")\",\"count\":${count}}"
        done <<< "$sorted_cmds"
    fi
    top_cmds_json+="]"

    # Top files
    local top_files_json="["
    local file_lines=""
    for i in "${!_lines[@]}"; do
        local file_path
        file_path=$(json_get_string "${_lines[$i]}" "file_path")
        if [[ -n "$file_path" ]]; then
            file_lines+="${file_path}"$'\n'
        fi
    done
    if [[ -n "$file_lines" ]]; then
        local file_first=true
        local sorted_files
        sorted_files=$(printf '%s' "$file_lines" | count_and_sort | head -10)
        while IFS= read -r count_line; do
            [[ -z "$count_line" ]] && continue
            local count fpath
            count=$(echo "$count_line" | awk '{print $1}')
            fpath=$(echo "$count_line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
            if [[ "$file_first" == "true" ]]; then
                file_first=false
            else
                top_files_json+=","
            fi
            top_files_json+="{\"path\":\"$(json_escape_string "$fpath")\",\"count\":${count}}"
        done <<< "$sorted_files"
    fi
    top_files_json+="]"

    local statistics_json
    statistics_json="{\"top_commands\":${top_cmds_json},\"top_files\":${top_files_json},\"tool_usage\":${tool_counts_json},\"event_types\":${type_counts_json}}"

    # Build credential_access JSON array
    local cred_json="["
    local cred_first=true
    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "credential_access" ]]; then
            if [[ "$cred_first" == "true" ]]; then
                cred_first=false
            else
                cred_json+=","
            fi
            local timestamp="${_timestamps[$i]}"
            local tool="${_tool_names[$i]}"
            cred_json+="{\"timestamp\":\"$(json_escape_string "$timestamp")\",\"tool\":\"$(json_escape_string "$tool")\"}"
        fi
    done
    cred_json+="]"

    # Build filesystem_impact JSON
    local fs_count=0
    local fs_paths_json="["
    local fs_path_first=true
    local -a seen_paths=()

    for i in "${!_event_types[@]}"; do
        if [[ "${_event_types[$i]}" == "filesystem_op" ]]; then
            ((fs_count++)) || true
            local file_path
            file_path=$(json_get_string "${_lines[$i]}" "file_path")
            if [[ -n "$file_path" ]]; then
                local already_seen=false
                local p
                for p in "${seen_paths[@]+"${seen_paths[@]}"}"; do
                    if [[ "$p" == "$file_path" ]]; then
                        already_seen=true
                        break
                    fi
                done
                if [[ "$already_seen" != "true" ]]; then
                    seen_paths+=("$file_path")
                    if [[ "$fs_path_first" == "true" ]]; then
                        fs_path_first=false
                    else
                        fs_paths_json+=","
                    fi
                    fs_paths_json+="\"$(json_escape_string "$file_path")\""
                fi
            fi
        fi
    done
    fs_paths_json+="]"

    local fs_json
    fs_json="{\"total_operations\":${fs_count},\"unique_files\":${#seen_paths[@]},\"paths\":${fs_paths_json}}"

    # Build the final JSON object
    local result_json
    result_json="{\"summary\":${summary_json},\"alerts\":${alerts_json},\"statistics\":${statistics_json},\"credential_access\":${cred_json},\"filesystem_impact\":${fs_json}"

    # Optionally add chain verification
    if [[ "$do_verify" == "true" ]]; then
        local verify_result="valid"
        local verify_msg=""
        verify_msg=$(audit_verify_chain "$audit_file" 2>&1) || verify_result="broken"
        result_json+=",\"chain_verification\":{\"result\":\"${verify_result}\",\"message\":\"$(json_escape_string "$verify_msg")\"}"
    fi

    result_json+="}"
    echo "$result_json"
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    local audit_file=""
    local agent_id=""
    local find_latest=false
    local output_format="text"
    local do_verify=false
    local summary_only=false
    local alerts_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            --format)
                output_format="$2"
                shift 2
                ;;
            --verify)
                do_verify=true
                shift
                ;;
            --summary)
                summary_only=true
                shift
                ;;
            --alerts-only)
                alerts_only=true
                shift
                ;;
            --agent-id)
                agent_id="$2"
                shift 2
                ;;
            --latest)
                find_latest=true
                shift
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "Run with --help for usage." >&2
                exit 1
                ;;
            *)
                if [[ -z "$audit_file" ]]; then
                    audit_file="$1"
                else
                    echo "Error: Unexpected argument: $1" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate format
    if [[ "$output_format" != "text" && "$output_format" != "json" ]]; then
        echo "Error: Invalid format '$output_format'. Use 'text' or 'json'." >&2
        exit 1
    fi

    # Resolve audit file
    if [[ -n "$agent_id" ]]; then
        audit_file=$(find_by_agent_id "$agent_id") || exit 1
    elif [[ "$find_latest" == "true" ]]; then
        audit_file=$(find_latest) || exit 1
    elif [[ -z "$audit_file" ]]; then
        echo "Error: No audit file specified." >&2
        echo "Run with --help for usage." >&2
        exit 1
    fi

    # Validate file exists
    if [[ ! -f "$audit_file" ]]; then
        echo "Error: Audit file not found: $audit_file" >&2
        exit 1
    fi

    # Parse the audit file
    parse_audit_file "$audit_file"

    if [[ "$_total_events" -eq 0 ]]; then
        echo "Error: Audit file is empty: $audit_file" >&2
        exit 1
    fi

    # Handle --alerts-only mode
    if [[ "$alerts_only" == "true" ]]; then
        if [[ "$output_format" == "json" ]]; then
            local alerts_file
            alerts_file="${audit_file%.audit.jsonl}-alerts.jsonl"
            if [[ -f "$alerts_file" ]]; then
                echo "["
                local first=true
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ "$first" == "true" ]]; then
                        first=false
                    else
                        echo ","
                    fi
                    printf '%s' "$line"
                done < "$alerts_file"
                echo ""
                echo "]"
            else
                echo "[]"
            fi
        else
            report_alerts_text "$audit_file"
        fi
        return 0
    fi

    # Generate report
    if [[ "$output_format" == "json" ]]; then
        report_json "$audit_file" "$do_verify"
    else
        # Text format
        report_session_summary_text "$audit_file"

        if [[ "$summary_only" == "true" ]]; then
            return 0
        fi

        if [[ "$do_verify" == "true" ]]; then
            report_chain_verification_text "$audit_file"
        fi

        report_alerts_text "$audit_file"
        report_statistics_text
        report_credential_access_text
        report_filesystem_impact_text
    fi
}

main "$@"
