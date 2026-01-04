#!/usr/bin/env bash
#===============================================================================
# Kapsis Pre-push: Create PR
#
# Creates a GitHub PR if one doesn't exist for the current branch.
# Uses gh CLI to create the PR with auto-filled title and body.
#
# Exit codes:
#   0 - PR exists or was created successfully
#   1 - Failed to create PR
#   2 - gh CLI not available
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$REPO_ROOT/scripts/lib/logging.sh" ]]; then
    source "$REPO_ROOT/scripts/lib/logging.sh"
    log_init "prepush-create-pr"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
fi

# Check if gh CLI is available
if ! command -v gh &>/dev/null; then
    log_warn "gh CLI not installed, skipping PR creation"
    exit 0
fi

# Check if authenticated
if ! gh auth status &>/dev/null 2>&1; then
    log_warn "Not authenticated with GitHub, skipping PR creation"
    exit 0
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

if [[ -z "$CURRENT_BRANCH" ]]; then
    log_debug "Not on a branch, skipping"
    exit 0
fi

# Skip if on main/master
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    log_debug "On main branch, skipping PR creation"
    exit 0
fi

# Check if PR already exists
if gh pr view &>/dev/null 2>&1; then
    PR_URL=$(gh pr view --json url -q '.url' 2>/dev/null)
    log_info "PR already exists: $PR_URL"
    exit 0
fi

log_info "No PR found for branch: $CURRENT_BRANCH"
log_info "Creating PR..."

# Get commit messages for PR body
COMMITS=$(git log origin/main..HEAD --oneline 2>/dev/null || git log HEAD~5..HEAD --oneline 2>/dev/null || echo "")

# Extract feature name from branch
FEATURE_NAME="${CURRENT_BRANCH##*/}"
FEATURE_NAME="${FEATURE_NAME//-/ }"  # Replace hyphens with spaces

# Create PR body
PR_BODY=$(cat <<EOF
## Summary

$FEATURE_NAME

## Changes

$COMMITS

## Test Plan

- [ ] Ran quick tests: \`./tests/run-all-tests.sh --quick\`
- [ ] Ran full tests: \`./tests/run-all-tests.sh\`
- [ ] Manual testing completed

---
*Created by Kapsis pre-push hook*
EOF
)

# Create the PR
if gh pr create --fill --body "$PR_BODY" 2>&1; then
    PR_URL=$(gh pr view --json url -q '.url' 2>/dev/null)
    log_info "PR created: $PR_URL"
else
    log_warn "Failed to create PR - you may need to push first"
    log_info "Create PR manually after push: gh pr create"
fi

exit 0
