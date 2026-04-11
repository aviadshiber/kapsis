#!/usr/bin/env bash
# shellcheck disable=SC2059  # Variables in printf format are intentional for ANSI codes
#===============================================================================
# Kapsis Progress Display Library
#===============================================================================
# Provides in-place terminal progress updates with real-time visualization.
#
# Features:
#   - In-place updates using ANSI escape codes (no repeating output lines)
#   - Animated spinner during active phases
#   - Progress bar with Unicode characters
#   - Elapsed time tracking
#   - Non-TTY fallback for CI/piped output
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/progress-display.sh"
#   display_init
#   display_header "$agent_id" "$branch" "$network_mode"
#   display_progress "Implementing" 55 "Adding token validation..."
#   display_complete 0 "https://github.com/you/repo/pull/42"
#   display_cleanup
#
# Environment Variables:
#   KAPSIS_PROGRESS_DISPLAY  - Enable progress display (set by display_init)
#   KAPSIS_NO_PROGRESS       - Disable progress display entirely
#   NO_COLOR                 - Standard variable to disable colors
#   TERM                     - Terminal type (dumb = no progress display)
#===============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_PROGRESS_DISPLAY_LOADED:-}" ]] && return 0
_KAPSIS_PROGRESS_DISPLAY_LOADED=1

#===============================================================================
# Configuration & Constants
#===============================================================================

# ANSI escape codes for terminal control (guard against re-declaration)
if [[ -z "${_PD_CURSOR_SAVE:-}" ]]; then
    readonly _PD_CURSOR_SAVE=$'\033[s'
    readonly _PD_CURSOR_RESTORE=$'\033[u'
    readonly _PD_CLEAR_LINE=$'\033[K'
    readonly _PD_CLEAR_BELOW=$'\033[J'
    readonly _PD_MOVE_UP=$'\033[A'
    readonly _PD_CARRIAGE_RETURN=$'\r'
    readonly _PD_HIDE_CURSOR=$'\033[?25l'
    readonly _PD_SHOW_CURSOR=$'\033[?25h'

    # Colors
    readonly _PD_GREEN=$'\033[0;32m'
    readonly _PD_CYAN=$'\033[0;36m'
    readonly _PD_YELLOW=$'\033[1;33m'
    readonly _PD_RED=$'\033[0;31m'
    readonly _PD_DIM=$'\033[0;90m'
    readonly _PD_BOLD=$'\033[1m'
    readonly _PD_RESET=$'\033[0m'

    # Spinner frames (braille pattern animation)
    readonly -a _PD_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    # Progress bar characters
    readonly _PD_BAR_FILLED='█'
    readonly _PD_BAR_EMPTY='░'
    readonly _PD_BAR_WIDTH=20
fi

# Phase labels (for display)
declare -A _PD_PHASE_LABELS
_PD_PHASE_LABELS=(
    ["initializing"]="Initializing"
    ["preparing"]="Preparing"
    ["starting"]="Starting"
    ["running"]="Running"
    ["analyzing"]="Analyzing"
    ["implementing"]="Implementing"
    ["testing"]="Testing"
    ["committing"]="Committing"
    ["pushing"]="Pushing"
    ["complete"]="Complete"
    ["post_processing"]="Processing"
    ["exploring"]="Exploring"
    ["completing"]="Completing"
)

#===============================================================================
# Internal State
#===============================================================================

_PD_INITIALIZED=false
_PD_IS_TTY=false
_PD_START_TIME=""
_PD_HEADER_LINES=0          # Number of lines in header (for cursor positioning)
_PD_SPINNER_IDX=0
_PD_LAST_PHASE=""
_PD_LAST_PROGRESS=0
_PD_LAST_MESSAGE=""
_PD_LAST_UPDATE_TIME=0      # For debouncing updates (epoch seconds)

#===============================================================================
# TTY Detection
#===============================================================================

# Check if we're running in a TTY with color support
# Returns: 0 if TTY with color, 1 otherwise
_pd_is_tty() {
    # Check if disabled explicitly
    [[ "${KAPSIS_NO_PROGRESS:-}" == "true" ]] && return 1
    [[ "${KAPSIS_NO_PROGRESS:-}" == "1" ]] && return 1

    # Check stderr is a terminal
    [[ ! -t 2 ]] && return 1

    # Check NO_COLOR standard
    [[ -n "${NO_COLOR:-}" ]] && return 1

    # Check for dumb terminal
    [[ "${TERM:-dumb}" == "dumb" ]] && return 1

    return 0
}

#===============================================================================
# Timer Functions
#===============================================================================

# Format elapsed time as "Xm YYs"
_pd_format_elapsed() {
    local start="${_PD_START_TIME:-}"
    [[ -z "$start" ]] && echo "0m 00s" && return

    local now
    now=$(date +%s)
    local elapsed=$((now - start))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf "%dm %02ds" "$mins" "$secs"
}

#===============================================================================
# Spinner Functions
#===============================================================================

# Get next spinner frame (used inline by _pd_render_progress_section)
_pd_spinner_tick() {
    _PD_SPINNER_IDX=$(( (_PD_SPINNER_IDX + 1) % ${#_PD_SPINNER_FRAMES[@]} ))
    echo -n "${_PD_SPINNER_FRAMES[$_PD_SPINNER_IDX]}"
}

#===============================================================================
# Progress Bar Rendering
#===============================================================================

# Render a progress bar
# Arguments:
#   $1 - Percentage (0-100)
#   $2 - Width (optional, default 20)
# Output: Progress bar string like "[████████░░░░░░░░░░░░] 55%"
_pd_render_bar() {
    local percent="${1:-0}"
    local width="${2:-$_PD_BAR_WIDTH}"

    # Clamp percent
    [[ "$percent" -lt 0 ]] && percent=0
    [[ "$percent" -gt 100 ]] && percent=100

    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do
        bar+="$_PD_BAR_FILLED"
    done
    for ((i=0; i<empty; i++)); do
        bar+="$_PD_BAR_EMPTY"
    done

    printf "%s %3d%%" "$bar" "$percent"
}

# Get phase label for display
_pd_get_phase_label() {
    local phase="$1"
    local label

    # Check if phase exists in the associative array using a workaround for set -u
    # We use ${!array[@]} to get keys and check if our key is among them
    local key
    for key in "${!_PD_PHASE_LABELS[@]}"; do
        if [[ "$key" == "$phase" ]]; then
            label="${_PD_PHASE_LABELS[$phase]}"
            echo "$label"
            return 0
        fi
    done

    # Capitalize first letter if not in map
    label="$(echo "${phase:0:1}" | tr '[:lower:]' '[:upper:]')${phase:1}"
    echo "$label"
}

#===============================================================================
# Terminal Rendering
#===============================================================================

# Render the progress section (called on each update)
# This section updates in-place
_pd_render_progress_section() {
    local phase="$1"
    local progress="${2:-0}"
    local message="${3:-}"

    [[ "$_PD_IS_TTY" != "true" ]] && return

    # Get terminal width
    local term_width="${COLUMNS:-80}"

    # Get spinner frame
    local spinner
    spinner=$(_pd_spinner_tick)

    # Get phase label
    local phase_label
    phase_label=$(_pd_get_phase_label "$phase")

    # Truncate message if too long
    local max_msg_len=$((term_width - 30))
    if [[ ${#message} -gt $max_msg_len ]]; then
        message="${message:0:$((max_msg_len - 3))}..."
    fi

    # Build progress line
    local bar
    bar=$(_pd_render_bar "$progress")

    # Move to progress line position and clear
    printf "${_PD_CARRIAGE_RETURN}${_PD_CLEAR_LINE}" >&2

    # Render progress line: "⠋ Implementing     ████████████░░░░░░░░  55%"
    printf "${_PD_CYAN}%s${_PD_RESET} %-14s %s" "$spinner" "$phase_label" "$bar" >&2

    # Render message line below if present
    printf "\n${_PD_CLEAR_LINE}" >&2
    if [[ -n "$message" ]]; then
        printf "  ${_PD_DIM}%s${_PD_RESET}" "$message" >&2
    fi

    # Move cursor back up (we printed 2 lines, move up 1 to stay on progress line)
    printf "${_PD_MOVE_UP}${_PD_CARRIAGE_RETURN}" >&2
}

# Render non-TTY fallback output (simple line-based)
_pd_render_fallback() {
    local phase="$1"
    local progress="${2:-0}"
    local message="${3:-}"

    local phase_label
    phase_label=$(_pd_get_phase_label "$phase")

    if [[ -n "$message" ]]; then
        echo "[kapsis] Phase: ${phase_label} (${progress}%) - ${message}" >&2
    else
        echo "[kapsis] Phase: ${phase_label} (${progress}%)" >&2
    fi
}

#===============================================================================
# Public API
#===============================================================================

# Initialize the progress display
# Call this before any other display functions
display_init() {
    [[ "$_PD_INITIALIZED" == "true" ]] && return 0

    # Detect TTY
    if _pd_is_tty; then
        _PD_IS_TTY=true
        export KAPSIS_PROGRESS_DISPLAY=1
    else
        _PD_IS_TTY=false
        export KAPSIS_PROGRESS_DISPLAY=0
    fi

    # Record start time
    _PD_START_TIME=$(date +%s)

    # Hide cursor in TTY mode
    [[ "$_PD_IS_TTY" == "true" ]] && printf "${_PD_HIDE_CURSOR}" >&2

    _PD_INITIALIZED=true
}

# Render the header block (call once after container starts)
# Arguments:
#   $1 - Agent ID
#   $2 - Branch name
#   $3 - Network mode
display_header() {
    local agent_id="${1:-unknown}"
    local branch="${2:-}"
    local network="${3:-filtered}"

    [[ "$_PD_INITIALIZED" != "true" ]] && display_init

    local elapsed
    elapsed=$(_pd_format_elapsed)

    if [[ "$_PD_IS_TTY" == "true" ]]; then
        # TTY mode: rich header
        echo "" >&2
        printf "${_PD_GREEN}✓${_PD_RESET} Sandbox ready · Agent: ${_PD_CYAN}%s${_PD_RESET} · %s\n" "$agent_id" "$elapsed" >&2
        if [[ -n "$branch" ]]; then
            printf "Branch: ${_PD_BOLD}%s${_PD_RESET} · Network: %s\n" "$branch" "$network" >&2
        else
            printf "Network: %s\n" "$network" >&2
        fi
        # Separator line
        local term_width="${COLUMNS:-80}"
        local separator=""
        local i
        for ((i=0; i<term_width && i<70; i++)); do
            separator+="─"
        done
        printf "${_PD_DIM}%s${_PD_RESET}\n" "$separator" >&2

        # Reserve space for progress display (2 lines: progress bar + message)
        printf "\n\n" >&2

        _PD_HEADER_LINES=5  # 1 blank + 1 status + 1 branch + 1 separator + 1 progress area

        # Save cursor position after header
        printf "${_PD_CURSOR_SAVE}" >&2
    else
        # Non-TTY fallback
        echo "[kapsis] Sandbox ready · Agent: $agent_id" >&2
        if [[ -n "$branch" ]]; then
            echo "[kapsis] Branch: $branch · Network: $network" >&2
        fi
    fi
}

# Update the progress display
# Arguments:
#   $1 - Phase name
#   $2 - Progress percentage (0-100)
#   $3 - Current task message (optional)
display_progress() {
    local phase="${1:-running}"
    local progress="${2:-0}"
    local message="${3:-}"

    [[ "$_PD_INITIALIZED" != "true" ]] && display_init

    # Debounce updates (except for phase changes)
    # Note: Using seconds for cross-platform compatibility (macOS doesn't support %N)
    local now
    now=$(date +%s)
    if [[ "$phase" == "$_PD_LAST_PHASE" ]] && [[ "$now" == "$_PD_LAST_UPDATE_TIME" ]]; then
        return 0
    fi

    # Capture old values for comparison BEFORE updating
    local old_phase="$_PD_LAST_PHASE"
    local old_progress="$_PD_LAST_PROGRESS"

    # Store current values for next comparison
    _PD_LAST_PHASE="$phase"
    _PD_LAST_PROGRESS="$progress"
    _PD_LAST_MESSAGE="$message"
    _PD_LAST_UPDATE_TIME="$now"

    if [[ "$_PD_IS_TTY" == "true" ]]; then
        _pd_render_progress_section "$phase" "$progress" "$message"
    else
        # Non-TTY: only log on phase change or significant progress change
        if [[ "$phase" != "$old_phase" ]] || [[ $((progress - old_progress)) -ge 10 ]]; then
            _pd_render_fallback "$phase" "$progress" "$message"
        fi
    fi
}

# Display completion summary
# Arguments:
#   $1 - Exit code (0 = success)
#   $2 - PR URL (optional)
#   $3 - Error message (optional)
display_complete() {
    local exit_code="${1:-0}"
    local pr_url="${2:-}"
    local error_msg="${3:-}"

    [[ "$_PD_INITIALIZED" != "true" ]] && return

    local elapsed
    elapsed=$(_pd_format_elapsed)

    if [[ "$_PD_IS_TTY" == "true" ]]; then
        # Show final 100% progress before completion message
        if [[ "$exit_code" -eq 0 ]]; then
            _pd_render_progress_section "complete" 100 "Done"
            # Brief pause to show 100% before clearing
            sleep 0.3
        fi

        # Clear progress section and move to final position
        printf "\n\n${_PD_CLEAR_LINE}" >&2

        if [[ "$exit_code" -eq 0 ]]; then
            printf "\n${_PD_GREEN}✓${_PD_RESET} Task completed successfully! (${elapsed})\n" >&2
            if [[ -n "$pr_url" ]]; then
                printf "${_PD_CYAN}🔗${_PD_RESET} PR: %s\n" "$pr_url" >&2
            fi
        else
            printf "\n${_PD_RED}✗${_PD_RESET} Task failed (exit code: %d, elapsed: %s)\n" "$exit_code" "$elapsed" >&2
            if [[ -n "$error_msg" ]]; then
                # Handle multi-line error messages (e.g., from container stderr)
                printf "\n${_PD_DIM}Container output:${_PD_RESET}\n" >&2
                while IFS= read -r line; do
                    printf "  ${_PD_DIM}%s${_PD_RESET}\n" "$line" >&2
                done <<< "$error_msg"
            fi
            # Show log file location for debugging
            local log_file=""
            if type -t log_get_file &>/dev/null; then
                log_file=$(log_get_file 2>/dev/null || true)
            fi
            if [[ -n "$log_file" ]] && [[ -f "$log_file" ]]; then
                printf "\n${_PD_DIM}📋 Full logs: %s${_PD_RESET}\n" "$log_file" >&2
            fi
        fi
        echo "" >&2
    else
        # Non-TTY fallback
        if [[ "$exit_code" -eq 0 ]]; then
            echo "[kapsis] Complete! ($elapsed)" >&2
            # Use || true to prevent short-circuit from setting exit status
            [[ -n "$pr_url" ]] && echo "[kapsis] PR: $pr_url" >&2 || true
        else
            echo "[kapsis] Failed (exit code: $exit_code, elapsed: $elapsed)" >&2
            if [[ -n "$error_msg" ]]; then
                echo "[kapsis] Container output:" >&2
                while IFS= read -r line; do
                    echo "[kapsis]   $line" >&2
                done <<< "$error_msg"
            fi
            # Show log file location for debugging
            local log_file=""
            if type -t log_get_file &>/dev/null; then
                log_file=$(log_get_file 2>/dev/null || true)
            fi
            if [[ -n "$log_file" ]] && [[ -f "$log_file" ]]; then
                echo "[kapsis] Full logs: $log_file" >&2
            fi
        fi
    fi
}

# Cleanup display state (call in trap or at end)
display_cleanup() {
    # Restore cursor visibility (|| true prevents exit status from short-circuit)
    [[ "$_PD_IS_TTY" == "true" ]] && printf "${_PD_SHOW_CURSOR}" >&2 || true

    _PD_INITIALIZED=false
}

# Check if progress display is enabled
# Returns: 0 if enabled, 1 if disabled
display_is_enabled() {
    [[ "${KAPSIS_PROGRESS_DISPLAY:-0}" == "1" ]]
}
