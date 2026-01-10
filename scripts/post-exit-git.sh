#!/usr/bin/env bash
#===============================================================================
# Kapsis - Post-Exit Git Operations Script
#
# Commits and optionally pushes changes after agent exits.
# Can be run standalone or is called by the container entrypoint via trap.
#
# Usage:
#   ./post-exit-git.sh <branch> <commit-message> [remote] [--no-push]
#
# Environment Variables:
#   KAPSIS_AGENT_ID  - Agent identifier for commit message
#   KAPSIS_NO_PUSH   - Set to "true" to skip push
#===============================================================================

set -euo pipefail

BRANCH="${1:?Branch name required}"
COMMIT_MSG="${2:?Commit message required}"
REMOTE="${3:-origin}"
NO_PUSH="${4:-false}"

# Override with environment variable if set
NO_PUSH="${KAPSIS_NO_PUSH:-$NO_PUSH}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[GIT]${NC} $*"; }
log_success() { echo -e "${GREEN}[GIT]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[GIT]${NC} $*"; }

# Source git remote utilities (provides generate_pr_url, detect_git_provider, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_HOME="${KAPSIS_HOME:-/opt/kapsis}"
if [[ -f "$KAPSIS_HOME/lib/git-remote-utils.sh" ]]; then
    source "$KAPSIS_HOME/lib/git-remote-utils.sh"
elif [[ -f "$SCRIPT_DIR/lib/git-remote-utils.sh" ]]; then
    source "$SCRIPT_DIR/lib/git-remote-utils.sh"
fi

cd "${WORKSPACE:-/workspace}"

# Check if there are changes
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ NO CHANGES TO COMMIT                                           │"
    echo "│ Working directory is clean                                     │"
    echo "└────────────────────────────────────────────────────────────────┘"
    exit 0
fi

# Verify we're on the right branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    log_warn "Current branch ($CURRENT_BRANCH) differs from expected ($BRANCH)"
    git checkout "$BRANCH" 2>/dev/null || {
        log_warn "Could not checkout $BRANCH, staying on $CURRENT_BRANCH"
        BRANCH="$CURRENT_BRANCH"
    }
fi

# Stage all changes
git add -A

echo ""
echo "┌────────────────────────────────────────────────────────────────┐"
echo "│ COMMITTING CHANGES                                             │"
echo "└────────────────────────────────────────────────────────────────┘"
git status --short
echo ""

# Commit
git commit -m "$COMMIT_MSG" || {
    log_warn "Commit failed or nothing to commit"
    exit 0
}

# Push (unless --no-push)
if [[ "$NO_PUSH" != "true" ]]; then
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ PUSHING TO REMOTE                                              │"
    echo "└────────────────────────────────────────────────────────────────┘"

    git push --set-upstream "$REMOTE" "$BRANCH" || {
        log_warn "Push failed. Changes are committed locally."
        echo ""
        echo "┌────────────────────────────────────────────────────────────────┐"
        echo "│ PUSH FALLBACK (for agent recovery)                             │"
        echo "└────────────────────────────────────────────────────────────────┘"
        echo "KAPSIS_PUSH_FALLBACK: git push $REMOTE $BRANCH"
        echo ""
        echo "The orchestrating agent can run this command from the host where"
        echo "git credentials are available."
        echo ""
        exit 1
    }

    # Generate PR URL using git-remote-utils library
    REMOTE_URL=$(git remote get-url "$REMOTE" 2>/dev/null || echo "")

    echo ""
    if [[ -n "$REMOTE_URL" ]] && type generate_pr_url &>/dev/null; then
        PR_URL=$(generate_pr_url "$REMOTE_URL" "$BRANCH")
        PR_TERM=$(get_pr_term "$REMOTE_URL")
        if [[ -n "$PR_URL" ]]; then
            echo "Create/View ${PR_TERM}: ${PR_URL}"
        fi
    fi

    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ CHANGES PUSHED SUCCESSFULLY                                    │"
    echo "│                                                                │"
    echo "│ To continue after PR review:                                   │"
    echo "│   ./launch-agent.sh <id> <project> \\                          │"
    echo "│       --branch $BRANCH \\                                      │"
    echo "│       --spec ./updated-spec.md                                 │"
    echo "└────────────────────────────────────────────────────────────────┘"
else
    echo ""
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│ CHANGES COMMITTED LOCALLY (--no-push)                          │"
    echo "│                                                                │"
    echo "│ To push later:                                                 │"
    echo "│   git push $REMOTE $BRANCH                                     │"
    echo "└────────────────────────────────────────────────────────────────┘"
fi
