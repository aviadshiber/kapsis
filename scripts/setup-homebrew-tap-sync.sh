#!/usr/bin/env bash
#
# Setup script for Homebrew tap sync
# This configures automatic syncing of the formula to aviadshiber/homebrew-kapsis
#
# Prerequisites:
# - gh CLI authenticated with admin access to both repos
# - ssh-keygen available
#
# Usage:
#   ./scripts/setup-homebrew-tap-sync.sh
#

set -euo pipefail

KAPSIS_REPO="aviadshiber/kapsis"
TAP_REPO="aviadshiber/homebrew-kapsis"
KEY_NAME="kapsis-tap-deploy"
TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=== Homebrew Tap Sync Setup ==="
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

echo "1. Generating deploy key pair..."
ssh-keygen -t ed25519 -C "$KEY_NAME" -f "$TEMP_DIR/deploy_key" -N "" -q
echo "   ✓ Key pair generated"

echo ""
echo "2. Adding public key to $TAP_REPO as deploy key..."
PUBLIC_KEY=$(cat "$TEMP_DIR/deploy_key.pub")

# Check if deploy key already exists
EXISTING_KEY=$(gh api "repos/$TAP_REPO/keys" --jq ".[] | select(.title == \"$KEY_NAME\") | .id" 2>/dev/null || echo "")
if [[ -n "$EXISTING_KEY" ]]; then
    echo "   Removing existing deploy key..."
    gh api "repos/$TAP_REPO/keys/$EXISTING_KEY" -X DELETE
fi

gh api "repos/$TAP_REPO/keys" \
    -X POST \
    -f title="$KEY_NAME" \
    -f key="$PUBLIC_KEY" \
    -F read_only=false \
    --silent
echo "   ✓ Deploy key added to $TAP_REPO (with write access)"

echo ""
echo "3. Adding private key as secret to $KAPSIS_REPO..."
PRIVATE_KEY=$(cat "$TEMP_DIR/deploy_key")

gh secret set TAP_DEPLOY_KEY \
    --repo "$KAPSIS_REPO" \
    --body "$PRIVATE_KEY"
echo "   ✓ Secret TAP_DEPLOY_KEY added to $KAPSIS_REPO"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "The sync workflow will now automatically update the tap when"
echo "packaging/homebrew/kapsis.rb changes on main branch."
echo ""
echo "Test it with:"
echo "  gh workflow run sync-homebrew-tap.yml --repo $KAPSIS_REPO"
