#!/usr/bin/env bash
#
# Setup script for GitHub App-based release workflow
#
# This creates a GitHub App that can bypass branch protection rules
# for automated releases, while blocking all other direct pushes.
#
# Prerequisites:
# - gh CLI authenticated with admin access
#
# Usage:
#   ./scripts/setup-release-app.sh
#

set -euo pipefail

REPO="aviadshiber/kapsis"
APP_NAME="kapsis-release-bot"

echo "=== GitHub App Setup for Releases ==="
echo ""
echo "This script will guide you through creating a GitHub App for secure releases."
echo ""
echo "A GitHub App is required because:"
echo "  - PATs inherit user permissions (can't distinguish user vs workflow)"
echo "  - GitHub Actions integration can't be bypass actor for personal repos"
echo "  - Apps can be specifically allowlisted in rulesets"
echo ""

# Check prerequisites
if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI not authenticated. Run: gh auth login"
    exit 1
fi

echo "=== Step 1: Create GitHub App ==="
echo ""
echo "Please create a GitHub App manually at:"
echo "  https://github.com/settings/apps/new"
echo ""
echo "Use these settings:"
echo "  - Name: $APP_NAME (or similar unique name)"
echo "  - Homepage URL: https://github.com/$REPO"
echo "  - Webhook: UNCHECK 'Active' (not needed)"
echo ""
echo "Repository permissions required:"
echo "  - Contents: Read and write"
echo "  - Metadata: Read-only (auto-selected)"
echo ""
echo "Where can this app be installed: 'Only on this account'"
echo ""
read -p "Press Enter after creating the app..."

echo ""
echo "=== Step 2: Generate Private Key ==="
echo ""
echo "On the app settings page, scroll to 'Private keys' and click 'Generate a private key'"
echo "Save the downloaded .pem file securely."
echo ""
read -p "Press Enter after downloading the private key..."

echo ""
echo "=== Step 3: Install App on Repository ==="
echo ""
echo "1. Go to: https://github.com/settings/apps/$APP_NAME/installations"
echo "2. Click 'Install'"
echo "3. Select 'Only select repositories'"
echo "4. Choose: $REPO"
echo "5. Click 'Install'"
echo ""
read -p "Press Enter after installing the app..."

echo ""
echo "=== Step 4: Get App ID and Installation ID ==="
echo ""
echo "From the app settings page, note the 'App ID' (a number like 123456)"
read -p "Enter the App ID: " APP_ID

# Get installation ID
echo ""
echo "Getting installation ID..."
INSTALLATION_ID=$(gh api "users/aviadshiber/installation" --jq '.id' 2>/dev/null || echo "")

if [[ -z "$INSTALLATION_ID" ]]; then
    echo "Could not auto-detect installation ID."
    echo "Go to: https://github.com/settings/installations"
    echo "Click on $APP_NAME, the URL will contain the installation ID"
    read -p "Enter the Installation ID: " INSTALLATION_ID
else
    echo "Found Installation ID: $INSTALLATION_ID"
fi

echo ""
echo "=== Step 5: Add Secrets to Repository ==="
echo ""
echo "Add the following secrets to the repository:"
echo ""

# Read private key
read -p "Enter path to the private key .pem file: " PEM_PATH
if [[ ! -f "$PEM_PATH" ]]; then
    echo "Error: File not found: $PEM_PATH"
    exit 1
fi

echo ""
echo "Adding APP_ID secret..."
gh secret set RELEASE_APP_ID --repo "$REPO" --body "$APP_ID"
echo "✓ RELEASE_APP_ID added"

echo ""
echo "Adding APP_INSTALLATION_ID secret..."
gh secret set RELEASE_APP_INSTALLATION_ID --repo "$REPO" --body "$INSTALLATION_ID"
echo "✓ RELEASE_APP_INSTALLATION_ID added"

echo ""
echo "Adding APP_PRIVATE_KEY secret..."
gh secret set RELEASE_APP_PRIVATE_KEY --repo "$REPO" < "$PEM_PATH"
echo "✓ RELEASE_APP_PRIVATE_KEY added"

echo ""
echo "=== Step 6: Update Ruleset Bypass ==="
echo ""
echo "Now add the app as a bypass actor in the ruleset."
echo ""
read -p "Enter the App's actor ID (same as App ID): " ACTOR_ID

# Update ruleset with app bypass
gh api "repos/$REPO/rulesets/11300650" -X PUT \
  --input - << EOF
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    }
  ],
  "bypass_actors": [
    {
      "actor_id": $ACTOR_ID,
      "actor_type": "Integration",
      "bypass_mode": "always"
    }
  ]
}
EOF

echo "✓ Ruleset updated with app bypass"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Update .github/workflows/release.yml to use the app token"
echo "2. Remove RELEASE_TOKEN from workflow (replace with app token generation)"
echo ""
echo "The release workflow will need to generate a token using:"
echo "  - uses: actions/create-github-app-token@v1"
echo "    with:"
echo "      app-id: \${{ secrets.RELEASE_APP_ID }}"
echo "      private-key: \${{ secrets.RELEASE_APP_PRIVATE_KEY }}"
echo ""
echo "See: https://github.com/actions/create-github-app-token"
