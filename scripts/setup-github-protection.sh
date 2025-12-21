#!/usr/bin/env bash
#
# Setup GitHub Branch Protection Rules
#
# This script configures branch protection rules to enforce:
# - All changes must go through pull requests (no direct pushes)
# - CI checks must pass before merging
# - Optional: Require pull request reviews
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated
#   - Admin access to the repository
#
# Usage:
#   ./scripts/setup-github-protection.sh [OPTIONS]
#
# Options:
#   --branch BRANCH    Branch to protect (default: main)
#   --require-reviews  Require at least 1 PR review (default: disabled)
#   --review-count N   Number of required reviews (default: 1)
#   --dry-run          Show what would be done without making changes
#   --help             Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
BRANCH="main"
REQUIRE_REVIEWS=false
REVIEW_COUNT=1
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --require-reviews)
            REQUIRE_REVIEWS=true
            shift
            ;;
        --review-count)
            REVIEW_COUNT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            head -30 "$0" | tail -27
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if gh is installed
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed."
        echo "Install it from: https://cli.github.com/"
        exit 1
    fi

    # Check if gh is authenticated
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI is not authenticated."
        echo "Run: gh auth login"
        exit 1
    fi

    # Get repository info
    if ! REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null); then
        log_error "Not in a GitHub repository or cannot access repo info."
        exit 1
    fi

    log_success "Prerequisites OK. Repository: $REPO"
}

# Get the current protection rules (if any)
get_current_rules() {
    log_info "Checking current protection rules for branch '$BRANCH'..."

    if gh api "repos/{owner}/{repo}/branches/$BRANCH/protection" &>/dev/null; then
        log_warn "Branch '$BRANCH' already has protection rules."
        echo ""
        gh api "repos/{owner}/{repo}/branches/$BRANCH/protection" 2>/dev/null | jq '.' || true
        echo ""
        read -p "Do you want to update the existing rules? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted. No changes made."
            exit 0
        fi
    else
        log_info "No existing protection rules found."
    fi
}

# Build the protection rules JSON
build_protection_rules() {
    local rules

    # Base rules - require PR, require status checks
    rules=$(cat <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["CI Success"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": true
}
EOF
)

    # Add PR review requirements if requested
    if [[ "$REQUIRE_REVIEWS" == "true" ]]; then
        rules=$(echo "$rules" | jq --argjson count "$REVIEW_COUNT" '.required_pull_request_reviews = {
            "dismissal_restrictions": {},
            "dismiss_stale_reviews": true,
            "require_code_owner_reviews": false,
            "required_approving_review_count": $count,
            "require_last_push_approval": false
        }')
    fi

    echo "$rules"
}

# Apply protection rules
apply_protection() {
    local rules
    rules=$(build_protection_rules)

    echo ""
    log_info "Protection rules to be applied:"
    echo "$rules" | jq '.'
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would apply the above rules to branch '$BRANCH'"
        return 0
    fi

    log_info "Applying protection rules to branch '$BRANCH'..."

    if echo "$rules" | gh api \
        --method PUT \
        "repos/{owner}/{repo}/branches/$BRANCH/protection" \
        --input - > /dev/null; then
        log_success "Branch protection rules applied successfully!"
    else
        log_error "Failed to apply branch protection rules."
        exit 1
    fi
}

# Show summary
show_summary() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Branch Protection Setup Complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Protected branch: $BRANCH"
    echo ""
    echo "Rules applied:"
    echo "  - Direct pushes to '$BRANCH' are blocked"
    echo "  - All changes must go through pull requests"
    echo "  - CI checks must pass before merging"
    echo "  - Branch must be up-to-date with base before merging"
    if [[ "$REQUIRE_REVIEWS" == "true" ]]; then
        echo "  - At least $REVIEW_COUNT PR review(s) required"
        echo "  - Stale reviews are dismissed on new pushes"
    fi
    echo ""
    echo "CI workflow: .github/workflows/ci.yml"
    echo "Required check: 'CI Success'"
    echo ""
    echo "To verify, visit:"
    echo "  https://github.com/$REPO/settings/branches"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "GitHub Branch Protection Setup"
    echo "==============================="
    echo ""

    check_prerequisites
    get_current_rules
    apply_protection

    if [[ "$DRY_RUN" != "true" ]]; then
        show_summary
    fi
}

main
