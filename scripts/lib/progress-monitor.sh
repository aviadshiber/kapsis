#!/usr/bin/env bash
#===============================================================================
# Kapsis Progress Monitor (Fallback)
#
# Background daemon that monitors /workspace/.kapsis/progress.json for status
# updates from agents that don't support hooks (like Aider).
#
# The agent is instructed to write progress updates to a JSON file, which this
# monitor reads and translates to Kapsis status updates.
#
# Progress File Format:
# {
#   "version": "1.0",
#   "current_step": 2,
#   "total_steps": 5,
#   "description": "What the agent is doing"
# }
#
# Progress Scale:
#   Agent 0-100% → Kapsis 25-90%
#   Formula: kapsis_progress = 25 + (agent_progress * 65 / 100)
#===============================================================================

set -euo pipefail

# Load status library if available
_PROGRESS_MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=status.sh
[[ -f "$_PROGRESS_MONITOR_DIR/status.sh" ]] && source "$_PROGRESS_MONITOR_DIR/status.sh"

#===============================================================================
# Configuration
#===============================================================================
PROGRESS_FILE="${KAPSIS_PROGRESS_FILE:-/workspace/.kapsis/progress.json}"
POLL_INTERVAL="${KAPSIS_PROGRESS_POLL_INTERVAL:-2}"
STATE_FILE="/kapsis-status/.progress-monitor-state"

# Track last seen values to avoid duplicate updates
LAST_STEP=""
LAST_DESCRIPTION=""

#===============================================================================
# Helper Functions
#===============================================================================

# Log with timestamp
log_monitor() {
    local level="$1"
    shift
    echo "[$(date '+%H:%M:%S')] [$level] progress-monitor: $*" >&2
}

# Calculate Kapsis progress from agent progress
# Agent 0-100% → Kapsis 25-90%
calculate_kapsis_progress() {
    local agent_progress="$1"

    # Clamp agent_progress to 0-100
    if [[ "$agent_progress" -lt 0 ]]; then
        agent_progress=0
    elif [[ "$agent_progress" -gt 100 ]]; then
        agent_progress=100
    fi

    # Formula: kapsis = 25 + (agent_progress * 65 / 100)
    local kapsis_progress=$((25 + (agent_progress * 65 / 100)))
    echo "$kapsis_progress"
}

# Map agent progress percentage to phase
map_progress_to_phase() {
    local progress="$1"

    if [[ "$progress" -lt 20 ]]; then
        echo "exploring"
    elif [[ "$progress" -lt 60 ]]; then
        echo "implementing"
    elif [[ "$progress" -lt 80 ]]; then
        echo "testing"
    else
        echo "completing"
    fi
}

# Parse progress.json and extract fields
parse_progress_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo '{"valid": false}'
        return
    fi

    python3 -c "
import json
import sys

try:
    with open('$file', 'r') as f:
        data = json.load(f)

    # Validate required fields
    version = data.get('version', '1.0')
    current_step = data.get('current_step', 0)
    total_steps = data.get('total_steps', 1)
    description = data.get('description', '')

    # Calculate percentage
    if total_steps > 0:
        percentage = int((current_step / total_steps) * 100)
    else:
        percentage = 0

    output = {
        'valid': True,
        'version': version,
        'current_step': current_step,
        'total_steps': total_steps,
        'percentage': percentage,
        'description': description
    }
    print(json.dumps(output))
except Exception as e:
    print(json.dumps({'valid': False, 'error': str(e)}))
" 2>/dev/null || echo '{"valid": false}'
}

# Update Kapsis status from progress data
update_status() {
    local agent_progress="$1"
    local description="$2"
    local current_step="$3"
    local total_steps="$4"

    # Check if this is a new update
    local state_key="${current_step}:${description}"
    if [[ "$state_key" == "$LAST_STEP:$LAST_DESCRIPTION" ]]; then
        return 0
    fi

    LAST_STEP="$current_step"
    LAST_DESCRIPTION="$description"

    # Calculate Kapsis progress
    local kapsis_progress
    kapsis_progress=$(calculate_kapsis_progress "$agent_progress")

    # Determine phase
    local phase
    phase=$(map_progress_to_phase "$agent_progress")

    # Format message
    local message
    if [[ -n "$description" ]]; then
        message="$description (step $current_step/$total_steps)"
    else
        message="Processing step $current_step of $total_steps"
    fi

    log_monitor "INFO" "Progress update: $kapsis_progress% - $message"

    # Update Kapsis status
    if type status_phase &>/dev/null; then
        status_phase "$phase" "$kapsis_progress" "$message"
    fi

    # Save state
    echo "$state_key" > "$STATE_FILE" 2>/dev/null || true
}

#===============================================================================
# Main Monitor Loop
#===============================================================================
main() {
    log_monitor "INFO" "Starting progress monitor"
    log_monitor "DEBUG" "Watching: $PROGRESS_FILE"
    log_monitor "DEBUG" "Poll interval: ${POLL_INTERVAL}s"

    # Create directory for progress file if needed
    mkdir -p "$(dirname "$PROGRESS_FILE")" 2>/dev/null || true

    # Main monitoring loop
    while true; do
        if [[ -f "$PROGRESS_FILE" ]]; then
            # Parse progress file
            local progress_data
            progress_data=$(parse_progress_file "$PROGRESS_FILE")

            # Check if valid
            local valid
            valid=$(echo "$progress_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('valid', False))" 2>/dev/null || echo "False")

            if [[ "$valid" == "True" ]]; then
                # Extract fields
                local percentage current_step total_steps description
                percentage=$(echo "$progress_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('percentage', 0))" 2>/dev/null || echo "0")
                current_step=$(echo "$progress_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_step', 0))" 2>/dev/null || echo "0")
                total_steps=$(echo "$progress_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_steps', 1))" 2>/dev/null || echo "1")
                description=$(echo "$progress_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description', ''))" 2>/dev/null || echo "")

                # Update status
                update_status "$percentage" "$description" "$current_step" "$total_steps"
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
