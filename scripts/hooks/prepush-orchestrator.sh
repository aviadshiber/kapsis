#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push Orchestrator
#
# Orchestrates all pre-push tasks in sequence:
#   1. Check PR comments (if PR exists)
#   2. Check documentation updates
#   3. Run unbiased LLM review (skeptical + security)
#   4. Create PR if doesn't exist
#
# Usage:
#   ./prepush-orchestrator.sh              # Run all checks
#   ./prepush-orchestrator.sh --no-review  # Skip LLM review
#   ./prepush-orchestrator.sh --no-pr      # Skip PR creation
#
# Exit codes:
#   0 - All checks passed
#   1 - Critical issue found (blocks push)
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source logging
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "prepush-orchestrator"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
fi

# Parse arguments
SKIP_REVIEW=false
SKIP_PR=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-review)
            SKIP_REVIEW=true
            shift
            ;;
        --no-pr)
            SKIP_PR=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Options:"
            echo "  --no-review    Skip LLM review"
            echo "  --no-pr        Skip PR creation"
            echo "  -h, --help     Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

PREPUSH_DIR="$SCRIPT_DIR/prepush"
EXIT_CODE=0

log_info "Starting pre-push checks..."
echo ""

# 1. Check PR comments
log_info "Step 1/4: Checking PR comments..."
if [[ -x "$PREPUSH_DIR/pr-comments.sh" ]]; then
    if ! "$PREPUSH_DIR/pr-comments.sh"; then
        log_warn "PR comment check had warnings"
    fi
else
    log_debug "pr-comments.sh not found, skipping"
fi
echo ""

# 2. Check documentation
log_info "Step 2/4: Checking documentation..."
if [[ -x "$PREPUSH_DIR/check-docs.sh" ]]; then
    if ! "$PREPUSH_DIR/check-docs.sh"; then
        log_warn "Documentation check had warnings"
    fi
else
    log_debug "check-docs.sh not found, skipping"
fi
echo ""

# 3. Run unbiased review
if [[ "$SKIP_REVIEW" == "false" ]]; then
    log_info "Step 3/4: Running unbiased review..."
    if [[ -x "$PREPUSH_DIR/unbiased-review.sh" ]]; then
        if ! "$PREPUSH_DIR/unbiased-review.sh"; then
            log_error "Review found critical issues"
            EXIT_CODE=1
        fi
    else
        log_debug "unbiased-review.sh not found, skipping"
    fi
else
    log_info "Step 3/4: Skipping LLM review (--no-review)"
fi
echo ""

# 4. Create PR if needed
if [[ "$SKIP_PR" == "false" ]]; then
    log_info "Step 4/4: Checking/creating PR..."
    if [[ -x "$PREPUSH_DIR/create-pr.sh" ]]; then
        if ! "$PREPUSH_DIR/create-pr.sh"; then
            log_warn "PR creation had issues"
        fi
    else
        log_debug "create-pr.sh not found, skipping"
    fi
else
    log_info "Step 4/4: Skipping PR creation (--no-pr)"
fi
echo ""

# Summary
if [[ "$EXIT_CODE" -eq 0 ]]; then
    log_success "All pre-push checks completed"
else
    log_error "Pre-push checks failed with critical issues"
fi

exit $EXIT_CODE
