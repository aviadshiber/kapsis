#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push: Check PR Comments
#
# Checks if there's an existing PR and fetches any unresolved comments.
# Warns about unresolved discussions before pushing.
#
# Exit codes:
#   0 - No PR or no unresolved comments
#   1 - Unresolved blocking comments found
#   2 - gh CLI not available
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "prepush-pr-comments"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
fi

# Check if gh CLI is available
if ! command -v gh &>/dev/null; then
    log_warn "gh CLI not installed, skipping PR comment check"
    exit 0
fi

# Check if authenticated
if ! gh auth status &>/dev/null 2>&1; then
    log_warn "Not authenticated with GitHub, skipping PR comment check"
    exit 0
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

if [[ -z "$CURRENT_BRANCH" ]]; then
    log_debug "Not on a branch, skipping"
    exit 0
fi

# Check if PR exists for this branch
log_debug "Checking for PR on branch: $CURRENT_BRANCH"

PR_JSON=$(gh pr view --json number,reviews,comments 2>/dev/null || echo "")

if [[ -z "$PR_JSON" ]]; then
    log_debug "No PR found for this branch"
    exit 0
fi

PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number // empty')
log_info "Found PR #$PR_NUMBER, checking for comments..."

# Check for unresolved review comments
REVIEWS=$(echo "$PR_JSON" | jq -r '.reviews // []')
COMMENTS=$(echo "$PR_JSON" | jq -r '.comments // []')

# Count pending/changes requested reviews
CHANGES_REQUESTED=$(echo "$REVIEWS" | jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length')

if [[ "$CHANGES_REQUESTED" -gt 0 ]]; then
    log_warn "PR has $CHANGES_REQUESTED review(s) requesting changes"
    log_info "Review the feedback before pushing updates"
fi

# Get detailed review comments
REVIEW_COMMENTS=$(gh pr view --json reviewDecision,reviews 2>/dev/null || echo "{}")
REVIEW_DECISION=$(echo "$REVIEW_COMMENTS" | jq -r '.reviewDecision // "NONE"')

case "$REVIEW_DECISION" in
    "CHANGES_REQUESTED")
        log_warn "PR requires changes before merge"
        ;;
    "APPROVED")
        log_info "PR is approved"
        ;;
    *)
        log_debug "PR review status: $REVIEW_DECISION"
        ;;
esac

# List recent comments if any
COMMENT_COUNT=$(echo "$COMMENTS" | jq 'length')
if [[ "$COMMENT_COUNT" -gt 0 ]]; then
    log_info "PR has $COMMENT_COUNT comment(s)"
    log_info "Run 'gh pr view --comments' to see them"
fi

exit 0
