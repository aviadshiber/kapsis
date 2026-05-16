#!/usr/bin/env bash
#===============================================================================
# Kapsis - Staged Workflow Launcher (Issue #85)
#
# Orchestrates a multi-stage agent pipeline where each stage runs in an
# isolated container with different network/credential settings, preventing
# the "Lethal Trifecta":
#   no stage holds sensitive credentials + untrusted external content +
#   open network access simultaneously.
#
# Stage data flows forward via a sanitized handoff directory.  Stage 1 commits
# its outputs to a dedicated git branch; the orchestrator extracts declared
# handoff files, sanitizes them, and mounts them read-only into Stage 2.
#
# Usage:
#   ./staged-launch.sh <project-path> --config <yaml> [options]
#
# Options:
#   --config <file>         Workflow config (required; must contain workflow.stages)
#   --no-approval           Skip all approval gates (for CI / non-interactive use)
#   --from-stage <name>     Resume from a named stage (skips earlier stages)
#   --workflow-id <id>      Reuse an existing workflow ID (resume mode)
#   --dry-run               Show what would be executed without running
#
# Exit codes:
#   0   All stages completed successfully
#   1   A stage failed (propagated from launch-agent.sh)
#   7   An approval gate timed out (KAPSIS_EXIT_APPROVAL_TIMEOUT)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/logging.sh"
log_init "staged-launch"

source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/stage-handoff.sh"

#===============================================================================
# DEFAULTS
#===============================================================================

PROJECT_PATH=""
CONFIG_FILE=""
NO_APPROVAL=false
FROM_STAGE=""
WORKFLOW_ID=""
DRY_RUN=false

#===============================================================================
# HELPERS
#===============================================================================

usage() {
    cat >&2 <<EOF
Usage: staged-launch.sh <project-path> --config <yaml> [options]

Options:
  --config <file>       Workflow config (required; must contain workflow.stages)
  --no-approval         Skip all approval gates (CI / non-interactive)
  --from-stage <name>   Resume from a named stage
  --workflow-id <id>    Reuse an existing workflow ID
  --dry-run             Print what would run without executing

Exit codes:
  0  All stages succeeded
  1  A stage failed
  7  An approval gate timed out
EOF
}

# Generate a short identifier (date + 6 random hex chars)
_generate_workflow_id() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local rnd
    if [[ -r /dev/urandom ]] && command -v xxd &>/dev/null; then
        rnd=$(head -c 3 /dev/urandom | xxd -p)
    elif [[ -r /dev/urandom ]]; then
        rnd=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-6)
    else
        rnd=$(printf '%06x' "$(( $(date +%s) % 16777216 ))")
    fi
    echo "${ts}-${rnd}"
}

# Require yq to be present.
_require_yq() {
    if ! command -v yq &>/dev/null; then
        log_error "yq is required by staged-launch.sh but was not found."
        log_error "Install: brew install yq  OR  pip install yq"
        exit 2
    fi
}

# Print a stage-progress banner.
_stage_banner() {
    local idx="$1" total="$2" name="$3" network="$4" no_creds="$5"
    log_info "━━━ Stage $((idx + 1))/$total: $name  [network=$network no_credentials=$no_creds] ━━━"
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    PROJECT_PATH="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --no-approval)
                NO_APPROVAL=true
                shift
                ;;
            --from-stage)
                FROM_STAGE="$2"
                shift 2
                ;;
            --workflow-id)
                WORKFLOW_ID="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "--config is required"
        usage
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    if [[ ! -d "$PROJECT_PATH" ]]; then
        log_error "Project path not found: $PROJECT_PATH"
        exit 1
    fi
}

#===============================================================================
# PER-STAGE CONFIG GENERATION
#===============================================================================

# Build a temporary config file for a given stage index by merging the base
# config with the stage-specific overrides.  The resulting YAML is written to
# output_file and is passed directly to launch-agent.sh --config.
#
# Args: base_config stage_idx workflow_id prev_handoff_dir output_file
generate_stage_config() {
    local base_config="$1"
    local stage_idx="$2"
    local workflow_id="$3"
    local prev_handoff_dir="$4"
    local output_file="$5"

    local stage_prefix=".workflow.stages[$stage_idx]"

    local stage_task stage_network stage_profile no_credentials
    stage_task=$(yq -r "${stage_prefix}.task // \"\"" "$base_config")
    stage_network=$(yq -r "${stage_prefix}.network // \"filtered\"" "$base_config")
    stage_profile=$(yq -r "${stage_prefix}.security_profile // \"standard\"" "$base_config")
    no_credentials=$(yq -r "${stage_prefix}.no_credentials // \"false\"" "$base_config")

    # Strip workflow block from the base config so launch-agent.sh never sees it
    yq 'del(.workflow)' "$base_config" > "$output_file"

    # Override task / agent command for this stage
    if [[ -n "$stage_task" ]]; then
        local cmd="claude --dangerously-skip-permissions -p \"$(printf '%s' "$stage_task" | sed 's/"/\\"/g')\""
        yq -i ".agent.command = \"$cmd\"" "$output_file"
    fi

    # Override security profile
    yq -i ".security_profile = \"$stage_profile\"" "$output_file" 2>/dev/null || true

    # Clear credentials when no_credentials: true
    if [[ "$no_credentials" == "true" ]]; then
        yq -i '.environment.keychain = {}' "$output_file"
        yq -i '.environment.passthrough = []' "$output_file"
        log_debug "Stage config: credentials cleared (no_credentials=true)"
    fi

    # Mount previous stage's handoff directory when one exists
    if [[ -n "$prev_handoff_dir" && -d "$prev_handoff_dir" ]]; then
        # The handoff dir lives under $HOME/.kapsis/handoffs/...
        # generate_filesystem_includes() will stage-and-copy it into the container
        # at the same relative path under /home/developer/.
        yq -i ".filesystem.include += [\"$prev_handoff_dir\"]" "$output_file"

        # Container-side path: replace host $HOME with /home/developer
        local relative_handoff="${prev_handoff_dir#"$HOME/"}"
        local container_handoff="/home/developer/$relative_handoff"
        yq -i ".environment.set.KAPSIS_HANDOFF_PATH = \"$container_handoff\"" "$output_file"

        log_debug "Handoff dir added: $prev_handoff_dir -> $container_handoff"
    fi

    log_debug "Generated stage config: $output_file (network=$stage_network)"
}

#===============================================================================
# MAIN WORKFLOW LOOP
#===============================================================================

run_staged_workflow() {
    _require_yq

    local handoffs_base="${KAPSIS_HANDOFFS_DIR:-${KAPSIS_DEFAULT_HANDOFFS_DIR}}"
    local wf_id="${WORKFLOW_ID:-$(_generate_workflow_id)}"
    local wf_dir="${handoffs_base}/${wf_id}"

    local stage_count
    stage_count=$(yq '.workflow.stages | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

    if [[ "$stage_count" -eq 0 ]]; then
        log_error "No stages defined under workflow.stages in $CONFIG_FILE"
        exit 1
    fi

    log_info "Starting workflow $wf_id  ($stage_count stage(s))"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] No containers will be started"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$wf_dir"
    fi

    local prev_handoff_dir=""
    local prev_branch=""
    local skip_until_stage="$FROM_STAGE"
    local stage_idx=0

    while [[ "$stage_idx" -lt "$stage_count" ]]; do
        local stage_name stage_network no_credentials approval_type approval_timeout
        local handoff_include_raw

        stage_name=$(yq -r ".workflow.stages[$stage_idx].name" "$CONFIG_FILE")
        stage_network=$(yq -r ".workflow.stages[$stage_idx].network // \"filtered\"" "$CONFIG_FILE")
        no_credentials=$(yq -r ".workflow.stages[$stage_idx].no_credentials // \"false\"" "$CONFIG_FILE")
        approval_type=$(yq -r ".workflow.stages[$stage_idx].approval.type // \"none\"" "$CONFIG_FILE")
        approval_timeout=$(yq -r ".workflow.stages[$stage_idx].approval.timeout // $KAPSIS_DEFAULT_STAGE_APPROVAL_TIMEOUT" "$CONFIG_FILE")
        handoff_include_raw=$(yq -r ".workflow.stages[$stage_idx].handoff.include // [] | .[]" "$CONFIG_FILE" 2>/dev/null || true)

        # --from-stage resume: skip stages before the named one
        if [[ -n "$skip_until_stage" ]]; then
            if [[ "$stage_name" != "$skip_until_stage" ]]; then
                log_info "Skipping stage '$stage_name' (--from-stage=$skip_until_stage)"
                ((stage_idx++)) || true
                continue
            else
                skip_until_stage=""
            fi
        fi

        _stage_banner "$stage_idx" "$stage_count" "$stage_name" "$stage_network" "$no_credentials"

        # Generate per-stage config
        local stage_config_file
        stage_config_file="${wf_dir}/${stage_name}-config.yaml"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would generate config: $stage_config_file"
        else
            generate_stage_config "$CONFIG_FILE" "$stage_idx" "$wf_id" \
                "$prev_handoff_dir" "$stage_config_file"

            # Security contract enforcement
            validate_stage_security \
                "$stage_name" "$no_credentials" "$stage_network" "$stage_config_file" \
                || exit 1
        fi

        # Build branch name for this stage
        local stage_branch="workflow-${wf_id}-${stage_name}"

        # Launch the stage
        local launch_exit=0
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would run: launch-agent.sh '$PROJECT_PATH'" \
                     "--config '$stage_config_file' --branch '$stage_branch'" \
                     "--network-mode '$stage_network'"
        else
            log_info "Launching stage '$stage_name' on branch '$stage_branch'..."
            "$SCRIPT_DIR/launch-agent.sh" "$PROJECT_PATH" \
                --config "$stage_config_file" \
                --branch "$stage_branch" \
                --network-mode "$stage_network" \
                || launch_exit=$?

            write_stage_manifest \
                "$handoffs_base" "$wf_id" "$stage_name" \
                "$stage_branch" "$launch_exit" "${wf_dir}/${stage_name}-handoff"

            if [[ "$launch_exit" -ne 0 ]]; then
                log_error "Stage '$stage_name' exited with code $launch_exit"
                log_error "Workflow $wf_id aborted at stage '$stage_name'."
                log_error "Previous stage branch: ${prev_branch:-none}"
                log_error "Stage branch: $stage_branch"
                log_error "Handoff artifacts: $wf_dir"
                exit "$launch_exit"
            fi
        fi

        # Extract handoff files from the committed branch
        local stage_handoff_dir="${wf_dir}/${stage_name}-handoff"

        if [[ -n "$handoff_include_raw" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would extract handoff files from branch '$stage_branch'"
            else
                log_info "Extracting handoff files from '$stage_branch'..."
                extract_handoff_files \
                    "$PROJECT_PATH" "$stage_branch" "$handoff_include_raw" \
                    "$stage_handoff_dir"

                log_info "Sanitizing handoff files..."
                sanitize_handoff_dir "$stage_handoff_dir"

                local file_count
                file_count=$(find "$stage_handoff_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                log_info "Handoff: $file_count file(s) ready for next stage at $stage_handoff_dir"
            fi
        fi

        # Approval gate (skip when --no-approval or type is "none")
        if [[ "$approval_type" == "blocking" && "$NO_APPROVAL" == "false" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would wait for approval at stage '$stage_name'"
            else
                wait_for_stage_approval \
                    "$handoffs_base" "$wf_id" "$stage_name" "$approval_timeout" \
                    || exit $?
            fi
        elif [[ "$approval_type" == "blocking" && "$NO_APPROVAL" == "true" ]]; then
            log_info "Skipping approval gate for stage '$stage_name' (--no-approval)"
        fi

        prev_branch="$stage_branch"
        prev_handoff_dir="$stage_handoff_dir"
        ((stage_idx++)) || true
    done

    log_success "Workflow $wf_id completed all $stage_count stage(s)."
    log_success "Artifacts: $wf_dir"
}

#===============================================================================
# ENTRY POINT
#===============================================================================

parse_args "$@"
run_staged_workflow
