#!/usr/bin/env bash
#===============================================================================
# Kapsis - Merge Agent Changes
#
# Reviews and merges changes from agent sandbox upper directory to the project.
# Use this for the manual merge workflow (when not using --branch).
#
# Usage:
#   ./merge-changes.sh <sandbox-id> <project-path> [options]
#
# Options:
#   --dry-run         Show what would be copied without copying
#   --force           Skip confirmation prompt
#   --cleanup         Remove sandbox after merge
#===============================================================================

set -euo pipefail

SANDBOX_ID="${1:?Sandbox ID required (e.g., myproject-1)}"
PROJECT_PATH="${2:?Project path required}"

DRY_RUN=false
FORCE=false
CLEANUP=false

# Parse options
shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[MERGE]${NC} $*"; }
log_success() { echo -e "${GREEN}[MERGE]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[MERGE]${NC} $*"; }
log_error() { echo -e "${RED}[MERGE]${NC} $*" >&2; }

# Find sandbox directory
SANDBOX_BASE="${HOME}/.ai-sandboxes"
SANDBOX_DIR="${SANDBOX_BASE}/${SANDBOX_ID}"
UPPER_DIR="${SANDBOX_DIR}/upper"

if [[ ! -d "$UPPER_DIR" ]]; then
    log_error "Sandbox not found: $SANDBOX_DIR"
    log_info "Available sandboxes:"
    ls -1 "$SANDBOX_BASE" 2>/dev/null || echo "  (none)"
    exit 1
fi

# Validate project path
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
if [[ ! -d "$PROJECT_PATH" ]]; then
    log_error "Project path does not exist: $PROJECT_PATH"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                    KAPSIS MERGE CHANGES                           ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

log_info "Sandbox: $SANDBOX_ID"
log_info "Upper directory: $UPPER_DIR"
log_info "Target project: $PROJECT_PATH"
echo ""

# Count and show changes
CHANGES=$(find "$UPPER_DIR" -type f 2>/dev/null)
CHANGE_COUNT=$(echo "$CHANGES" | grep -c . || echo 0)

if [[ "$CHANGE_COUNT" -eq 0 ]]; then
    log_warn "No changes found in sandbox"
    exit 0
fi

log_info "Files to merge ($CHANGE_COUNT):"
echo ""
echo "$CHANGES" | while read -r file; do
    rel_path="${file#$UPPER_DIR/}"
    if [[ -f "${PROJECT_PATH}/${rel_path}" ]]; then
        echo -e "  ${YELLOW}[MODIFY]${NC} $rel_path"
    else
        echo -e "  ${GREEN}[NEW]${NC} $rel_path"
    fi
done
echo ""

# Dry run
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN - Would execute:"
    echo "  rsync -av ${UPPER_DIR}/ ${PROJECT_PATH}/"
    exit 0
fi

# Confirmation
if [[ "$FORCE" != "true" ]]; then
    echo -n "Merge these changes? [y/N] "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Merge cancelled"
        exit 0
    fi
fi

# Merge
log_info "Merging changes..."
rsync -av "${UPPER_DIR}/" "${PROJECT_PATH}/"

log_success "Changes merged successfully"

# Show git status
if [[ -d "${PROJECT_PATH}/.git" ]]; then
    echo ""
    log_info "Git status:"
    cd "$PROJECT_PATH"
    git status --short
fi

# Cleanup
if [[ "$CLEANUP" == "true" ]]; then
    echo ""
    log_info "Cleaning up sandbox..."
    rm -rf "$SANDBOX_DIR"
    log_success "Sandbox removed: $SANDBOX_DIR"
else
    echo ""
    log_info "Sandbox preserved at: $SANDBOX_DIR"
    echo "To cleanup: rm -rf $SANDBOX_DIR"
fi
