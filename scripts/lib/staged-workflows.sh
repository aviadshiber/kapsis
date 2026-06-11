#!/usr/bin/env bash
#===============================================================================
# Kapsis - Staged Workflows Library (Issue #85 / Phase 4)
#
# Implements the "Lethal Trifecta" mitigation by decomposing agent workflows
# into stages where no single stage has all three risk factors simultaneously:
#
#   1. Sensitive Data     — credentials, source code
#   2. Untrusted Content  — web pages, external API responses
#   3. External Comms     — outbound network access
#
# Stage layout (default):
#
#   research       : Untrusted Content + External Comms  (no credentials)
#   implementation : Sensitive Data only                  (no network)
#   publish        : External Comms only                  (limited credentials)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/staged-workflows.sh"
#   stage_load_config  "$CONFIG_FILE"
#   stage_apply_config "$STAGE_NAME"   # mutates NETWORK_MODE, KAPSIS_SECURITY_PROFILE, etc.
#   stage_check_approval_gate "$PREV_STAGE" "$CURRENT_STAGE" "$AGENT_ID"
#   stage_write_handoff "$STAGE_NAME"  "$AGENT_ID" "$WORKTREE_PATH" "$SUMMARY"
#   stage_read_handoff  "$STAGE_NAME"  "$AGENT_ID"
#===============================================================================

set -euo pipefail

[[ -n "${_KAPSIS_STAGED_WORKFLOWS_LOADED:-}" ]] && return 0
readonly _KAPSIS_STAGED_WORKFLOWS_LOADED=1

# Source dependencies if not already loaded
_SW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SW_LIB_DIR/logging.sh"
source "$_SW_LIB_DIR/constants.sh"
source "$_SW_LIB_DIR/sanitize-files.sh"

#===============================================================================
# CONSTANTS
#===============================================================================

# Directory where stage handoff files are stored (overrideable via env for testing)
: "${KAPSIS_HANDOFF_DIR:=${HOME}/.kapsis/handoffs}"

# Valid stage names built into Kapsis (users can define custom ones in YAML)
readonly KAPSIS_BUILTIN_STAGES="research implementation publish"

# Approval policy names supported natively
readonly KAPSIS_APPROVAL_POLICIES_LIST="small_changes docs_only tests_only always"

# Thresholds for the 'small_changes' approval policy
readonly KAPSIS_APPROVAL_SMALL_FILES=5
readonly KAPSIS_APPROVAL_SMALL_LINES=100

#===============================================================================
# STATE (populated by stage_load_config)
#===============================================================================

# Parsed stage definitions — indexed by stage name.
# Each entry is a colon-delimited record: name:network_mode:security_profile:credentials
# Stored as parallel arrays for Bash 3.2 compatibility.
_SW_STAGE_NAMES=()
_SW_STAGE_NETWORK_MODES=()
_SW_STAGE_SECURITY_PROFILES=()
_SW_STAGE_CREDENTIALS=()        # comma-separated list of credential var names
_SW_STAGE_NETWORK_OVERRIDES=()  # comma-separated extra allowlist hosts for this stage

# Approval configuration
_SW_APPROVAL_POLICIES=()        # auto-approve policies
_SW_APPROVAL_REQUIRE_MANUAL=""  # "true" = always require human confirmation
_SW_APPROVAL_GATE_SCRIPT=""     # path to custom gate script

# Whether a config has been loaded
_SW_CONFIG_LOADED=false

#===============================================================================
# HELPERS
#===============================================================================

# Return the index of a stage name in _SW_STAGE_NAMES, or -1 if not found.
_sw_stage_index() {
    local name="$1"
    local i
    for i in "${!_SW_STAGE_NAMES[@]}"; do
        [[ "${_SW_STAGE_NAMES[$i]}" == "$name" ]] && echo "$i" && return 0
    done
    echo "-1"
}

# Validate that a stage name is known.
_sw_validate_stage_name() {
    local name="$1"
    local idx
    idx=$(_sw_stage_index "$name")
    if [[ "$idx" == "-1" ]]; then
        log_error "Unknown stage: '$name'. Defined stages: ${_SW_STAGE_NAMES[*]:-none}"
        return 1
    fi
    return 0
}

# Write a JSON field to a handoff file builder variable.
# Usage: _sw_json_field KEY VALUE [TYPE]
# TYPE: "string" (default), "number", "bool", "raw"
_sw_json_field() {
    local key="$1"
    local value="$2"
    local type="${3:-string}"

    case "$type" in
        number|bool|raw)
            printf '  "%s": %s' "$key" "$value"
            ;;
        *)
            # Escape double quotes and backslashes
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"
            printf '  "%s": "%s"' "$key" "$value"
            ;;
    esac
}

#===============================================================================
# CONFIG LOADING
#===============================================================================

# Load stage definitions from the kapsis config YAML.
# Populates _SW_STAGE_* parallel arrays and approval settings.
#
# Arguments:
#   $1 - Path to agent-sandbox.yaml
#
# Returns:
#   0 on success (stages found or defaults applied)
#   1 on config parse error
stage_load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_debug "staged-workflows: config file not found, built-in defaults apply"
        _sw_load_builtin_defaults
        _SW_CONFIG_LOADED=true
        return 0
    fi

    if ! command -v yq &>/dev/null; then
        log_debug "staged-workflows: yq not available, built-in defaults apply"
        _sw_load_builtin_defaults
        _SW_CONFIG_LOADED=true
        return 0
    fi

    local stage_count
    stage_count=$(yq -r '.workflow.stages | length // 0' "$config_file" 2>/dev/null || echo "0")

    if [[ "$stage_count" -eq 0 ]]; then
        log_debug "staged-workflows: no stages defined in config, built-in defaults apply"
        _sw_load_builtin_defaults
        _SW_CONFIG_LOADED=true
        return 0
    fi

    log_debug "staged-workflows: loading $stage_count stage(s) from $config_file"

    # Reset arrays
    _SW_STAGE_NAMES=()
    _SW_STAGE_NETWORK_MODES=()
    _SW_STAGE_SECURITY_PROFILES=()
    _SW_STAGE_CREDENTIALS=()
    _SW_STAGE_NETWORK_OVERRIDES=()

    local i
    for i in $(seq 0 $((stage_count - 1))); do
        local name network_mode security_profile credentials net_override
        name=$(yq -r ".workflow.stages[$i].name // \"\"" "$config_file" 2>/dev/null || echo "")
        if [[ -z "$name" ]]; then
            log_warn "staged-workflows: stage[$i] has no name, skipping"
            continue
        fi

        network_mode=$(yq -r ".workflow.stages[$i].network_mode // \"filtered\"" "$config_file" 2>/dev/null || echo "filtered")
        security_profile=$(yq -r ".workflow.stages[$i].security_profile // \"standard\"" "$config_file" 2>/dev/null || echo "standard")

        # credentials: comma-join array or empty
        credentials=$(yq -r ".workflow.stages[$i].credentials // [] | join(\",\")" "$config_file" 2>/dev/null || echo "")

        # network_allowlist_override: comma-join array of extra hosts
        net_override=$(yq -r ".workflow.stages[$i].network_allowlist_override // [] | join(\",\")" "$config_file" 2>/dev/null || echo "")

        _SW_STAGE_NAMES+=("$name")
        _SW_STAGE_NETWORK_MODES+=("$network_mode")
        _SW_STAGE_SECURITY_PROFILES+=("$security_profile")
        _SW_STAGE_CREDENTIALS+=("$credentials")
        _SW_STAGE_NETWORK_OVERRIDES+=("$net_override")

        log_debug "staged-workflows: loaded stage '$name' (network=$network_mode, security=$security_profile)"
    done

    # Load approval config
    _SW_APPROVAL_REQUIRE_MANUAL=$(yq -r '.workflow.approval.require_manual // "false"' "$config_file" 2>/dev/null || echo "false")
    _SW_APPROVAL_GATE_SCRIPT=$(yq -r '.workflow.approval.gate_script // ""' "$config_file" 2>/dev/null || echo "")

    local policy_count
    policy_count=$(yq -r '.workflow.approval.auto_approve | length // 0' "$config_file" 2>/dev/null || echo "0")
    _SW_APPROVAL_POLICIES=()
    if [[ "$policy_count" -gt 0 ]]; then
        local j
        for j in $(seq 0 $((policy_count - 1))); do
            local policy
            policy=$(yq -r ".workflow.approval.auto_approve[$j].policy // \"\"" "$config_file" 2>/dev/null || echo "")
            [[ -n "$policy" ]] && _SW_APPROVAL_POLICIES+=("$policy")
        done
    fi

    _SW_CONFIG_LOADED=true
    log_debug "staged-workflows: config loaded (${#_SW_STAGE_NAMES[@]} stages, ${#_SW_APPROVAL_POLICIES[@]} auto-approve policies)"
}

# Populate built-in stage defaults when no workflow.stages section exists.
_sw_load_builtin_defaults() {
    _SW_STAGE_NAMES=(     "research"  "implementation"  "publish"  )
    _SW_STAGE_NETWORK_MODES=(  "filtered"  "none"       "filtered" )
    _SW_STAGE_SECURITY_PROFILES=( "minimal"   "strict"     "standard" )
    _SW_STAGE_CREDENTIALS=(   ""          ""           ""         )
    _SW_STAGE_NETWORK_OVERRIDES=( ""        ""           ""         )
    _SW_APPROVAL_POLICIES=("small_changes")
    _SW_APPROVAL_REQUIRE_MANUAL="false"
    _SW_APPROVAL_GATE_SCRIPT=""
}

#===============================================================================
# STAGE APPLICATION
#===============================================================================

# Apply stage-specific isolation config to the running environment.
# Mutates NETWORK_MODE, KAPSIS_SECURITY_PROFILE, and ENV_KEYCHAIN so that
# the container launched by launch-agent.sh respects the stage's risk posture.
#
# Arguments:
#   $1 - Stage name (e.g. "research", "implementation", "publish")
#   $2 - Full ENV_KEYCHAIN string (pipe-delimited lines)
#
# Exports:
#   NETWORK_MODE              - overridden per stage
#   KAPSIS_SECURITY_PROFILE   - overridden per stage
#   KAPSIS_CURRENT_STAGE      - visible to agent inside container
#   KAPSIS_STAGE_CREDENTIALS  - comma-separated list of allowed credential names
#   KAPSIS_STAGE_NET_OVERRIDE - extra allowlist hosts for this stage
#
# Prints:
#   The filtered ENV_KEYCHAIN string (caller should capture via $())
stage_apply_config() {
    local stage_name="$1"
    local env_keychain="${2:-}"

    [[ "$_SW_CONFIG_LOADED" != "true" ]] && {
        log_warn "staged-workflows: stage_load_config() not called; applying defaults"
        _sw_load_builtin_defaults
        _SW_CONFIG_LOADED=true
    }

    if ! _sw_validate_stage_name "$stage_name"; then
        return 1
    fi

    local idx
    idx=$(_sw_stage_index "$stage_name")

    NETWORK_MODE="${_SW_STAGE_NETWORK_MODES[$idx]}"
    export KAPSIS_SECURITY_PROFILE="${_SW_STAGE_SECURITY_PROFILES[$idx]}"
    export KAPSIS_CURRENT_STAGE="$stage_name"
    export KAPSIS_STAGE_CREDENTIALS="${_SW_STAGE_CREDENTIALS[$idx]}"
    export KAPSIS_STAGE_NET_OVERRIDE="${_SW_STAGE_NETWORK_OVERRIDES[$idx]}"

    log_info "staged-workflows: stage '$stage_name' → network=$NETWORK_MODE, security=$KAPSIS_SECURITY_PROFILE"

    # Filter ENV_KEYCHAIN to only emit credential entries allowed for this stage.
    # When credentials list is empty string, no filtering is applied (all pass through).
    local allowed_creds="${_SW_STAGE_CREDENTIALS[$idx]}"
    if [[ -z "$allowed_creds" ]]; then
        # Empty list = no filtering; pass entire keychain through
        printf '%s' "$env_keychain"
        return 0
    fi

    # Filter: only keep lines whose VAR_NAME appears in the allowed list
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local var_name
        var_name="${line%%|*}"
        if _sw_credential_is_allowed "$var_name" "$allowed_creds"; then
            printf '%s\n' "$line"
        else
            log_debug "staged-workflows: credential '$var_name' suppressed for stage '$stage_name'"
        fi
    done <<< "$env_keychain"
}

# Check whether a credential variable name is in the allowed comma-separated list.
_sw_credential_is_allowed() {
    local var_name="$1"
    local allowed_list="$2"   # comma-separated

    local cred
    IFS=',' read -ra _creds <<< "$allowed_list"
    for cred in "${_creds[@]}"; do
        [[ "$cred" == "$var_name" ]] && return 0
    done
    return 1
}

#===============================================================================
# APPROVAL GATES
#===============================================================================

# Check whether a stage transition is approved.
# Exit codes:
#   0 = approved (transition may proceed)
#   1 = denied   (transition blocked)
#   2 = pending  (gate deferred to human — interactive prompt shown)
#
# Arguments:
#   $1 - Handoff dir where previous stage output lives (may be empty)
#   $2 - Previous stage name (may be empty for first stage)
#   $3 - Current (target) stage name
#   $4 - Agent ID (for handoff lookup)
stage_check_approval_gate() {
    local handoff_dir="${1:-$KAPSIS_HANDOFF_DIR}"
    local prev_stage="${2:-}"
    local current_stage="$3"
    local agent_id="$4"

    # No previous stage = no gate needed
    [[ -z "$prev_stage" ]] && return 0

    # Require manual always takes precedence
    if [[ "$_SW_APPROVAL_REQUIRE_MANUAL" == "true" ]]; then
        log_warn "staged-workflows: manual approval required before entering stage '$current_stage'"
        _sw_interactive_approval "$prev_stage" "$current_stage" "$agent_id" "$handoff_dir"
        return $?
    fi

    # Run custom gate script if configured
    if [[ -n "$_SW_APPROVAL_GATE_SCRIPT" && -x "$_SW_APPROVAL_GATE_SCRIPT" ]]; then
        log_debug "staged-workflows: running custom gate script: $_SW_APPROVAL_GATE_SCRIPT"
        if "$_SW_APPROVAL_GATE_SCRIPT" "$prev_stage" "$current_stage" "$agent_id" "$handoff_dir"; then
            log_info "staged-workflows: gate script approved transition $prev_stage → $current_stage"
            return 0
        else
            local gate_rc=$?
            if [[ "$gate_rc" -eq 2 ]]; then
                _sw_interactive_approval "$prev_stage" "$current_stage" "$agent_id" "$handoff_dir"
                return $?
            fi
            log_error "staged-workflows: gate script denied transition $prev_stage → $current_stage"
            return 1
        fi
    fi

    # Try auto-approve policies
    local policy
    for policy in "${_SW_APPROVAL_POLICIES[@]:-}"; do
        if _sw_check_policy "$policy" "$prev_stage" "$agent_id" "$handoff_dir"; then
            log_info "staged-workflows: auto-approved transition $prev_stage → $current_stage (policy: $policy)"
            return 0
        fi
    done

    # No auto-approve policy matched; require interactive confirmation
    if [[ -t 0 ]]; then
        _sw_interactive_approval "$prev_stage" "$current_stage" "$agent_id" "$handoff_dir"
        return $?
    fi

    # Non-interactive context — deny by default (safe default)
    log_warn "staged-workflows: no approval policy matched and no TTY; transition $prev_stage → $current_stage blocked"
    log_warn "  Re-run with a TTY to approve interactively, or set a matching auto_approve policy."
    return 1
}

# Check a named approval policy against the previous stage's handoff.
_sw_check_policy() {
    local policy="$1"
    local prev_stage="$2"
    local agent_id="$3"
    local handoff_dir="$4"

    local handoff_file="${handoff_dir}/kapsis-${agent_id}-${prev_stage}.json"

    case "$policy" in
        small_changes)
            [[ -f "$handoff_file" ]] || return 1
            local files lines
            files=$(python3 -c "import json,sys; d=json.load(open('$handoff_file')); print(len(d.get('output_files',[])))" 2>/dev/null || echo "999")
            lines=$(python3 -c "import json,sys; d=json.load(open('$handoff_file')); print(d.get('lines_changed',999))" 2>/dev/null || echo "999")
            [[ "$files" -le "$KAPSIS_APPROVAL_SMALL_FILES" && "$lines" -le "$KAPSIS_APPROVAL_SMALL_LINES" ]]
            ;;
        docs_only)
            [[ -f "$handoff_file" ]] || return 1
            local non_doc
            non_doc=$(python3 -c "
import json, re, sys
d = json.load(open('$handoff_file'))
files = [f['path'] for f in d.get('output_files', [])]
non_doc = [f for f in files if not re.search(r'\.(md|rst|txt|adoc|html|pdf)$', f, re.I)]
print(len(non_doc))
" 2>/dev/null || echo "999")
            [[ "$non_doc" -eq 0 ]]
            ;;
        tests_only)
            [[ -f "$handoff_file" ]] || return 1
            local non_test
            non_test=$(python3 -c "
import json, re, sys
d = json.load(open('$handoff_file'))
files = [f['path'] for f in d.get('output_files', [])]
non_test = [f for f in files if not re.search(r'(test|spec)[^/]*\.(java|py|js|ts|go|rb|sh|bash)$', f, re.I)]
print(len(non_test))
" 2>/dev/null || echo "999")
            [[ "$non_test" -eq 0 ]]
            ;;
        always)
            # Always auto-approve (use with caution)
            return 0
            ;;
        *)
            log_warn "staged-workflows: unknown approval policy '$policy'"
            return 1
            ;;
    esac
}

# Interactive TTY approval prompt.
_sw_interactive_approval() {
    local prev_stage="$1"
    local current_stage="$2"
    local agent_id="$3"
    local handoff_dir="$4"

    local handoff_file="${handoff_dir}/kapsis-${agent_id}-${prev_stage}.json"

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│  Kapsis Stage Transition Approval Gate              │"
    echo "└─────────────────────────────────────────────────────┘"
    echo "  Agent:    $agent_id"
    echo "  From:     $prev_stage"
    echo "  To:       $current_stage"

    if [[ -f "$handoff_file" ]]; then
        echo ""
        echo "  Handoff summary:"
        python3 -c "
import json, sys
try:
    d = json.load(open('$handoff_file'))
    print('    Files changed : ' + str(len(d.get('output_files', []))))
    print('    Lines changed : ' + str(d.get('lines_changed', 'unknown')))
    summary = d.get('summary', '')
    if summary:
        # Wrap at 60 chars
        import textwrap
        for line in textwrap.wrap('Summary: ' + summary, 60):
            print('    ' + line)
except Exception as e:
    print('    (could not read handoff: ' + str(e) + ')')
" 2>/dev/null || echo "    (handoff file not readable)"
    fi

    echo ""
    printf "  Approve transition? [y/N]: "
    local answer
    read -r answer </dev/tty
    case "$answer" in
        y|Y|yes|YES)
            log_info "staged-workflows: operator approved transition $prev_stage → $current_stage"
            return 0
            ;;
        *)
            log_warn "staged-workflows: operator denied transition $prev_stage → $current_stage"
            return 1
            ;;
    esac
}

#===============================================================================
# HANDOFF MANAGEMENT
#===============================================================================

# Write a stage handoff JSON file recording the stage's outputs and metadata.
# This file is read by the next stage's approval gate and appended to the
# container environment as KAPSIS_PREV_STAGE_HANDOFF.
#
# Arguments:
#   $1 - Stage name
#   $2 - Agent ID
#   $3 - Worktree path (for computing changed files)
#   $4 - Summary message (free text, agent-provided or auto-generated)
#   $5 - (optional) Additional metadata JSON object string, e.g. '{"api_calls": 12}'
stage_write_handoff() {
    local stage_name="$1"
    local agent_id="$2"
    local worktree_path="${3:-}"
    local summary="${4:-}"
    local extra_meta="${5:-{}}"

    mkdir -p "$KAPSIS_HANDOFF_DIR"

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-${agent_id}-${stage_name}.json"
    local completed_at
    completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    # Compute changed files from worktree if available
    local files_json="[]"
    local lines_changed=0
    if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
        files_json=$(_sw_compute_changed_files "$worktree_path")
        lines_changed=$(_sw_compute_lines_changed "$worktree_path")
    fi

    # Sanitize summary to avoid JSON injection
    summary="${summary//\\/\\\\}"
    summary="${summary//\"/\\\"}"
    summary="${summary//$'\n'/\\n}"

    cat > "$handoff_file" << EOF
{
  "schema_version": "1.0",
  "stage": "$stage_name",
  "agent_id": "$agent_id",
  "completed_at": "$completed_at",
  "summary": "$summary",
  "output_files": $files_json,
  "lines_changed": $lines_changed,
  "metadata": $extra_meta
}
EOF

    log_debug "staged-workflows: handoff written to $handoff_file"
    echo "$handoff_file"
}

# Read and print the handoff file from the previous stage.
# Arguments:
#   $1 - Stage name to read
#   $2 - Agent ID
stage_read_handoff() {
    local stage_name="$1"
    local agent_id="$2"

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-${agent_id}-${stage_name}.json"

    if [[ ! -f "$handoff_file" ]]; then
        log_debug "staged-workflows: no handoff found for stage '$stage_name', agent '$agent_id'"
        return 1
    fi

    cat "$handoff_file"
}

# Sanitize a handoff file, stripping dangerous Unicode sequences that could
# smuggle malicious content from an untrusted stage (e.g. research) into a
# trusted one (e.g. implementation).
#
# Calls the individual sanitize-files.sh stripping functions directly on the
# file rather than sanitize_staged_files() (which requires a git worktree).
# Host-side execution only — never call this from inside a container.
#
# Arguments:
#   $1 - Stage name
#   $2 - Agent ID
stage_sanitize_handoff() {
    local stage_name="$1"
    local agent_id="$2"

    local handoff_file="${KAPSIS_HANDOFF_DIR}/kapsis-${agent_id}-${stage_name}.json"

    if [[ ! -f "$handoff_file" ]]; then
        log_debug "staged-workflows: no handoff to sanitize for stage '$stage_name'"
        return 0
    fi

    log_debug "staged-workflows: sanitizing handoff from stage '$stage_name'"

    local bidi_removed zw_removed
    bidi_removed=$(_sanitize_strip_bidi "$handoff_file" 2>/dev/null || echo 0)
    zw_removed=$(_sanitize_strip_zero_width "$handoff_file" 2>/dev/null || echo 0)

    local total_removed=$(( ${bidi_removed:-0} + ${zw_removed:-0} ))
    if [[ "$total_removed" -gt 0 ]]; then
        log_warn "staged-workflows: removed $total_removed dangerous Unicode chars from handoff (BiDi=$bidi_removed, ZW=$zw_removed)"
    else
        log_debug "staged-workflows: handoff sanitization complete (no dangerous chars found)"
    fi
}

#===============================================================================
# INTERNAL HELPERS FOR HANDOFF COMPUTATION
#===============================================================================

# Compute a JSON array of changed files in the worktree relative to HEAD.
_sw_compute_changed_files() {
    local worktree="$1"
    local files_json="["
    local first=true

    local file
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        # Sanitize path for JSON embedding
        file="${file//\\/\\\\}"
        file="${file//\"/\\\"}"

        if [[ "$first" == "true" ]]; then
            files_json+="\"$file\""
            first=false
        else
            files_json+=", \"$file\""
        fi
    done < <(git -C "$worktree" diff --name-only HEAD 2>/dev/null | head -100 || true)

    files_json+="]"
    # Transform to array of objects with path key for richer metadata
    # We use a simple approach: convert ["a","b"] → [{"path":"a"},{"path":"b"}]
    echo "$files_json" | python3 -c "
import json, sys
paths = json.load(sys.stdin)
print(json.dumps([{'path': p} for p in paths]))
" 2>/dev/null || echo "[]"
}

# Count total lines changed (insertions + deletions) in the worktree.
_sw_compute_lines_changed() {
    local worktree="$1"
    local total=0

    local insertions deletions
    insertions=$(git -C "$worktree" diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
    deletions=$(git -C  "$worktree" diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' || echo "0")

    total=$(( ${insertions:-0} + ${deletions:-0} ))
    echo "$total"
}

#===============================================================================
# PUBLIC UTILITY
#===============================================================================

# Print a human-readable summary of the current stage configuration.
stage_print_summary() {
    local stage_name="${1:-all}"

    if [[ "$stage_name" == "all" ]]; then
        echo "Staged workflow configuration:"
        echo "  Stages: ${_SW_STAGE_NAMES[*]:-none}"
        local i
        for i in "${!_SW_STAGE_NAMES[@]}"; do
            echo "  [${_SW_STAGE_NAMES[$i]}]"
            echo "    network_mode     : ${_SW_STAGE_NETWORK_MODES[$i]}"
            echo "    security_profile : ${_SW_STAGE_SECURITY_PROFILES[$i]}"
            echo "    credentials      : ${_SW_STAGE_CREDENTIALS[$i]:-<all>}"
            echo "    net_override     : ${_SW_STAGE_NETWORK_OVERRIDES[$i]:-<none>}"
        done
        echo "  Approval:"
        echo "    require_manual  : $_SW_APPROVAL_REQUIRE_MANUAL"
        echo "    auto policies   : ${_SW_APPROVAL_POLICIES[*]:-none}"
        echo "    gate_script     : ${_SW_APPROVAL_GATE_SCRIPT:-<none>}"
    else
        _sw_validate_stage_name "$stage_name" || return 1
        local idx
        idx=$(_sw_stage_index "$stage_name")
        echo "Stage: $stage_name"
        echo "  network_mode     : ${_SW_STAGE_NETWORK_MODES[$idx]}"
        echo "  security_profile : ${_SW_STAGE_SECURITY_PROFILES[$idx]}"
        echo "  credentials      : ${_SW_STAGE_CREDENTIALS[$idx]:-<all>}"
        echo "  net_override     : ${_SW_STAGE_NETWORK_OVERRIDES[$idx]:-<none>}"
    fi
}

# Return the list of defined stage names (space-separated).
stage_list() {
    echo "${_SW_STAGE_NAMES[*]:-}"
}

# Export KAPSIS_PREV_STAGE_HANDOFF env var for the container.
# Reads the handoff for $prev_stage, sanitizes it, base64-encodes it,
# and sets the env var so the agent can inspect what the previous stage produced.
#
# Arguments:
#   $1 - Previous stage name
#   $2 - Agent ID
stage_export_handoff_env() {
    local prev_stage="$1"
    local agent_id="$2"

    [[ -z "$prev_stage" ]] && return 0

    # Sanitize before exposing to the next stage
    stage_sanitize_handoff "$prev_stage" "$agent_id"

    local handoff_content
    if handoff_content=$(stage_read_handoff "$prev_stage" "$agent_id" 2>/dev/null); then
        # Base64-encode to avoid shell escaping issues across container boundary
        local encoded
        encoded=$(printf '%s' "$handoff_content" | base64 | tr -d '\n')
        export KAPSIS_PREV_STAGE_HANDOFF="$encoded"
        log_debug "staged-workflows: exported KAPSIS_PREV_STAGE_HANDOFF (${#handoff_content} bytes)"
    fi
}
