#!/usr/bin/env bash
#
# kapsis-cleanup.sh - Reclaim space and clean up after agent work
#
# Usage:
#   kapsis-cleanup.sh                    # Interactive cleanup with prompts
#   kapsis-cleanup.sh --dry-run          # Show what would be cleaned
#   kapsis-cleanup.sh --all              # Clean everything (with confirmation)
#   kapsis-cleanup.sh --project <name>   # Clean specific project
#   kapsis-cleanup.sh --agent <proj> <id> # Clean specific agent
#   kapsis-cleanup.sh --volumes          # Also clean build cache volumes
#   kapsis-cleanup.sh --force            # Skip confirmation prompts
#   kapsis-cleanup.sh --help             # Show help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging if available
if [[ -f "$SCRIPT_DIR/lib/logging.sh" ]]; then
    source "$SCRIPT_DIR/lib/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [[ "${KAPSIS_DEBUG:-}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }
fi

# Source cross-platform compatibility helpers
if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
    source "$SCRIPT_DIR/lib/compat.sh"
fi

# Directories
KAPSIS_DIR="${KAPSIS_DIR:-$HOME/.kapsis}"
WORKTREE_DIR="${KAPSIS_WORKTREE_DIR:-$KAPSIS_DIR/worktrees}"
STATUS_DIR="${KAPSIS_STATUS_DIR:-$KAPSIS_DIR/status}"
LOG_DIR="${KAPSIS_LOG_DIR:-$KAPSIS_DIR/logs}"
SANDBOX_DIR="${KAPSIS_SANDBOX_DIR:-$HOME/.ai-sandboxes}"
SANITIZED_GIT_DIR="${KAPSIS_SANITIZED_GIT_DIR:-$KAPSIS_DIR/sanitized-git}"

# Options
DRY_RUN=false
FORCE=false
CLEAN_ALL=false
CLEAN_VOLUMES=false
PROJECT_FILTER=""
AGENT_FILTER=""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Stats
TOTAL_SIZE_FREED=0
ITEMS_CLEANED=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reclaim disk space by cleaning up after Kapsis agent work.

OPTIONS:
    --dry-run           Show what would be cleaned without removing anything
    --all               Clean all Kapsis artifacts (worktrees, sandboxes, status, containers)
    --project <name>    Clean only artifacts for specific project
    --agent <proj> <id> Clean only specific agent's artifacts
    --volumes           Also clean build cache volumes (Maven, Gradle)
    --containers        Clean stopped Kapsis containers
    --logs              Clean log files older than 7 days
    --ssh-cache         Clear cached SSH host keys from keychain
    --force, -f         Skip confirmation prompts
    --help, -h          Show this help message

WHAT GETS CLEANED:
    Worktrees       Git worktrees in ~/.kapsis/worktrees/
    Sandboxes       Overlay upper dirs in ~/.ai-sandboxes/
    Status files    Completed status files in ~/.kapsis/status/
    Sanitized git   Temporary git dirs in ~/.kapsis/sanitized-git/
    Containers      Stopped kapsis-* containers (with --containers)
    Volumes         Build cache volumes (with --volumes)
    Logs            Old log files (with --logs)
    SSH cache       Cached SSH host keys (with --ssh-cache)

EXAMPLES:
    # See what would be cleaned
    $(basename "$0") --dry-run

    # Clean everything for project 'products'
    $(basename "$0") --project products --force

    # Full cleanup including volumes
    $(basename "$0") --all --volumes

    # Clean specific agent
    $(basename "$0") --agent products 1

    # Clear SSH host key cache (after key rotation)
    $(basename "$0") --ssh-cache
EOF
}

# Format bytes to human readable
format_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1fG" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1fM" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.1fK" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%dB" "$bytes"
    fi
}

# Get directory size in bytes
get_dir_size() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        local kb
        kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
        echo $((${kb:-0} * 1024))
    else
        echo 0
    fi
}

# Confirm action
confirm() {
    local msg="$1"
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    echo -en "${YELLOW}$msg [y/N]: ${NC}"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Print section header
section() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"
}

# Print item to clean
print_item() {
    local type="$1"
    local name="$2"
    local size="$3"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}[DRY-RUN]${NC} Would remove $type: $name ($size)"
    else
        echo -e "  ${GREEN}[CLEANED]${NC} Removed $type: $name ($size)"
    fi
}

# Clean worktrees
clean_worktrees() {
    section "Worktrees"

    if [[ ! -d "$WORKTREE_DIR" ]]; then
        echo "  No worktree directory found"
        return
    fi

    local count=0
    local total_size=0

    for worktree in "$WORKTREE_DIR"/*; do
        [[ -d "$worktree" ]] || continue
        local name
        name=$(basename "$worktree")

        # Apply filters
        if [[ -n "$PROJECT_FILTER" ]] && [[ ! "$name" =~ ^${PROJECT_FILTER}- ]]; then
            continue
        fi
        if [[ -n "$AGENT_FILTER" ]] && [[ "$name" != "${PROJECT_FILTER}-${AGENT_FILTER}" ]]; then
            continue
        fi

        local size
        size=$(get_dir_size "$worktree")
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "worktree" "$name" "$size_human"
        else
            # Find the original git repo to prune from
            if [[ -f "$worktree/.git" ]]; then
                local git_dir
                git_dir=$(grep "gitdir:" "$worktree/.git" | cut -d' ' -f2-)
                local main_repo
                main_repo=$(dirname "$(dirname "$git_dir")")
                if [[ -d "$main_repo/.git" ]]; then
                    git -C "$main_repo" worktree remove "$worktree" --force 2>/dev/null || rm -rf "$worktree"
                else
                    rm -rf "$worktree"
                fi
            else
                rm -rf "$worktree"
            fi
            print_item "worktree" "$name" "$size_human"
        fi

        ((total_size += size))
        ((count++))
    done

    if (( count == 0 )); then
        echo "  No worktrees to clean"
    else
        echo -e "  ${BOLD}Total: $count worktrees ($(format_size $total_size))${NC}"
        ((TOTAL_SIZE_FREED += total_size))
        ((ITEMS_CLEANED += count))
    fi
}

# Clean sandbox directories
clean_sandboxes() {
    section "Sandbox Directories"

    if [[ ! -d "$SANDBOX_DIR" ]]; then
        echo "  No sandbox directory found"
        return
    fi

    local count=0
    local total_size=0
    local skipped_sandboxes=0

    for sandbox in "$SANDBOX_DIR"/*; do
        [[ -d "$sandbox" ]] || continue
        local name
        name=$(basename "$sandbox")

        # Skip non-kapsis sandboxes (those not matching pattern)
        if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+-[0-9]+$ ]] && [[ ! "$name" =~ ^\.kapsis- ]] && [[ ! "$name" =~ ^kapsis- ]]; then
            # Check if it looks like a kapsis sandbox (has upper/work dirs)
            if [[ ! -d "$sandbox/upper" ]] && [[ ! -d "$sandbox/work" ]]; then
                continue
            fi
        fi

        # Apply filters
        if [[ -n "$PROJECT_FILTER" ]]; then
            if [[ ! "$name" =~ ^${PROJECT_FILTER}- ]] && [[ ! "$name" =~ ^\.kapsis-${PROJECT_FILTER}- ]]; then
                continue
            fi
        fi
        if [[ -n "$AGENT_FILTER" ]]; then
            if [[ "$name" != "${PROJECT_FILTER}-${AGENT_FILTER}" ]] && [[ "$name" != ".kapsis-${PROJECT_FILTER}-${AGENT_FILTER}" ]]; then
                continue
            fi
        fi

        local size
        size=$(get_dir_size "$sandbox")
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "sandbox" "$name" "$size_human"
        else
            if rm -rf "$sandbox" 2>/dev/null; then
                print_item "sandbox" "$name" "$size_human"
            else
                # Try podman unshare (Linux) or other elevated methods
                local cleaned=false
                if command -v podman &>/dev/null; then
                    # Check if we're on macOS (remote podman)
                    if [[ "$(uname)" == "Darwin" ]]; then
                        # On macOS, overlay dirs owned by VM - try sudo
                        if sudo rm -rf "$sandbox" 2>/dev/null; then
                            print_item "sandbox" "$name" "$size_human (via sudo)"
                            cleaned=true
                        fi
                    else
                        # On Linux, use podman unshare
                        if podman unshare rm -rf "$sandbox" 2>/dev/null; then
                            print_item "sandbox" "$name" "$size_human (via podman unshare)"
                            cleaned=true
                        fi
                    fi
                fi
                if [[ "$cleaned" != "true" ]]; then
                    echo -e "  ${YELLOW}[SKIPPED]${NC} $name (permission denied)"
                    ((skipped_sandboxes++))
                    continue
                fi
            fi
        fi

        ((total_size += size))
        ((count++))
    done

    if (( count == 0 )) && (( skipped_sandboxes == 0 )); then
        echo "  No sandboxes to clean"
    else
        if (( count > 0 )); then
            echo -e "  ${BOLD}Total: $count sandboxes ($(format_size $total_size))${NC}"
            ((TOTAL_SIZE_FREED += total_size))
            ((ITEMS_CLEANED += count))
        fi
        if (( skipped_sandboxes > 0 )); then
            echo -e "  ${YELLOW}Skipped: $skipped_sandboxes sandboxes (overlay permissions)${NC}"
            echo -e "  ${CYAN}To clean these manually:${NC}"
            if [[ "$(uname)" == "Darwin" ]]; then
                echo "    sudo rm -rf ~/.ai-sandboxes/kapsis-*"
            else
                echo "    podman unshare rm -rf ~/.ai-sandboxes/kapsis-*"
            fi
        fi
    fi
}

# Clean status files
clean_status() {
    section "Status Files"

    if [[ ! -d "$STATUS_DIR" ]]; then
        echo "  No status directory found"
        return
    fi

    local count=0
    local total_size=0

    for status_file in "$STATUS_DIR"/kapsis-*.json; do
        [[ -f "$status_file" ]] || continue
        local name
        name=$(basename "$status_file")

        # Apply project filter
        if [[ -n "$PROJECT_FILTER" ]] && [[ ! "$name" =~ ^kapsis-${PROJECT_FILTER}- ]]; then
            continue
        fi

        # Check if completed (only clean completed status files)
        local phase
        phase=$(grep -o '"phase"[[:space:]]*:[[:space:]]*"[^"]*"' "$status_file" 2>/dev/null | cut -d'"' -f4 || echo "")
        if [[ "$phase" != "complete" ]] && [[ "$CLEAN_ALL" != "true" ]]; then
            log_debug "Skipping active status file: $name (phase: $phase)"
            continue
        fi

        local size
        size=$(get_file_size "$status_file")
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "status" "$name" "$size_human"
        else
            rm -f "$status_file"
            print_item "status" "$name" "$size_human"
        fi

        ((total_size += size))
        ((count++))
    done

    if (( count == 0 )); then
        echo "  No status files to clean"
    else
        echo -e "  ${BOLD}Total: $count status files ($(format_size $total_size))${NC}"
        ((TOTAL_SIZE_FREED += total_size))
        ((ITEMS_CLEANED += count))
    fi
}

# Clean sanitized git directories
clean_sanitized_git() {
    section "Sanitized Git Directories"

    if [[ ! -d "$SANITIZED_GIT_DIR" ]]; then
        echo "  No sanitized git directory found"
        return
    fi

    local count=0
    local total_size=0

    for git_dir in "$SANITIZED_GIT_DIR"/*; do
        [[ -d "$git_dir" ]] || continue
        local name
        name=$(basename "$git_dir")

        # Apply project filter
        if [[ -n "$PROJECT_FILTER" ]] && [[ ! "$name" =~ ^${PROJECT_FILTER}- ]]; then
            continue
        fi

        local size
        size=$(get_dir_size "$git_dir")
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "sanitized-git" "$name" "$size_human"
        else
            rm -rf "$git_dir"
            print_item "sanitized-git" "$name" "$size_human"
        fi

        ((total_size += size))
        ((count++))
    done

    if (( count == 0 )); then
        echo "  No sanitized git directories to clean"
    else
        echo -e "  ${BOLD}Total: $count directories ($(format_size $total_size))${NC}"
        ((TOTAL_SIZE_FREED += total_size))
        ((ITEMS_CLEANED += count))
    fi
}

# Clean containers
clean_containers() {
    section "Stopped Containers"

    if ! command -v podman &>/dev/null; then
        echo "  Podman not available"
        return
    fi

    local count=0

    # Get stopped kapsis containers
    local containers
    containers=$(podman ps -a --filter "name=kapsis" --filter "status=exited" --filter "status=created" --format "{{.Names}}" 2>/dev/null || true)

    if [[ -z "$containers" ]]; then
        echo "  No stopped containers to clean"
        return
    fi

    while IFS= read -r container; do
        [[ -z "$container" ]] && continue

        # Apply project filter
        if [[ -n "$PROJECT_FILTER" ]] && [[ ! "$container" =~ ${PROJECT_FILTER} ]]; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "container" "$container" "N/A"
        else
            podman rm "$container" &>/dev/null || true
            print_item "container" "$container" "N/A"
        fi
        ((count++))
    done <<< "$containers"

    if (( count == 0 )); then
        echo "  No containers to clean"
    else
        echo -e "  ${BOLD}Total: $count containers${NC}"
        ((ITEMS_CLEANED += count))
    fi
}

# Clean volumes
clean_volumes() {
    section "Build Cache Volumes"

    if ! command -v podman &>/dev/null; then
        echo "  Podman not available"
        return
    fi

    local count=0
    local total_size=0

    # Get kapsis volumes
    local volumes
    volumes=$(podman volume ls --format "{{.Name}}" 2>/dev/null | grep -E "^kapsis-" || true)

    if [[ -z "$volumes" ]]; then
        echo "  No volumes to clean"
        return
    fi

    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue

        # Apply agent filter
        if [[ -n "$AGENT_FILTER" ]] && [[ ! "$volume" =~ kapsis-${AGENT_FILTER}- ]]; then
            continue
        fi

        # Get volume size (approximate)
        local mount_point
        mount_point=$(podman volume inspect "$volume" --format "{{.Mountpoint}}" 2>/dev/null || echo "")
        local size=0
        if [[ -n "$mount_point" ]] && [[ -d "$mount_point" ]]; then
            size=$(get_dir_size "$mount_point")
        fi
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "volume" "$volume" "$size_human"
        else
            podman volume rm "$volume" &>/dev/null || true
            print_item "volume" "$volume" "$size_human"
        fi

        ((total_size += size))
        ((count++))
    done <<< "$volumes"

    if (( count == 0 )); then
        echo "  No volumes to clean"
    else
        echo -e "  ${BOLD}Total: $count volumes ($(format_size $total_size))${NC}"
        ((TOTAL_SIZE_FREED += total_size))
        ((ITEMS_CLEANED += count))
    fi
}

# Clean old logs
clean_logs() {
    section "Log Files"

    if [[ ! -d "$LOG_DIR" ]]; then
        echo "  No log directory found"
        return
    fi

    local count=0
    local total_size=0

    # Find log files older than 7 days
    while IFS= read -r log_file; do
        [[ -z "$log_file" ]] && continue
        local name
        name=$(basename "$log_file")
        local size
        size=$(get_file_size "$log_file")
        local size_human
        size_human=$(format_size "$size")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_item "log" "$name" "$size_human"
        else
            rm -f "$log_file"
            print_item "log" "$name" "$size_human"
        fi

        ((total_size += size))
        ((count++))
    done < <(find "$LOG_DIR" -name "*.log" -mtime +7 2>/dev/null || true)

    if (( count == 0 )); then
        echo "  No old log files to clean"
    else
        echo -e "  ${BOLD}Total: $count log files ($(format_size $total_size))${NC}"
        ((TOTAL_SIZE_FREED += total_size))
        ((ITEMS_CLEANED += count))
    fi
}

# Clean SSH cache
clean_ssh_cache() {
    section "SSH Host Key Cache"

    local count=0
    local ssh_cache_dir="$KAPSIS_DIR/ssh-cache"

    # macOS: Clear keychain entries
    if [[ "$(uname)" == "Darwin" ]]; then
        # Get all kapsis SSH entries from keychain
        local entries
        entries=$(security dump-keychain 2>/dev/null | grep -B5 '"kapsis-ssh-known-hosts"' | grep '"acct"' | sed 's/.*="//;s/".*//' || true)

        if [[ -n "$entries" ]]; then
            while IFS= read -r host; do
                [[ -z "$host" ]] && continue

                if [[ "$DRY_RUN" == "true" ]]; then
                    print_item "keychain" "kapsis-ssh-known-hosts/$host" "N/A"
                else
                    if security delete-generic-password -s "kapsis-ssh-known-hosts" -a "$host" &>/dev/null; then
                        print_item "keychain" "kapsis-ssh-known-hosts/$host" "N/A"
                    fi
                fi
                ((count++))
            done <<< "$entries"
        fi
    fi

    # Linux: Clear file-based cache
    if [[ -d "$ssh_cache_dir" ]]; then
        local cache_size
        cache_size=$(get_dir_size "$ssh_cache_dir")
        local size_human
        size_human=$(format_size "$cache_size")

        for cache_file in "$ssh_cache_dir"/*; do
            [[ -f "$cache_file" ]] || continue
            local name
            name=$(basename "$cache_file")

            if [[ "$DRY_RUN" == "true" ]]; then
                print_item "ssh-cache" "$name" "N/A"
            else
                rm -f "$cache_file"
                print_item "ssh-cache" "$name" "N/A"
            fi
            ((count++))
        done

        if [[ "$DRY_RUN" != "true" ]] && [[ -d "$ssh_cache_dir" ]]; then
            rmdir "$ssh_cache_dir" 2>/dev/null || true
        fi
    fi

    if (( count == 0 )); then
        echo "  No SSH cache entries to clean"
    else
        echo -e "  ${BOLD}Total: $count SSH cache entries${NC}"
        ((ITEMS_CLEANED += count))
    fi

    # Note about persistent config
    if [[ -f "$KAPSIS_DIR/ssh-hosts.conf" ]]; then
        echo -e "  ${CYAN}Note: ~/.kapsis/ssh-hosts.conf (fingerprints) preserved${NC}"
    fi
}

# Print summary
print_summary() {
    echo -e "\n${BOLD}${GREEN}=== Summary ===${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}DRY RUN - No changes made${NC}"
        echo -e "  Would clean: $ITEMS_CLEANED items"
        echo -e "  Would free: $(format_size $TOTAL_SIZE_FREED)"
    else
        echo -e "  Cleaned: $ITEMS_CLEANED items"
        echo -e "  Space freed: $(format_size $TOTAL_SIZE_FREED)"
    fi
}

# Main
main() {
    local clean_containers_flag=false
    local clean_logs_flag=false
    local clean_ssh_cache_flag=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --all)
                CLEAN_ALL=true
                shift
                ;;
            --volumes)
                CLEAN_VOLUMES=true
                shift
                ;;
            --containers)
                clean_containers_flag=true
                shift
                ;;
            --logs)
                clean_logs_flag=true
                shift
                ;;
            --ssh-cache)
                clean_ssh_cache_flag=true
                shift
                ;;
            --project)
                PROJECT_FILTER="$2"
                shift 2
                ;;
            --agent)
                PROJECT_FILTER="$2"
                AGENT_FILTER="$3"
                shift 3
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

    echo -e "${BOLD}Kapsis Cleanup${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}(Dry run mode - no changes will be made)${NC}"
    fi
    if [[ -n "$PROJECT_FILTER" ]]; then
        echo -e "Filtering: project=${PROJECT_FILTER}${AGENT_FILTER:+, agent=$AGENT_FILTER}"
    fi

    # Confirm if cleaning all
    if [[ "$CLEAN_ALL" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        if ! confirm "This will clean ALL Kapsis artifacts. Continue?"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Run cleanups
    clean_worktrees
    clean_sandboxes
    clean_status
    clean_sanitized_git

    if [[ "$clean_containers_flag" == "true" ]] || [[ "$CLEAN_ALL" == "true" ]]; then
        clean_containers
    fi

    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        if [[ "$DRY_RUN" != "true" ]] && ! confirm "Clean build cache volumes? This will require re-downloading dependencies."; then
            echo "  Skipping volumes"
        else
            clean_volumes
        fi
    fi

    if [[ "$clean_logs_flag" == "true" ]] || [[ "$CLEAN_ALL" == "true" ]]; then
        clean_logs
    fi

    if [[ "$clean_ssh_cache_flag" == "true" ]]; then
        clean_ssh_cache
    fi

    # Summary
    print_summary

    # Suggest garbage collection
    if [[ "$DRY_RUN" != "true" ]] && (( ITEMS_CLEANED > 0 )); then
        echo -e "\n${YELLOW}Tip:${NC} Run 'git worktree prune' in your project repos to clean stale worktree references."
    fi
}

main "$@"
