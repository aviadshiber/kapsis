#!/usr/bin/env bash
#===============================================================================
# Kapsis - Git Branch Initialization Script
#
# Initializes a git branch for the AI agent workflow. Can be run standalone
# or is called by the container entrypoint.
#
# Usage:
#   ./init-git-branch.sh <branch-name> [remote] [base-branch]
#
# Arguments:
#   branch-name  - Target branch to create or checkout
#   remote       - Git remote name (default: origin)
#   base-branch  - Base branch/tag for new branches (default: current HEAD)
#                  Fix #116: Ensures branches are created from correct base
#
# Behavior:
#   - If remote branch exists: checkout and track it (continue from previous work)
#   - If remote branch doesn't exist: create new branch from base-branch or HEAD
#===============================================================================

set -euo pipefail

BRANCH="${1:?Branch name required}"
REMOTE="${2:-origin}"
BASE_BRANCH="${3:-}"  # Fix #116: Optional base branch/tag

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
    # Fix #116: Use BASE_BRANCH if specified, otherwise current HEAD
    base_ref="${BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ CREATING NEW BRANCH                                            │"
    echo "│ Branch: $BRANCH"
    echo "│ Base: $base_ref"
    echo "└────────────────────────────────────────────────────────────────┘"

    # Create new branch from specified base or current HEAD
    if [[ -n "$BASE_BRANCH" ]]; then
        # Ensure we have the base ref
        git fetch "$REMOTE" "$BASE_BRANCH" 2>/dev/null || true
        git fetch "$REMOTE" "refs/tags/$BASE_BRANCH:refs/tags/$BASE_BRANCH" 2>/dev/null || true

        if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
            git checkout -b "$BRANCH" "$BASE_BRANCH"
        else
            log_info "Warning: Base ref '$BASE_BRANCH' not found, using current HEAD"
            git checkout -b "$BRANCH"
        fi
    else
        git checkout -b "$BRANCH"
    fi
    echo ""
fi

log_success "Ready to work on branch: $BRANCH"
