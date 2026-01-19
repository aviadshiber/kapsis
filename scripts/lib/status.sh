#!/usr/bin/env bash
# =============================================================================
# Kapsis Status Library
# =============================================================================
# Provides JSON-based status reporting for external consumers to monitor
# agent progress in real-time.
#
# Features:
#   - Phase-level progress tracking
#   - JSON output for easy parsing
#   - Atomic file writes (temp + mv)
#   - Works in both host and container contexts
#   - Progress percentage estimates
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"
#   status_init "my-project" "1" "feature/DEV-123" "worktree"
#   status_phase "initializing" 5 "Validating inputs"
#   status_phase "running" 50 "Agent executing task"
#   status_complete 0  # Success
#   status_complete 1 "Build failed"  # Failure with error message
#
# Environment Variables:
#   KAPSIS_STATUS_DIR      - Status directory, default: ~/.kapsis/status
#   KAPSIS_STATUS_ENABLED  - Enable status reporting (true|false), default: true
#   KAPSIS_STATUS_VERSION  - JSON schema version, default: 1.0
#
# Container Environment Variables (set by launch-agent.sh):
#   KAPSIS_STATUS_PROJECT  - Project name for status file
#   KAPSIS_STATUS_AGENT_ID - Agent ID for status file
#   KAPSIS_STATUS_BRANCH   - Git branch being worked on
# =============================================================================

# Prevent double-sourcing
[[ -n "${_KAPSIS_STATUS_LOADED:-}" ]] && return 0
_KAPSIS_STATUS_LOADED=1

# =============================================================================
# Configuration Defaults
# =============================================================================

# Default configuration
: "${KAPSIS_STATUS_DIR:=${HOME}/.kapsis/status}"
: "${KAPSIS_STATUS_ENABLED:=true}"
: "${KAPSIS_STATUS_VERSION:=1.0}"
: "${KAPSIS_GIST_FILE:=/workspace/.kapsis/gist.txt}"

# Internal state
_KAPSIS_STATUS_PROJECT=""
_KAPSIS_STATUS_AGENT_ID=""
_KAPSIS_STATUS_BRANCH=""
_KAPSIS_STATUS_SANDBOX_MODE=""
_KAPSIS_STATUS_WORKTREE_PATH=""
_KAPSIS_STATUS_FILE=""
_KAPSIS_STATUS_STARTED=""
_KAPSIS_STATUS_INITIALIZED=false

# Push verification state
_KAPSIS_PUSH_STATUS=""           # "success", "failed", "skipped", "unverified"
_KAPSIS_PUSH_FALLBACK_CMD=""     # Fallback command for agent recovery when push fails
_KAPSIS_LOCAL_COMMIT=""     # Local HEAD commit SHA
_KAPSIS_REMOTE_COMMIT=""    # Remote HEAD commit SHA after push

# Commit verification state (Fix #3: verify commit before reporting completion)
_KAPSIS_COMMIT_STATUS=""         # "success", "failed", "uncommitted", "no_changes"
_KAPSIS_COMMIT_SHA=""            # SHA of committed changes
_KAPSIS_UNCOMMITTED_FILES=0      # Count of uncommitted files remaining
_KAPSIS_PRE_COMMIT_SHA=""        # SHA before commit (to verify HEAD moved)

# Agent gist state (agent-provided summary of current activity)
_KAPSIS_GIST=""                  # Current gist message from agent
_KAPSIS_GIST_UPDATED_AT=""       # When gist was last updated

# Gist rate limiting state (reduce I/O on frequent PostToolUse calls)
_KAPSIS_GIST_LAST_READ=""        # Epoch timestamp of last gist read
_KAPSIS_GIST_LAST_MTIME=""       # Last known file mtime

# =============================================================================
# Helper Functions
# =============================================================================

# Get the status directory (auto-detect container vs host)
_status_get_dir() {
    # In container: use mounted path if available
    if [[ -d "/kapsis-status" ]]; then
        echo "/kapsis-status"
    else
        echo "$KAPSIS_STATUS_DIR"
    fi
}

# Get current UTC timestamp in ISO 8601 format
_status_timestamp() {
    # macOS and Linux compatible
    if date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then
        return 0
    else
        # Fallback for older systems
        date +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# Escape string for JSON (handles quotes, backslashes, newlines, control chars)
# Security: Removes control characters that could break JSON parsing or enable injection
_status_json_escape() {
    local str="$1"
    # Escape backslashes first, then quotes, then whitespace chars
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    # Security: Remove control characters (0x00-0x1F except those already handled)
    # This prevents JSON injection and parsing issues
    # Using tr to remove: NUL, SOH-US (except \t\n\r already escaped), DEL
    str=$(printf '%s' "$str" | tr -d '\000-\010\013\014\016-\037\177')
    echo "$str"
}

# Validate agent_id format (defense-in-depth for file path safety)
# Only allows alphanumeric characters, hyphens, and underscores
# Arguments:
#   $1 - Agent ID to validate
# Returns:
#   0 if valid, 1 if invalid
_status_validate_agent_id() {
    local agent_id="$1"
    if [[ "$agent_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    else
        echo "[status] Error: Invalid agent_id format: $agent_id (must match ^[a-zA-Z0-9_-]+$)" >&2
        return 1
    fi
}

# =============================================================================
# Initialization
# =============================================================================

# Initialize status tracking
# Arguments:
#   $1 - Project name
#   $2 - Agent ID
#   $3 - Branch name (optional)
#   $4 - Sandbox mode: "worktree" or "overlay" (optional, default: overlay)
#   $5 - Worktree path (optional)
status_init() {
    [[ "$KAPSIS_STATUS_ENABLED" != "true" ]] && return 0

    local project="${1:-}"
    local agent_id="${2:-}"
    local branch="${3:-}"
    local sandbox_mode="${4:-overlay}"
    local worktree_path="${5:-}"

    # Validate required parameters
    if [[ -z "$project" || -z "$agent_id" ]]; then
        echo "[status] Warning: status_init requires project and agent_id" >&2
        return 1
    fi

    # Validate agent_id format (defense-in-depth for file path safety)
    if ! _status_validate_agent_id "$agent_id"; then
        return 1
    fi

    _KAPSIS_STATUS_PROJECT="$project"
    _KAPSIS_STATUS_AGENT_ID="$agent_id"
    _KAPSIS_STATUS_BRANCH="$branch"
    _KAPSIS_STATUS_SANDBOX_MODE="$sandbox_mode"
    _KAPSIS_STATUS_WORKTREE_PATH="$worktree_path"
    _KAPSIS_STATUS_STARTED=$(_status_timestamp)

    # Create status directory
    local status_dir
    status_dir=$(_status_get_dir)
    mkdir -p "$status_dir" 2>/dev/null || {
        echo "[status] Warning: Could not create status directory: $status_dir" >&2
        KAPSIS_STATUS_ENABLED=false
        return 1
    }

    # Set status file path
    _KAPSIS_STATUS_FILE="${status_dir}/kapsis-${project}-${agent_id}.json"
    _KAPSIS_STATUS_INITIALIZED=true

    # Write initial status
    _status_write "initializing" 0 "Starting agent"
}

# =============================================================================
# Status Updates
# =============================================================================

# Update current phase and progress
# Arguments:
#   $1 - Phase name (initializing, preparing, starting, running, committing, pushing, complete)
#   $2 - Progress percentage (0-100)
#   $3 - Human-readable message (optional)
status_phase() {
    [[ "$KAPSIS_STATUS_ENABLED" != "true" ]] && return 0
    [[ "$_KAPSIS_STATUS_INITIALIZED" != "true" ]] && return 0

    local phase="$1"
    local progress="${2:-0}"
    local message="${3:-}"

    _status_write "$phase" "$progress" "$message"
}

# Mark task as complete
# Arguments:
#   $1 - Exit code (0 = success, non-zero = failure)
#   $2 - Error message (optional, for failures)
#   $3 - PR URL (optional)
status_complete() {
    [[ "$KAPSIS_STATUS_ENABLED" != "true" ]] && return 0
    [[ "$_KAPSIS_STATUS_INITIALIZED" != "true" ]] && return 0

    local exit_code="${1:-0}"
    local error_message="${2:-}"
    local pr_url="${3:-}"

    local message="Completed successfully"
    if [[ "$exit_code" -ne 0 ]]; then
        message="Failed with exit code $exit_code"
    fi

    _status_write "complete" 100 "$message" "$exit_code" "$error_message" "$pr_url"
}

# =============================================================================
# Push Verification
# =============================================================================

# Set push verification information
# Arguments:
#   $1 - Push status: "success", "failed", "skipped", "unverified"
#   $2 - Local commit SHA
#   $3 - Remote commit SHA (optional)
status_set_push_info() {
    _KAPSIS_PUSH_STATUS="${1:-unverified}"
    _KAPSIS_LOCAL_COMMIT="${2:-}"
    _KAPSIS_REMOTE_COMMIT="${3:-}"
}

# Set push fallback command for agent recovery
# When push fails, this provides a command the orchestrating agent can run
# Arguments:
#   $1 - Worktree path
#   $2 - Remote name
#   $3 - Branch name
status_set_push_fallback() {
    local worktree_path="$1"
    local remote="${2:-origin}"
    local branch="$3"

    if [[ -z "$worktree_path" || -z "$branch" ]]; then
        _KAPSIS_PUSH_FALLBACK_CMD=""
        return
    fi

    _KAPSIS_PUSH_FALLBACK_CMD="cd ${worktree_path} && git push -u ${remote} ${branch}"

    # Output machine-parseable marker for agent grep
    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│ PUSH FALLBACK (for agent recovery)                                 │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    echo "KAPSIS_PUSH_FALLBACK: $_KAPSIS_PUSH_FALLBACK_CMD"
    echo ""
    echo "The orchestrating agent can run this command from the host where"
    echo "git credentials are available."
    echo ""
}

# Verify push succeeded by comparing local and remote HEAD
# Arguments:
#   $1 - Worktree/repo path
#   $2 - Remote name (default: origin)
#   $3 - Branch name
# Returns: 0 if push verified, 1 if verification failed
status_verify_push() {
    local repo_path="${1:-.}"
    local remote="${2:-origin}"
    local branch="${3:-}"

    cd "$repo_path" || return 1

    # Get current branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    # Get local HEAD commit
    local local_commit
    local_commit=$(git rev-parse HEAD 2>/dev/null)
    if [[ -z "$local_commit" ]]; then
        status_set_push_info "failed" "" ""
        return 1
    fi

    # Fetch latest from remote to ensure we have current state
    git fetch "$remote" "$branch" --quiet 2>/dev/null || true

    # Get remote HEAD commit
    local remote_commit
    remote_commit=$(git rev-parse "${remote}/${branch}" 2>/dev/null)

    # Compare commits
    if [[ "$local_commit" == "$remote_commit" ]]; then
        status_set_push_info "success" "$local_commit" "$remote_commit"
        return 0
    else
        status_set_push_info "failed" "$local_commit" "${remote_commit:-unknown}"
        return 1
    fi
}

# Mark push as skipped (for --no-push scenarios)
status_push_skipped() {
    local local_commit="${1:-}"
    status_set_push_info "skipped" "$local_commit" ""
}

# =============================================================================
# Commit Verification (Fix #3)
# =============================================================================

# Set commit verification information
# Arguments:
#   $1 - Commit status: "success", "failed", "uncommitted", "no_changes"
#   $2 - Commit SHA (optional)
#   $3 - Uncommitted file count (optional)
status_set_commit_info() {
    _KAPSIS_COMMIT_STATUS="${1:-uncommitted}"
    _KAPSIS_COMMIT_SHA="${2:-}"
    _KAPSIS_UNCOMMITTED_FILES="${3:-0}"
}

# Record the pre-commit SHA for later verification
# Call this BEFORE attempting to commit
# Arguments:
#   $1 - Worktree path
status_record_pre_commit() {
    local worktree_path="$1"
    _KAPSIS_PRE_COMMIT_SHA=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")
}

# Verify that a commit was created and no uncommitted changes remain
# Call this AFTER commit_changes() to verify success
# Arguments:
#   $1 - Worktree path
# Returns:
#   0 if commit verified (HEAD moved and working tree is clean)
#   1 if no commit happened (HEAD unchanged)
#   2 if uncommitted changes remain
status_verify_commit() {
    local worktree_path="$1"

    # Get current HEAD
    local current_sha
    current_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null)

    # Check if HEAD moved (commit happened)
    if [[ -n "$_KAPSIS_PRE_COMMIT_SHA" && "$current_sha" == "$_KAPSIS_PRE_COMMIT_SHA" ]]; then
        # HEAD didn't move - no commit was created
        # Check if there were changes that should have been committed
        local uncommitted_count
        uncommitted_count=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$uncommitted_count" -gt 0 ]]; then
            status_set_commit_info "uncommitted" "" "$uncommitted_count"
            return 2
        else
            # No changes and HEAD didn't move - this is "no_changes" not a failure
            status_set_commit_info "no_changes" "$current_sha" "0"
            return 0
        fi
    fi

    # HEAD moved - verify no uncommitted changes remain
    local remaining_changes
    remaining_changes=$(git -C "$worktree_path" status --porcelain 2>/dev/null)

    if [[ -n "$remaining_changes" ]]; then
        local uncommitted_count
        uncommitted_count=$(echo "$remaining_changes" | wc -l | tr -d ' ')
        status_set_commit_info "uncommitted" "$current_sha" "$uncommitted_count"
        return 2
    fi

    # Success: HEAD moved and no uncommitted changes
    status_set_commit_info "success" "$current_sha" "0"
    return 0
}

# Get commit status for external queries
status_get_commit_status() {
    echo "${_KAPSIS_COMMIT_STATUS:-unknown}"
}

# Get commit SHA for external queries
status_get_commit_sha() {
    echo "${_KAPSIS_COMMIT_SHA:-}"
}

# =============================================================================
# Agent Gist (Activity Summary)
# =============================================================================

# Set agent gist from a message
# Called by hooks when they read the gist file
# Arguments:
#   $1 - Gist message (truncated to 500 chars for safety)
status_set_gist() {
    local gist="${1:-}"
    # Truncate to 500 chars for safety
    _KAPSIS_GIST="${gist:0:500}"
    _KAPSIS_GIST_UPDATED_AT=$(_status_timestamp)
}

# Read gist from the signaling file
# The agent writes to $KAPSIS_GIST_FILE (default: /workspace/.kapsis/gist.txt)
# This function reads it and updates internal state
# Arguments:
#   $1 - Path to gist file (default: $KAPSIS_GIST_FILE)
# Security:
#   - Path is canonicalized with realpath to prevent traversal attacks
#   - Only reads files within /workspace/.kapsis/ directory
# Rate Limiting:
#   - Time debounce: Skip read if read within last N seconds (KAPSIS_GIST_DEBOUNCE, default: 5)
#   - Mtime bypass: If file changed (different mtime), read immediately
status_read_gist_file() {
    local gist_file="${1:-$KAPSIS_GIST_FILE}"

    # Security: Canonicalize path to prevent directory traversal
    # realpath -m allows non-existent paths (for validation before file exists)
    local canonical_path
    canonical_path=$(realpath -m "$gist_file" 2>/dev/null) || return 0

    # Security: Only allow gist files within the workspace .kapsis directory
    local allowed_prefix="/workspace/.kapsis/"
    if [[ "$canonical_path" != "${allowed_prefix}"* ]]; then
        # Path escapes allowed directory - silently ignore for security
        return 0
    fi

    if [[ -f "$canonical_path" ]]; then
        local should_read=false
        local now
        now=$(date +%s)

        # Check mtime - if file changed, always read (bypass debounce)
        local current_mtime
        # macOS uses -f %m, Linux uses -c %Y
        current_mtime=$(stat -f %m "$canonical_path" 2>/dev/null || stat -c %Y "$canonical_path" 2>/dev/null || echo "")

        if [[ -n "$current_mtime" && "$current_mtime" != "${_KAPSIS_GIST_LAST_MTIME:-}" ]]; then
            should_read=true
            _KAPSIS_GIST_LAST_MTIME="$current_mtime"
        fi

        # Time debounce (default: 5 seconds)
        # Only check time if mtime didn't trigger a read
        if [[ "$should_read" != "true" ]]; then
            local debounce_secs="${KAPSIS_GIST_DEBOUNCE:-5}"
            if [[ -z "$_KAPSIS_GIST_LAST_READ" ]] || (( now - _KAPSIS_GIST_LAST_READ >= debounce_secs )); then
                should_read=true
            fi
        fi

        # Update last read timestamp when we actually read
        if [[ "$should_read" == "true" ]]; then
            _KAPSIS_GIST_LAST_READ="$now"
            local gist
            # Read first 500 chars, strip newlines
            gist=$(head -c 500 "$canonical_path" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
            if [[ -n "$gist" ]]; then
                status_set_gist "$gist"
            fi
        fi
    fi
}

# =============================================================================
# Internal Write Function
# =============================================================================

# Write status file atomically
# Arguments:
#   $1 - Phase
#   $2 - Progress
#   $3 - Message
#   $4 - Exit code (optional)
#   $5 - Error message (optional)
#   $6 - PR URL (optional)
_status_write() {
    local phase="$1"
    local progress="$2"
    local message="${3:-}"
    local exit_code="${4:-}"
    local error="${5:-}"
    local pr_url="${6:-}"

    local updated_at
    updated_at=$(_status_timestamp)

    # Escape strings for JSON
    local escaped_message
    escaped_message=$(_status_json_escape "$message")
    local escaped_error
    escaped_error=$(_status_json_escape "$error")
    local escaped_branch
    escaped_branch=$(_status_json_escape "$_KAPSIS_STATUS_BRANCH")
    local escaped_worktree
    escaped_worktree=$(_status_json_escape "$_KAPSIS_STATUS_WORKTREE_PATH")

    # Format optional fields as JSON null or value
    local exit_code_json="null"
    [[ -n "$exit_code" ]] && exit_code_json="$exit_code"

    local error_json="null"
    [[ -n "$error" ]] && error_json="\"$escaped_error\""

    local pr_url_json="null"
    [[ -n "$pr_url" ]] && pr_url_json="\"$pr_url\""

    local branch_json="null"
    [[ -n "$_KAPSIS_STATUS_BRANCH" ]] && branch_json="\"$escaped_branch\""

    local worktree_json="null"
    [[ -n "$_KAPSIS_STATUS_WORKTREE_PATH" ]] && worktree_json="\"$escaped_worktree\""

    # Push verification fields
    local push_status_json="null"
    [[ -n "$_KAPSIS_PUSH_STATUS" ]] && push_status_json="\"$_KAPSIS_PUSH_STATUS\""

    local local_commit_json="null"
    [[ -n "$_KAPSIS_LOCAL_COMMIT" ]] && local_commit_json="\"$_KAPSIS_LOCAL_COMMIT\""

    local remote_commit_json="null"
    [[ -n "$_KAPSIS_REMOTE_COMMIT" ]] && remote_commit_json="\"$_KAPSIS_REMOTE_COMMIT\""

    # Push fallback command for agent recovery
    local push_fallback_json="null"
    if [[ -n "$_KAPSIS_PUSH_FALLBACK_CMD" ]]; then
        local escaped_fallback
        escaped_fallback=$(_status_json_escape "$_KAPSIS_PUSH_FALLBACK_CMD")
        push_fallback_json="\"$escaped_fallback\""
    fi

    # Commit verification fields (Fix #3)
    local commit_status_json="null"
    [[ -n "$_KAPSIS_COMMIT_STATUS" ]] && commit_status_json="\"$_KAPSIS_COMMIT_STATUS\""

    local commit_sha_json="null"
    [[ -n "$_KAPSIS_COMMIT_SHA" ]] && commit_sha_json="\"$_KAPSIS_COMMIT_SHA\""

    local uncommitted_files_json="${_KAPSIS_UNCOMMITTED_FILES:-0}"

    # Agent gist fields
    local gist_json="null"
    local gist_updated_at_json="null"
    if [[ -n "$_KAPSIS_GIST" ]]; then
        local escaped_gist
        escaped_gist=$(_status_json_escape "$_KAPSIS_GIST")
        gist_json="\"$escaped_gist\""
        [[ -n "$_KAPSIS_GIST_UPDATED_AT" ]] && gist_updated_at_json="\"$_KAPSIS_GIST_UPDATED_AT\""
    fi

    # Build JSON (using heredoc for readability)
    local json
    json=$(cat << EOF
{
  "version": "${KAPSIS_STATUS_VERSION}",
  "agent_id": "${_KAPSIS_STATUS_AGENT_ID}",
  "project": "${_KAPSIS_STATUS_PROJECT}",
  "branch": ${branch_json},
  "sandbox_mode": "${_KAPSIS_STATUS_SANDBOX_MODE}",
  "phase": "${phase}",
  "progress": ${progress},
  "message": "${escaped_message}",
  "gist": ${gist_json},
  "gist_updated_at": ${gist_updated_at_json},
  "started_at": "${_KAPSIS_STATUS_STARTED}",
  "updated_at": "${updated_at}",
  "exit_code": ${exit_code_json},
  "error": ${error_json},
  "worktree_path": ${worktree_json},
  "pr_url": ${pr_url_json},
  "push_status": ${push_status_json},
  "local_commit": ${local_commit_json},
  "remote_commit": ${remote_commit_json},
  "push_fallback_command": ${push_fallback_json},
  "commit_status": ${commit_status_json},
  "commit_sha": ${commit_sha_json},
  "uncommitted_files": ${uncommitted_files_json}
}
EOF
)

    # Atomic write: temp file + mv
    # Security: Restrict status file permissions (contains project/agent metadata)
    local temp_file="${_KAPSIS_STATUS_FILE}.tmp.$$"
    if echo "$json" > "$temp_file" 2>/dev/null; then
        chmod 600 "$temp_file" 2>/dev/null || true
        mv "$temp_file" "$_KAPSIS_STATUS_FILE" 2>/dev/null || {
            rm -f "$temp_file" 2>/dev/null
            return 1
        }
    else
        return 1
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Get status file path
status_get_file() {
    echo "$_KAPSIS_STATUS_FILE"
}

# Get current phase
status_get_phase() {
    if [[ -f "$_KAPSIS_STATUS_FILE" ]]; then
        # Native bash regex extraction (no subprocess overhead)
        local content
        content=$(<"$_KAPSIS_STATUS_FILE") 2>/dev/null || return
        if [[ "$content" =~ \"phase\":\ *\"([^\"]*)\" ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    fi
}

# Check if status tracking is active
status_is_active() {
    [[ "$KAPSIS_STATUS_ENABLED" == "true" && "$_KAPSIS_STATUS_INITIALIZED" == "true" ]]
}

# Cleanup status file (for manual cleanup)
status_cleanup() {
    [[ -f "$_KAPSIS_STATUS_FILE" ]] && rm -f "$_KAPSIS_STATUS_FILE"
}

# Re-initialize status from environment (for scripts that run after container)
# This allows post-container-git.sh to continue status updates
status_reinit_from_env() {
    [[ "$KAPSIS_STATUS_ENABLED" != "true" ]] && return 0

    # Check for environment variables set by launch-agent.sh
    if [[ -n "${KAPSIS_STATUS_PROJECT:-}" && -n "${KAPSIS_STATUS_AGENT_ID:-}" ]]; then
        status_init \
            "${KAPSIS_STATUS_PROJECT}" \
            "${KAPSIS_STATUS_AGENT_ID}" \
            "${KAPSIS_STATUS_BRANCH:-}" \
            "${KAPSIS_STATUS_SANDBOX_MODE:-overlay}" \
            "${KAPSIS_STATUS_WORKTREE_PATH:-}"
    fi
}
