#!/usr/bin/env bash
#===============================================================================
# Kapsis - Pre-Flight Validation Script
#
# Validates all prerequisites before launching a Kapsis agent.
# Called automatically by launch-agent.sh when using --branch flag.
#
# Exit codes:
#   0 - All checks pass
#   1 - Critical failure (blocks launch)
#   2 - Warnings only (can proceed)
#
# Usage:
#   source preflight-check.sh
#   preflight_check <project_path> <target_branch> [spec_file]
#===============================================================================

set -euo pipefail

# Script directory
PREFLIGHT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging library (only if not already loaded)
if [[ -z "${_KAPSIS_LOGGING_LOADED:-}" ]]; then
    source "$PREFLIGHT_SCRIPT_DIR/lib/logging.sh"
    log_init "preflight-check"
fi

# Source cross-platform compatibility helpers (only if not already loaded)
if [[ -z "${_KAPSIS_COMPAT_LOADED:-}" ]] && [[ -f "$PREFLIGHT_SCRIPT_DIR/lib/compat.sh" ]]; then
    source "$PREFLIGHT_SCRIPT_DIR/lib/compat.sh"
fi

# Source constants (only if not already loaded — provides SSH probe defaults)
if [[ -z "${_KAPSIS_CONSTANTS_LOADED:-}" ]] && [[ -f "$PREFLIGHT_SCRIPT_DIR/lib/constants.sh" ]]; then
    source "$PREFLIGHT_SCRIPT_DIR/lib/constants.sh"
fi

#===============================================================================
# PREFLIGHT CHECK RESULTS
#===============================================================================
_PREFLIGHT_ERRORS=0
_PREFLIGHT_WARNINGS=0

preflight_error() {
    log_error "$1"
    ((_PREFLIGHT_ERRORS++)) || true
}

preflight_warn() {
    log_warn "$1"
    ((_PREFLIGHT_WARNINGS++)) || true
}

preflight_ok() {
    log_success "$1"
}

#===============================================================================
# INDIVIDUAL CHECKS
#===============================================================================

# Check if Podman is available and machine is running
check_podman() {
    log_info "Checking Podman..."

    if ! command -v podman &>/dev/null; then
        preflight_error "Podman is not installed or not in PATH"
        return 1
    fi

    if ! podman machine inspect podman-machine-default &>/dev/null; then
        preflight_error "Podman machine 'podman-machine-default' not found"
        preflight_error "  Run: podman machine init"
        return 1
    fi

    local machine_state
    machine_state=$(podman machine inspect podman-machine-default --format '{{.State}}' 2>/dev/null || echo "unknown")

    if [[ "$machine_state" != "running" ]]; then
        preflight_error "Podman machine is not running (state: $machine_state)"
        preflight_error "  Run: podman machine start"
        return 1
    fi

    preflight_ok "Podman machine is running"

    # Verify SSH tunnel is functional (macOS only — Issue #255)
    # After reboot/sleep, machine reports "running" but SSH tunnel may be dead.
    if ! is_linux && declare -f _recover_podman_ssh_tunnel &>/dev/null; then
        local probe_timeout="${KAPSIS_PREFLIGHT_SSH_PROBE_TIMEOUT:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_PROBE_TIMEOUT:-10}}"
        local max_retries="${KAPSIS_PREFLIGHT_SSH_RECOVERY_RETRIES:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_RETRIES:-2}}"
        local retry_delay="${KAPSIS_PREFLIGHT_SSH_RECOVERY_DELAY:-${KAPSIS_DEFAULT_PREFLIGHT_SSH_RECOVERY_DELAY:-3}}"

        log_info "Verifying Podman SSH tunnel..."

        if _recover_podman_ssh_tunnel "$probe_timeout" "$max_retries" "$retry_delay"; then
            if [[ "${KAPSIS_SSH_PROBE_PASSED:-}" == "1" ]]; then
                preflight_ok "Podman SSH tunnel is functional"
            fi
        else
            # preflight_error does not return non-zero; explicit return required
            preflight_error "Podman SSH tunnel is broken — run: podman machine stop && podman machine start"
            return 1
        fi
    fi

    return 0
}

# Check if Kapsis images are available
check_images() {
    local image_name="${1:-kapsis-sandbox:latest}"

    log_info "Checking Kapsis image: $image_name"

    if ! podman image exists "$image_name" 2>/dev/null; then
        preflight_error "Kapsis image not found: $image_name"
        preflight_error "  Run: ~/git/kapsis/scripts/build-image.sh"
        if [[ "$image_name" == *"claude"* ]]; then
            preflight_error "  Then: ~/git/kapsis/scripts/build-agent-image.sh claude-cli"
        fi
        return 1
    fi

    preflight_ok "Image available: $image_name"
    return 0
}

# Check git status (clean working tree)
check_git_status() {
    local project_path="$1"

    log_info "Checking git status..."

    if [[ ! -d "$project_path/.git" ]]; then
        preflight_error "Not a git repository: $project_path"
        return 1
    fi

    cd "$project_path"

    local status
    status=$(git status --porcelain 2>/dev/null || echo "ERROR")

    if [[ "$status" == "ERROR" ]]; then
        preflight_error "Failed to check git status in $project_path"
        return 1
    fi

    if [[ -n "$status" ]]; then
        local change_count
        change_count=$(echo "$status" | wc -l | tr -d ' ')
        preflight_warn "Git working tree has $change_count uncommitted change(s)"
        preflight_warn "  Consider: git stash or git commit"
        # This is a warning, not an error - worktree still works
        return 0
    fi

    preflight_ok "Git working tree is clean"
    return 0
}

# CRITICAL: Check if main repo is on the target branch
check_branch_conflict() {
    local project_path="$1"
    local target_branch="$2"

    log_info "Checking for branch conflict..."

    cd "$project_path"

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -z "$current_branch" ]]; then
        preflight_error "Could not determine current branch in $project_path"
        return 1
    fi

    # Normalize branch names (remove feature/ prefix for comparison if needed)
    local target_normalized="${target_branch#feature/}"
    local current_normalized="${current_branch#feature/}"

    if [[ "$current_branch" == "$target_branch" ]] || \
       [[ "$current_normalized" == "$target_normalized" && "$current_branch" == "feature/$target_normalized" ]]; then
        preflight_error "BRANCH CONFLICT: Main repo is on '$current_branch'"
        preflight_error ""
        preflight_error "Git worktrees cannot use a branch already checked out elsewhere."
        preflight_error ""
        preflight_error "To fix this, switch the main repo to a different branch:"
        preflight_error "  cd $project_path"
        preflight_error "  git checkout main  # or: git checkout stable/trunk"
        preflight_error "  git stash          # if you have uncommitted changes"
        preflight_error ""
        preflight_error "Then retry the Kapsis launch."
        return 1
    fi

    preflight_ok "No branch conflict (main repo on: $current_branch)"
    return 0
}

# Check if spec file exists (if provided)
check_spec_file() {
    local spec_file="$1"

    if [[ -z "$spec_file" ]]; then
        return 0
    fi

    log_info "Checking spec file..."

    if [[ ! -f "$spec_file" ]]; then
        preflight_error "Spec file not found: $spec_file"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$spec_file" | tr -d ' ')

    if [[ "$line_count" -lt 5 ]]; then
        preflight_warn "Spec file is very short ($line_count lines) - may need more detail"
    else
        preflight_ok "Spec file exists: $spec_file ($line_count lines)"
    fi

    return 0
}

# Check for existing worktree that might conflict
check_existing_worktree() {
    local project_path="$1"
    local agent_id="$2"

    log_info "Checking for existing worktree..."

    local project_name
    project_name=$(basename "$project_path")
    local worktree_path="${KAPSIS_WORKTREE_BASE:-$HOME/.kapsis/worktrees}/${project_name}-${agent_id}"

    if [[ -d "$worktree_path" ]]; then
        preflight_warn "Existing worktree found: $worktree_path"
        preflight_warn "  Will be reused if on compatible branch"
    else
        preflight_ok "No conflicting worktree"
    fi

    return 0
}

# Check for orphaned Kapsis volumes (Fix #191)
check_orphan_volumes() {
    log_info "Checking for orphaned volumes..."

    if ! command -v podman &>/dev/null; then
        return 0
    fi

    # Count all kapsis volumes
    local all_volumes
    all_volumes=$(podman volume ls --format "{{.Name}}" 2>/dev/null | grep -c "^kapsis-" || true)
    [[ -z "$all_volumes" ]] && all_volumes=0

    if (( all_volumes == 0 )); then
        preflight_ok "No orphaned volumes"
        return 0
    fi

    # Count volumes in use by running containers
    local active_volumes=0
    local running_containers
    running_containers=$(podman ps --format "{{.Names}}" 2>/dev/null | grep "^kapsis-" || true)
    if [[ -n "$running_containers" ]]; then
        # Each running kapsis container uses 3 volumes (m2, gradle, ge)
        local running_count
        running_count=$(echo "$running_containers" | wc -l | tr -d ' ')
        active_volumes=$(( running_count * 3 ))
    fi

    local orphan_count=$(( all_volumes - active_volumes ))
    # Guard against over-estimation of active volumes
    if (( orphan_count < 0 )); then
        orphan_count=0
    fi

    if (( orphan_count > 10 )); then
        preflight_warn "$orphan_count orphaned Kapsis volumes found (wasting disk space)"
        preflight_warn "  Run: kapsis cleanup --volumes"
    elif (( orphan_count > 0 )); then
        log_debug "$orphan_count orphaned volume(s) found (below warning threshold)"
        preflight_ok "Volumes OK ($orphan_count orphaned, below threshold)"
    else
        preflight_ok "No orphaned volumes"
    fi

    return 0
}

# Check for stale/corrupted registered worktrees (Fix #283)
check_stale_worktrees() {
    local project_path="${1:-.}"

    # Only meaningful for git repos
    if ! git -C "$project_path" rev-parse --git-dir &>/dev/null 2>&1; then
        return 0
    fi

    log_info "Checking for stale registered worktrees..."

    # Detect worktrees registered in git but missing or corrupted on disk
    local stale_count=0
    stale_count=$(git -C "$project_path" worktree prune --dry-run 2>&1 | grep -c "^Removing" || true)

    if [[ "$stale_count" -gt 0 ]]; then
        preflight_warn "$stale_count stale worktree(s) registered in git but missing/corrupted on disk"
        preflight_warn "  Run: git -C $project_path worktree prune"
    fi

    # Warn when total worktree count is high (subtract 1 for the main worktree)
    local wt_total=0
    wt_total=$(git -C "$project_path" worktree list --porcelain 2>/dev/null | grep -c "^worktree " || true)
    local wt_count=$(( wt_total > 1 ? wt_total - 1 : 0 ))
    local warn_threshold="${KAPSIS_WORKTREE_COUNT_WARN:-20}"

    if [[ "$wt_count" -gt "$warn_threshold" ]]; then
        preflight_warn "$wt_count worktrees registered for this project — risk of disk exhaustion"
        preflight_warn "  Run: kapsis cleanup --worktrees --project $(basename "$project_path")"
    elif [[ "$stale_count" -eq 0 ]]; then
        preflight_ok "Worktrees OK ($wt_count registered)"
    fi

    return 0
}

# Check available disk space (Fix #191)
check_disk_space() {
    local warn_mb="${KAPSIS_DISK_WARN_MB:-2048}"    # 2GB default
    local abort_mb="${KAPSIS_DISK_ABORT_MB:-512}"    # 500MB default

    log_info "Checking disk space..."

    local available_mb
    if is_macos; then
        available_mb=$(df -m "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
    else
        available_mb=$(df -BM "$HOME" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'M')
    fi

    if [[ -z "$available_mb" ]] || ! [[ "$available_mb" =~ ^[0-9]+$ ]]; then
        log_debug "Could not determine available disk space"
        return 0
    fi

    if (( available_mb < abort_mb )); then
        preflight_error "Critically low disk space: ${available_mb}MB available (minimum: ${abort_mb}MB)"
        preflight_error "  Run: kapsis cleanup --all --volumes --images"
        return 1
    elif (( available_mb < warn_mb )); then
        preflight_warn "Low disk space: ${available_mb}MB available (recommend: ${warn_mb}MB+)"
        preflight_warn "  Consider: kapsis cleanup --all --volumes --images"
        return 0
    fi

    preflight_ok "Disk space OK (${available_mb}MB available)"
    return 0
}

#===============================================================================
# MAIN PREFLIGHT CHECK
#===============================================================================
#===============================================================================
# User namespace compatibility (#361)
#===============================================================================

# Two related concerns, both surfaced at launch as WARN (never ERROR):
#
#   1. Host UID > KAPSIS_USERNS_THRESHOLD AND the resolved --userns value is
#      plain `keep-id`. This produces the #361 degenerate single-ID mapping
#      and container attach fails with exit 126. Default autodetect handles
#      this, but a user who manually pinned `security.userns: keep-id` (in
#      YAML) or `KAPSIS_USERNS=keep-id` (in env) overrides the autodetect
#      and re-introduces the failure.
#
#   2. The resolved --userns value visibly weakens the security posture
#      (host = no namespace isolation, auto = subuid auto-allocate may
#      collide, keep-id:uid=0 = container root maps to host UID). These
#      are valid debug knobs but should not be silent in normal launches.
check_userns_compat() {
    local config_file="${1:-}"
    local host_uid
    local threshold="${KAPSIS_USERNS_THRESHOLD:-60000}"

    # See _detect_userns_default in security.sh — same intentional fallback
    # above the threshold so a transient `id` failure picks the safe path.
    host_uid=$(id -u 2>/dev/null || echo 99999)

    # Determine the effective userns by mirroring _resolve_userns precedence:
    # KAPSIS_USERNS env > security.userns YAML > "(autodetect)".
    local effective_userns="" effective_source=""
    if [[ -n "${KAPSIS_USERNS:-}" ]]; then
        effective_userns="$KAPSIS_USERNS"
        effective_source="KAPSIS_USERNS env"
    elif [[ -n "$config_file" && -f "$config_file" ]] && command -v yq &>/dev/null; then
        local pinned
        pinned=$(yq -r '.security.userns // ""' "$config_file" 2>/dev/null)
        if [[ -n "$pinned" && "$pinned" != "null" ]]; then
            effective_userns="$pinned"
            effective_source="security.userns YAML"
        fi
    fi

    # Concern 1: high host UID + explicit `keep-id` pin → reproduces #361.
    if (( host_uid > threshold )) && [[ "$effective_userns" == "keep-id" ]]; then
        preflight_warn "${effective_source}: 'keep-id' pinned and host UID $host_uid > $threshold"
        preflight_warn "  Container attach may fail with exit 126 (kapsis#361)."
        preflight_warn "  Remove the pin to use the autodetected default"
        preflight_warn "  (keep-id:uid=1000,gid=1000) or set it explicitly."
        return 0
    fi

    # Concern 2: explicitly weakened modes.
    case "$effective_userns" in
        host)
            preflight_warn "${effective_source}: 'host' disables user namespace isolation."
            preflight_warn "  Container processes share the host's namespace; not recommended"
            preflight_warn "  outside Linux-on-Linux debug scenarios."
            ;;
        auto)
            preflight_warn "${effective_source}: 'auto' allocates a subuid block per container."
            preflight_warn "  May exhaust /etc/subuid on long-lived hosts (~15 containers max"
            preflight_warn "  with default 1M-ID range). Prefer the autodetected default."
            ;;
        keep-id:uid=0,*|keep-id:uid=0)
            preflight_warn "${effective_source}: maps container UID 0 (root) to host UID."
            preflight_warn "  This is a privilege uplift surface. Use uid>=1000 unless you"
            preflight_warn "  understand the implications."
            ;;
        "")
            preflight_ok "User namespace mode autodetected for host UID $host_uid"
            ;;
        *)
            preflight_ok "User namespace mode '$effective_userns' (host UID $host_uid)"
            ;;
    esac
}

# Check Podman VM memory allocation (macOS only — Issue #377)
#
# Warns when the VM is sized below the recommended minimum for the planned
# parallel-agent concurrency, and when it consumes too much host RAM (jetsam risk).
# Neither warning blocks launch — both print the exact `podman machine set`
# remediation command so the user can act.
check_podman_vm_memory() {
    local config_file="${1:-}"

    # macOS only — Linux uses native Podman, no VM to size
    if ! is_macos; then
        return 0
    fi

    log_info "Checking Podman VM memory sizing..."

    local machine
    machine="${KAPSIS_PODMAN_MACHINE:-podman-machine-default}"

    local base_gb per_agent_gb max_host_pct
    base_gb="${KAPSIS_VM_BASE_MEMORY_GB:-${KAPSIS_DEFAULT_VM_BASE_MEMORY_GB}}"
    per_agent_gb="${KAPSIS_VM_PER_AGENT_MEMORY_GB:-${KAPSIS_DEFAULT_VM_PER_AGENT_MEMORY_GB}}"
    max_host_pct="${KAPSIS_VM_MAX_HOST_PCT:-${KAPSIS_DEFAULT_VM_MAX_HOST_PCT}}"

    # Resolve max_parallel_agents: KAPSIS_MAX_PARALLEL_AGENTS env > vm.max_parallel_agents YAML > 1
    local max_parallel_agents=1
    if [[ -n "${KAPSIS_MAX_PARALLEL_AGENTS:-}" ]] && [[ "${KAPSIS_MAX_PARALLEL_AGENTS}" =~ ^[0-9]+$ ]]; then
        max_parallel_agents="$KAPSIS_MAX_PARALLEL_AGENTS"
    elif [[ -n "$config_file" && -f "$config_file" ]] && command -v yq &>/dev/null; then
        local cfg_agents
        cfg_agents=$(yq -r '.vm.max_parallel_agents // ""' "$config_file" 2>/dev/null || echo "")
        if [[ -n "$cfg_agents" && "$cfg_agents" =~ ^[0-9]+$ ]]; then
            max_parallel_agents="$cfg_agents"
        fi
    fi

    # Minimum recommended VM memory for the planned concurrency
    local recommended_gb
    recommended_gb=$(( base_gb + per_agent_gb * max_parallel_agents ))

    # Read VM memory in MiB via `podman machine inspect` — gracefully skip on failure
    local vm_mem_mb
    vm_mem_mb=$(podman machine inspect "$machine" --format '{{.Resources.Memory}}' 2>/dev/null || echo "0")
    if ! [[ "${vm_mem_mb:-0}" =~ ^[0-9]+$ ]] || (( vm_mem_mb == 0 )); then
        log_debug "Could not read VM memory from 'podman machine inspect' — skipping memory advisor"
        return 0
    fi
    local vm_mem_gb
    vm_mem_gb=$(( vm_mem_mb / 1024 ))

    # Read host total RAM (bytes → GB)
    local host_mem_bytes host_mem_gb
    host_mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
    host_mem_gb=0
    if [[ "${host_mem_bytes:-0}" =~ ^[0-9]+$ ]] && (( host_mem_bytes > 0 )); then
        host_mem_gb=$(( host_mem_bytes / 1024 / 1024 / 1024 ))
    fi

    # Check 1: VM below recommended threshold for planned concurrency
    if (( vm_mem_gb < recommended_gb )); then
        local recommended_mb
        recommended_mb=$(( recommended_gb * 1024 ))
        preflight_warn "VM memory ${vm_mem_gb}GB < recommended ${recommended_gb}GB for ${max_parallel_agents} parallel agent(s)"
        preflight_warn "  AVF virtio-fs cache race window widens under memory pressure (Apple FB16008360)"
        preflight_warn "  To resize (requires VM restart — kills in-flight agents):"
        preflight_warn "    podman machine stop ${machine} && podman machine set --memory ${recommended_mb} ${machine} && podman machine start ${machine}"
        return 0
    fi

    # Check 2: VM consumes too much host RAM — jetsam amplifier risk
    if (( host_mem_gb > 0 )); then
        local vm_pct
        vm_pct=$(( vm_mem_gb * 100 / host_mem_gb ))
        if (( vm_pct > max_host_pct )); then
            local safe_gb safe_mb
            safe_gb=$(( host_mem_gb * max_host_pct / 100 ))
            safe_mb=$(( safe_gb * 1024 ))
            preflight_warn "VM memory ${vm_mem_gb}GB is ${vm_pct}% of host RAM ${host_mem_gb}GB (threshold: ${max_host_pct}%)"
            preflight_warn "  High VM:host ratio makes the AVF helper the top jetsam candidate (Apple FB16008360)"
            preflight_warn "  Recommended VM size: ${safe_gb}GB"
            preflight_warn "    podman machine stop ${machine} && podman machine set --memory ${safe_mb} ${machine} && podman machine start ${machine}"
            return 0
        fi
    fi

    preflight_ok "VM memory OK (${vm_mem_gb}GB allocated, ${max_parallel_agents} parallel agent(s), threshold ${recommended_gb}GB)"
    return 0
}

# Check macOS host memory pressure (Issue #377)
#
# Elevated swap usage widens the AVF virtio-fs cache-coherency race window
# (Apple FB16008360), increasing mount_failure (exit_code=4) frequency.
# Warning-only — does not block launch.
check_host_memory_pressure() {
    # macOS only
    if ! is_macos; then
        return 0
    fi

    local swap_warn_pct
    swap_warn_pct="${KAPSIS_VM_SWAP_WARN_PCT:-${KAPSIS_DEFAULT_VM_SWAP_WARN_PCT}}"

    log_info "Checking host memory pressure..."

    # sysctl vm.swapusage: total = 4096.00M  used = 2048.00M  free = 2048.00M  (encrypted)
    local swap_line
    swap_line=$(sysctl vm.swapusage 2>/dev/null || echo "")
    if [[ -z "$swap_line" ]]; then
        log_debug "vm.swapusage not available — skipping memory pressure check"
        return 0
    fi

    # BSD-awk: find "total = NNN.NNM" and "used = NNN.NNM", extract integer MB part
    local swap_total_mb swap_used_mb
    swap_total_mb=$(printf '%s' "$swap_line" | awk '{for(i=1;i<=NF;i++) if ($i=="total" && $(i+1)=="=") {split($(i+2),a,"."); print a[1]+0; exit}}')
    swap_used_mb=$(printf '%s' "$swap_line" | awk '{for(i=1;i<=NF;i++) if ($i=="used" && $(i+1)=="=") {split($(i+2),a,"."); print a[1]+0; exit}}')

    if ! [[ "${swap_total_mb:-0}" =~ ^[0-9]+$ ]] || ! [[ "${swap_used_mb:-0}" =~ ^[0-9]+$ ]]; then
        log_debug "Could not parse vm.swapusage: '$swap_line'"
        return 0
    fi

    if (( swap_total_mb == 0 )); then
        preflight_ok "No swap configured — host memory pressure: low"
        return 0
    fi

    local swap_pct
    swap_pct=$(( swap_used_mb * 100 / swap_total_mb ))

    if (( swap_pct >= swap_warn_pct )); then
        preflight_warn "Host swap usage ${swap_pct}% (${swap_used_mb}MB/${swap_total_mb}MB)"
        preflight_warn "  Elevated swap widens the AVF virtio-fs cache race window (Apple FB16008360)"
        preflight_warn "  This increases mount_failure (exit_code=4) frequency"
        preflight_warn "  Consider: close memory-heavy apps, or reduce Podman VM memory"
    else
        preflight_ok "Host memory pressure OK (swap ${swap_pct}% used)"
    fi

    return 0
}

preflight_check() {
    local project_path="${1:-.}"
    local target_branch="${2:-}"
    local spec_file="${3:-}"
    local image_name="${4:-kapsis-sandbox:latest}"
    local agent_id="${5:-1}"
    local agent_config="${6:-}"

    _PREFLIGHT_ERRORS=0
    _PREFLIGHT_WARNINGS=0

    log_section "Kapsis Pre-Flight Check"
    echo ""

    # Run all checks
    check_podman || true
    check_podman_vm_memory "$agent_config" || true
    check_host_memory_pressure || true
    check_disk_space || true
    check_images "$image_name" || true
    check_userns_compat "$agent_config" || true

    if [[ -n "$target_branch" ]]; then
        check_git_status "$project_path" || true
        check_branch_conflict "$project_path" "$target_branch" || true
        check_existing_worktree "$project_path" "$agent_id" || true
        check_stale_worktrees "$project_path" || true
    fi

    if [[ -n "$spec_file" ]]; then
        check_spec_file "$spec_file" || true
    fi

    check_orphan_volumes || true

    echo ""

    # Summary
    if [[ $_PREFLIGHT_ERRORS -gt 0 ]]; then
        log_error "Pre-flight check FAILED: $_PREFLIGHT_ERRORS error(s), $_PREFLIGHT_WARNINGS warning(s)"
        echo ""
        return 1
    elif [[ $_PREFLIGHT_WARNINGS -gt 0 ]]; then
        log_warn "Pre-flight check PASSED with $_PREFLIGHT_WARNINGS warning(s)"
        echo ""
        return 0  # Warnings don't block launch
    else
        log_success "Pre-flight check PASSED: All checks OK"
        echo ""
        return 0
    fi
}

#===============================================================================
# STANDALONE EXECUTION
#===============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse arguments - support both --config and legacy positional args
    PROJECT_PATH=""
    TARGET_BRANCH=""
    SPEC_FILE=""
    IMAGE_NAME=""
    AGENT_ID="1"
    CONFIG_FILE=""

    show_help() {
        echo "Usage: $0 [--config <file>] <project_path> [target_branch] [spec_file]"
        echo ""
        echo "Validates prerequisites before launching a Kapsis agent."
        echo ""
        echo "Options:"
        echo "  --config <file>  Read image from config file (same as launch-agent.sh)"
        echo "  -h, --help       Show this help message"
        echo ""
        echo "Positional arguments:"
        echo "  project_path   Path to the project directory (default: .)"
        echo "  target_branch  Git branch for worktree (optional)"
        echo "  spec_file      Task specification file (optional)"
        echo "  image_name     Container image (default: from config or kapsis-sandbox:latest)"
        echo "  agent_id       Agent identifier (default: 1)"
        echo ""
        echo "Examples:"
        echo "  # Recommended: use --config to match launch-agent.sh behavior"
        echo "  $0 --config ~/git/kapsis/configs/aviad-claude.yaml ~/git/products feature/DEV-123 ./spec.md"
        echo ""
        echo "  # Legacy: explicit image name"
        echo "  $0 ~/git/products feature/DEV-123 ./spec.md kapsis-claude-cli:latest"
        echo ""
        echo "Exit codes:"
        echo "  0 - All checks pass"
        echo "  1 - Critical failure"
        exit 0
    }

    # Parse --config option first
    POSITIONAL_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
    set -- "${POSITIONAL_ARGS[@]}"

    # Parse positional arguments
    PROJECT_PATH="${1:-.}"
    TARGET_BRANCH="${2:-}"
    SPEC_FILE="${3:-}"
    IMAGE_NAME="${4:-}"
    AGENT_ID="${5:-1}"

    # Extract image from config file (same logic as launch-agent.sh)
    if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        if ! command -v yq &>/dev/null; then
            echo "ERROR: yq is required but not installed." >&2
            echo "Install yq: brew install yq (macOS) or sudo snap install yq (Linux)" >&2
            exit 1
        fi
        CONFIG_IMAGE=$(yq -r '.image.name // "kapsis-sandbox"' "$CONFIG_FILE"):$(yq -r '.image.tag // "latest"' "$CONFIG_FILE")
        IMAGE_NAME="${CONFIG_IMAGE}"
    fi

    # Default if no config file provided
    [[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="kapsis-sandbox:latest"

    preflight_check "$PROJECT_PATH" "$TARGET_BRANCH" "$SPEC_FILE" "$IMAGE_NAME" "$AGENT_ID" "$CONFIG_FILE"
    exit $?
fi
