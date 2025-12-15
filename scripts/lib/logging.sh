#!/usr/bin/env bash
# =============================================================================
# Kapsis Logging Library
# =============================================================================
# Provides comprehensive file-based logging with rotation for all Kapsis scripts.
#
# Features:
#   - Console + file logging with colors
#   - Log rotation (configurable max size and backup count)
#   - Timestamps for debugging
#   - Log levels (DEBUG, INFO, WARN, ERROR)
#   - Per-agent session logs
#   - Context tracking (script name, function, line number)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#   log_init "my-script"
#   log_info "Starting operation"
#   log_debug "Variable value: $var"
#   log_warn "Something unexpected"
#   log_error "Operation failed"
#
# Environment Variables:
#   KAPSIS_LOG_LEVEL   - Minimum log level (DEBUG|INFO|WARN|ERROR), default: INFO
#   KAPSIS_LOG_DIR     - Log directory, default: ~/.kapsis/logs
#   KAPSIS_LOG_FILE    - Override log filename (otherwise auto-generated)
#   KAPSIS_LOG_TO_FILE - Enable file logging (true|false), default: true
#   KAPSIS_LOG_MAX_SIZE_MB - Max log file size before rotation, default: 10
#   KAPSIS_LOG_MAX_FILES   - Max number of rotated files to keep, default: 5
#   KAPSIS_LOG_CONSOLE     - Enable console output (true|false), default: true
#   KAPSIS_LOG_TIMESTAMPS  - Include timestamps (true|false), default: true
#   KAPSIS_DEBUG           - Enable debug mode (sets log level to DEBUG)
# =============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_LOGGING_LOADED:-}" ]] && return 0
_KAPSIS_LOGGING_LOADED=1

# =============================================================================
# Configuration Defaults
# =============================================================================

# Log levels (numeric for comparison) - Bash 3.2 compatible
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# Colors for console output - Bash 3.2 compatible
LOG_COLOR_DEBUG='\033[0;90m'   # Gray
LOG_COLOR_INFO='\033[0;36m'    # Cyan
LOG_COLOR_WARN='\033[1;33m'    # Yellow
LOG_COLOR_ERROR='\033[0;31m'   # Red
LOG_COLOR_SUCCESS='\033[0;32m' # Green
LOG_COLOR_RESET='\033[0m'      # Reset

# Default configuration
: "${KAPSIS_LOG_LEVEL:=INFO}"
: "${KAPSIS_LOG_DIR:=${HOME}/.kapsis/logs}"
: "${KAPSIS_LOG_TO_FILE:=true}"
: "${KAPSIS_LOG_MAX_SIZE_MB:=10}"
: "${KAPSIS_LOG_MAX_FILES:=5}"
: "${KAPSIS_LOG_CONSOLE:=true}"
: "${KAPSIS_LOG_TIMESTAMPS:=true}"

# Enable debug if KAPSIS_DEBUG is set
[[ -n "${KAPSIS_DEBUG:-}" ]] && KAPSIS_LOG_LEVEL="DEBUG"

# Internal state
_KAPSIS_LOG_SCRIPT_NAME=""
_KAPSIS_LOG_SESSION_ID=""
_KAPSIS_LOG_FILE_PATH=""
_KAPSIS_LOG_INITIALIZED=false

# =============================================================================
# Initialization
# =============================================================================

# Initialize the logging system
# Arguments:
#   $1 - Script name/identifier (e.g., "launch-agent", "worktree-manager")
#   $2 - Optional session ID (defaults to timestamp + random)
log_init() {
    local script_name="${1:-unknown}"
    local session_id="${2:-}"

    _KAPSIS_LOG_SCRIPT_NAME="$script_name"

    # Generate session ID if not provided
    if [[ -z "$session_id" ]]; then
        _KAPSIS_LOG_SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    else
        _KAPSIS_LOG_SESSION_ID="$session_id"
    fi

    # Create log directory if needed
    if [[ "$KAPSIS_LOG_TO_FILE" == "true" ]]; then
        mkdir -p "$KAPSIS_LOG_DIR" 2>/dev/null || {
            echo "[WARN] Could not create log directory: $KAPSIS_LOG_DIR" >&2
            KAPSIS_LOG_TO_FILE=false
        }

        # Set log file path if not overridden
        if [[ -z "${KAPSIS_LOG_FILE:-}" ]]; then
            _KAPSIS_LOG_FILE_PATH="${KAPSIS_LOG_DIR}/kapsis-${script_name}.log"
        else
            _KAPSIS_LOG_FILE_PATH="$KAPSIS_LOG_FILE"
        fi
    fi

    _KAPSIS_LOG_INITIALIZED=true

    # Log initialization
    _log_raw "INFO" "=========================================="
    _log_raw "INFO" "Logging initialized for ${script_name}"
    _log_raw "INFO" "Session: ${_KAPSIS_LOG_SESSION_ID}"
    _log_raw "INFO" "Log level: ${KAPSIS_LOG_LEVEL}"
    [[ "$KAPSIS_LOG_TO_FILE" == "true" ]] && _log_raw "INFO" "Log file: ${_KAPSIS_LOG_FILE_PATH}"
    _log_raw "INFO" "=========================================="
}

# =============================================================================
# Log Rotation
# =============================================================================

# Rotate log file if it exceeds max size
_log_rotate() {
    [[ "$KAPSIS_LOG_TO_FILE" != "true" ]] && return 0
    [[ ! -f "$_KAPSIS_LOG_FILE_PATH" ]] && return 0

    local max_bytes=$((KAPSIS_LOG_MAX_SIZE_MB * 1024 * 1024))
    local current_size

    # Get file size (compatible with macOS and Linux)
    if [[ "$(uname)" == "Darwin" ]]; then
        current_size=$(stat -f%z "$_KAPSIS_LOG_FILE_PATH" 2>/dev/null || echo 0)
    else
        current_size=$(stat -c%s "$_KAPSIS_LOG_FILE_PATH" 2>/dev/null || echo 0)
    fi

    if [[ "$current_size" -ge "$max_bytes" ]]; then
        _do_rotation
    fi
}

# Perform the actual rotation
_do_rotation() {
    local base_path="$_KAPSIS_LOG_FILE_PATH"
    local max_files="${KAPSIS_LOG_MAX_FILES}"

    # Remove oldest file if at limit
    local oldest="${base_path}.${max_files}"
    [[ -f "$oldest" ]] && rm -f "$oldest"

    # Shift existing files
    for ((i=max_files-1; i>=1; i--)); do
        local current="${base_path}.${i}"
        local next="${base_path}.$((i+1))"
        [[ -f "$current" ]] && mv "$current" "$next"
    done

    # Rotate current log
    [[ -f "$base_path" ]] && mv "$base_path" "${base_path}.1"

    # Create new empty log file
    touch "$base_path"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [logging] Log rotated (previous file: ${base_path}.1)" >> "$base_path"
}

# =============================================================================
# Core Logging Functions
# =============================================================================

# Get caller context (script:function:line)
_get_caller_context() {
    local depth="${1:-2}"
    local func="${FUNCNAME[$((depth+1))]:-main}"
    local line="${BASH_LINENO[$depth]:-0}"
    echo "${func}:${line}"
}

# Get numeric level for a log level name (Bash 3.2 compatible)
_get_level_num() {
    case "$1" in
        DEBUG) echo $LOG_LEVEL_DEBUG ;;
        INFO)  echo $LOG_LEVEL_INFO ;;
        WARN)  echo $LOG_LEVEL_WARN ;;
        ERROR) echo $LOG_LEVEL_ERROR ;;
        *)     echo $LOG_LEVEL_INFO ;;
    esac
}

# Get color for a log level (Bash 3.2 compatible)
_get_level_color() {
    case "$1" in
        DEBUG)   echo "$LOG_COLOR_DEBUG" ;;
        INFO)    echo "$LOG_COLOR_INFO" ;;
        WARN)    echo "$LOG_COLOR_WARN" ;;
        ERROR)   echo "$LOG_COLOR_ERROR" ;;
        SUCCESS) echo "$LOG_COLOR_SUCCESS" ;;
        *)       echo "$LOG_COLOR_INFO" ;;
    esac
}

# Check if log level should be output
_should_log() {
    local level="$1"
    local min_level="${KAPSIS_LOG_LEVEL}"

    local level_num
    level_num=$(_get_level_num "$level")
    local min_num
    min_num=$(_get_level_num "$min_level")

    [[ "$level_num" -ge "$min_num" ]]
}

# Raw logging function (bypasses level check)
_log_raw() {
    local level="$1"
    shift
    local message="$*"

    local timestamp=""
    [[ "$KAPSIS_LOG_TIMESTAMPS" == "true" ]] && timestamp="[$(date '+%Y-%m-%d %H:%M:%S')] "

    local prefix="[${_KAPSIS_LOG_SCRIPT_NAME:-kapsis}]"
    local formatted="${timestamp}[${level}] ${prefix} ${message}"

    # Write to file
    if [[ "$KAPSIS_LOG_TO_FILE" == "true" && -n "$_KAPSIS_LOG_FILE_PATH" ]]; then
        echo "$formatted" >> "$_KAPSIS_LOG_FILE_PATH" 2>/dev/null
    fi
}

# Main logging function
_log() {
    local level="$1"
    shift
    local message="$*"

    # Check if we should log this level
    _should_log "$level" || return 0

    # Auto-initialize if needed
    if [[ "$_KAPSIS_LOG_INITIALIZED" != "true" ]]; then
        log_init "$(basename "${BASH_SOURCE[2]:-unknown}" .sh)"
    fi

    # Check rotation before writing
    _log_rotate

    local timestamp=""
    [[ "$KAPSIS_LOG_TIMESTAMPS" == "true" ]] && timestamp="[$(date '+%Y-%m-%d %H:%M:%S')] "

    local context="$(_get_caller_context 2)"
    local prefix="[${_KAPSIS_LOG_SCRIPT_NAME:-kapsis}]"

    # File format (no colors, includes context)
    local file_formatted="${timestamp}[${level}] ${prefix} [${context}] ${message}"

    # Console format (with colors) - Bash 3.2 compatible
    local color
    color=$(_get_level_color "$level")
    local reset="$LOG_COLOR_RESET"
    local console_formatted="${color}${timestamp}[${level}] ${prefix}${reset} ${message}"

    # Write to file
    if [[ "$KAPSIS_LOG_TO_FILE" == "true" && -n "$_KAPSIS_LOG_FILE_PATH" ]]; then
        echo "$file_formatted" >> "$_KAPSIS_LOG_FILE_PATH" 2>/dev/null
    fi

    # Write to console
    if [[ "$KAPSIS_LOG_CONSOLE" == "true" ]]; then
        if [[ "$level" == "ERROR" ]]; then
            echo -e "$console_formatted" >&2
        else
            echo -e "$console_formatted"
        fi
    fi
}

# =============================================================================
# Public Logging Functions
# =============================================================================

log_debug() {
    _log "DEBUG" "$@"
}

log_info() {
    _log "INFO" "$@"
}

log_warn() {
    _log "WARN" "$@"
}

log_error() {
    _log "ERROR" "$@"
}

# Success is INFO level with green color
log_success() {
    local message="$*"

    _should_log "INFO" || return 0

    if [[ "$_KAPSIS_LOG_INITIALIZED" != "true" ]]; then
        log_init "$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
    fi

    _log_rotate

    local timestamp=""
    [[ "$KAPSIS_LOG_TIMESTAMPS" == "true" ]] && timestamp="[$(date '+%Y-%m-%d %H:%M:%S')] "

    local context="$(_get_caller_context 1)"
    local prefix="[${_KAPSIS_LOG_SCRIPT_NAME:-kapsis}]"

    # File format
    local file_formatted="${timestamp}[INFO] ${prefix} [${context}] ${message}"

    # Console format (green) - Bash 3.2 compatible
    local color="$LOG_COLOR_SUCCESS"
    local reset="$LOG_COLOR_RESET"
    local console_formatted="${color}${timestamp}[INFO] ${prefix}${reset} ${message}"

    # Write to file
    if [[ "$KAPSIS_LOG_TO_FILE" == "true" && -n "$_KAPSIS_LOG_FILE_PATH" ]]; then
        echo "$file_formatted" >> "$_KAPSIS_LOG_FILE_PATH" 2>/dev/null
    fi

    # Write to console
    if [[ "$KAPSIS_LOG_CONSOLE" == "true" ]]; then
        echo -e "$console_formatted"
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Log a command before executing it (useful for debugging)
log_cmd() {
    local cmd="$*"
    log_debug "Executing: $cmd"
    eval "$cmd"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_debug "Command exited with code: $rc"
    fi
    return $rc
}

# Log entry into a function
log_enter() {
    local func="${FUNCNAME[1]:-unknown}"
    log_debug ">>> Entering ${func}() with args: $*"
}

# Log exit from a function
log_exit() {
    local func="${FUNCNAME[1]:-unknown}"
    local rc="${1:-0}"
    log_debug "<<< Exiting ${func}() with code: $rc"
}

# Log a variable's value
log_var() {
    local var_name="$1"
    local var_value="${!var_name:-<unset>}"
    log_debug "${var_name}=${var_value}"
}

# Log multiple variables
log_vars() {
    for var_name in "$@"; do
        log_var "$var_name"
    done
}

# Log a section header (for visual separation in logs)
log_section() {
    local title="$1"
    local line="----------------------------------------"
    log_info "$line"
    log_info "$title"
    log_info "$line"
}

# Log elapsed time for a phase (Bash 3.2 compatible)
log_timer_start() {
    local timer_name="${1:-default}"
    eval "_KAPSIS_TIMER_${timer_name}=$(date +%s)"
}

log_timer_end() {
    local timer_name="${1:-default}"
    local var_name="_KAPSIS_TIMER_${timer_name}"
    local start_time="${!var_name:-$(date +%s)}"
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Timer [${timer_name}]: ${elapsed}s elapsed"
}

# Log environment summary (useful at startup)
log_env_summary() {
    log_section "Environment Summary"
    log_debug "USER: ${USER:-unknown}"
    log_debug "HOME: ${HOME:-unknown}"
    log_debug "PWD: ${PWD:-unknown}"
    log_debug "SHELL: ${SHELL:-unknown}"
    log_debug "PATH: ${PATH:-unknown}"
    log_debug "Kapsis Log Dir: ${KAPSIS_LOG_DIR}"
    log_debug "Kapsis Log Level: ${KAPSIS_LOG_LEVEL}"
}

# =============================================================================
# Cleanup / Finalization
# =============================================================================

# Finalize logging (call at end of script)
log_finalize() {
    local exit_code="${1:-0}"
    _log_raw "INFO" "=========================================="
    _log_raw "INFO" "Script completed with exit code: ${exit_code}"
    _log_raw "INFO" "Session: ${_KAPSIS_LOG_SESSION_ID}"
    _log_raw "INFO" "=========================================="
}

# Get the current log file path
log_get_file() {
    echo "$_KAPSIS_LOG_FILE_PATH"
}

# Get the current session ID
log_get_session() {
    echo "$_KAPSIS_LOG_SESSION_ID"
}

# Tail the current log file (useful for debugging)
log_tail() {
    local lines="${1:-50}"
    if [[ -f "$_KAPSIS_LOG_FILE_PATH" ]]; then
        tail -n "$lines" "$_KAPSIS_LOG_FILE_PATH"
    else
        echo "No log file available"
    fi
}

# =============================================================================
# Legacy Compatibility Layer
# =============================================================================
# These functions match the old logging signatures used in existing scripts
# to make migration easier. They all route through the new logging system.

# Old-style colored logging (maps to new system)
# Usage: log_info_legacy "PREFIX" "message"
log_info_legacy() {
    local prefix="$1"
    shift
    log_info "[$prefix] $*"
}

log_success_legacy() {
    local prefix="$1"
    shift
    log_success "[$prefix] $*"
}

log_warn_legacy() {
    local prefix="$1"
    shift
    log_warn "[$prefix] $*"
}

log_error_legacy() {
    local prefix="$1"
    shift
    log_error "[$prefix] $*"
}
