#!/usr/bin/env bash
#===============================================================================
# Kapsis - Git Branch Initialization Script
#
# Initializes a git branch for the AI agent workflow. Can be run standalone
# or is called by the container entrypoint.
#
# Usage:
#   ./init-git-branch.sh <branch-name> [remote]
#
# Behavior:
#   - If remote branch exists: checkout and track it (continue from previous work)
#   - If remote branch doesn't exist: create new branch from current HEAD
#===============================================================================

set -euo pipefail

BRANCH="${1:?Branch name required}"
REMOTE="${2:-origin}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[GIT]${NC} $*"; }
log_success() { echo -e "${GREEN}[GIT]${NC} $*"; }

cd "${WORKSPACE:-/workspace}"

# Ensure we have latest remote refs
log_info "Fetching from $REMOTE..."
git fetch "$REMOTE" --prune 2>/dev/null || log_info "Warning: Could not fetch from $REMOTE"

# Check if remote branch exists
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ CONTINUING FROM EXISTING REMOTE BRANCH                        │"
    echo "│ Branch: $BRANCH"
    echo "│ Remote: $REMOTE"
    echo "└────────────────────────────────────────────────────────────────┘"

    # Checkout tracking the remote branch
    git checkout -b "$BRANCH" "${REMOTE}/${BRANCH}" 2>/dev/null || \
        git checkout "$BRANCH"

    # Ensure we're up to date
    git pull "$REMOTE" "$BRANCH" --ff-only 2>/dev/null || true

    echo ""
    log_info "Recent commits on this branch:"
    git log --oneline -5
    echo ""
else
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ CREATING NEW BRANCH                                            │"
    echo "│ Branch: $BRANCH"
    echo "│ Base: $(git rev-parse --abbrev-ref HEAD)"
    echo "└────────────────────────────────────────────────────────────────┘"

    # Create new branch from current HEAD
    git checkout -b "$BRANCH"
    echo ""
fi

log_success "Ready to work on branch: $BRANCH"
