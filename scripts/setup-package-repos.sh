#!/usr/bin/env bash
#
# Setup script for APT and RPM package repositories
# This configures GitHub Pages-hosted package repositories for automatic updates
#
# Prerequisites:
# - gh CLI authenticated with admin access to the repo
# - gpg available for key generation
#
# Usage:
#   ./scripts/setup-package-repos.sh
#

set -euo pipefail

REPO="aviadshiber/kapsis"
KEY_NAME="Kapsis Package Signing Key"
KEY_EMAIL="aviadshiber@gmail.com"
TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=== Package Repository Setup ==="
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

if ! command -v gpg &>/dev/null; then
    echo "Error: gpg not found. Install with: brew install gnupg"
    exit 1
fi

echo "1. Generating GPG key pair for package signing..."

# Create GPG key batch file
cat > "$TEMP_DIR/gpg-batch" <<EOF
%echo Generating Kapsis package signing key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $KEY_NAME
Name-Email: $KEY_EMAIL
Expire-Date: 0
%no-protection
%commit
%echo Done
EOF

# Generate key
gpg --batch --gen-key "$TEMP_DIR/gpg-batch" 2>/dev/null

# Get key ID
KEY_ID=$(gpg --list-keys --keyid-format LONG "$KEY_EMAIL" | grep -E "^pub" | head -1 | awk '{print $2}' | cut -d'/' -f2)
echo "   ✓ GPG key generated: $KEY_ID"

echo ""
echo "2. Exporting keys..."

# Export public key
gpg --armor --export "$KEY_ID" > "$TEMP_DIR/public.asc"
echo "   ✓ Public key exported"

# Export private key
gpg --armor --export-secret-keys "$KEY_ID" > "$TEMP_DIR/private.asc"
echo "   ✓ Private key exported"

echo ""
echo "3. Adding GPG private key as repository secret..."

gh secret set GPG_PRIVATE_KEY \
    --repo "$REPO" \
    --body "$(cat "$TEMP_DIR/private.asc")"
echo "   ✓ Secret GPG_PRIVATE_KEY added to $REPO"

echo ""
echo "4. Checking GitHub Pages configuration..."

# Check if gh-pages branch exists
if gh api "repos/$REPO/branches/gh-pages" &>/dev/null; then
    echo "   ✓ gh-pages branch already exists"
else
    echo "   Creating gh-pages branch..."

    # Create orphan gh-pages branch with initial structure
    CLONE_DIR="$TEMP_DIR/repo"
    git clone --depth 1 "https://github.com/$REPO.git" "$CLONE_DIR"
    cd "$CLONE_DIR"

    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true

    # Create directory structure
    mkdir -p apt/pool/main/k/kapsis
    mkdir -p apt/dists/stable/main/binary-all
    mkdir -p apt/dists/stable/main/binary-amd64
    mkdir -p rpm/packages
    mkdir -p gpg

    # Add public GPG key
    cp "$TEMP_DIR/public.asc" gpg/kapsis.asc

    # Create README
    cat > README.md <<'README'
# Kapsis Package Repository

This branch hosts APT and RPM package repositories for Kapsis.

## APT (Debian/Ubuntu)

```bash
# Add GPG key
curl -fsSL https://aviadshiber.github.io/kapsis/gpg/kapsis.asc | sudo gpg --dearmor -o /etc/apt/keyrings/kapsis.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/kapsis.gpg] https://aviadshiber.github.io/kapsis/apt stable main" | sudo tee /etc/apt/sources.list.d/kapsis.list

# Install
sudo apt update
sudo apt install kapsis
```

## RPM (Fedora/RHEL/CentOS)

```bash
# Add repository
sudo tee /etc/yum.repos.d/kapsis.repo <<EOF
[kapsis]
name=Kapsis Repository
baseurl=https://aviadshiber.github.io/kapsis/rpm
enabled=1
gpgcheck=1
gpgkey=https://aviadshiber.github.io/kapsis/gpg/kapsis.asc
EOF

# Install
sudo dnf install kapsis
```

## Homebrew (macOS/Linux)

```bash
brew tap aviadshiber/kapsis
brew install kapsis
```
README

    # Create placeholder files for APT structure
    cat > apt/dists/stable/Release <<RELEASE
Origin: Kapsis
Label: Kapsis
Suite: stable
Codename: stable
Architectures: all amd64
Components: main
Description: Kapsis package repository
RELEASE

    touch apt/dists/stable/main/binary-all/Packages
    touch apt/dists/stable/main/binary-amd64/Packages
    gzip -k apt/dists/stable/main/binary-all/Packages
    gzip -k apt/dists/stable/main/binary-amd64/Packages

    # Create placeholder for RPM
    touch rpm/.gitkeep

    # Create index.html
    cat > index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Kapsis Package Repository</title>
    <meta http-equiv="refresh" content="0; url=https://github.com/aviadshiber/kapsis#installation">
</head>
<body>
    <p>Redirecting to <a href="https://github.com/aviadshiber/kapsis#installation">installation instructions</a>...</p>
</body>
</html>
HTML

    git add -A
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git commit -m "Initialize package repository structure"

    # Push using gh CLI's auth
    gh api repos/$REPO/git/refs -X POST \
        -f ref="refs/heads/gh-pages" \
        -f sha="$(git rev-parse HEAD)"

    echo "   ✓ gh-pages branch created with initial structure"
    cd - > /dev/null
fi

echo ""
echo "5. Enabling GitHub Pages..."

# Enable GitHub Pages for gh-pages branch
gh api "repos/$REPO/pages" -X POST \
    -f source='{"branch":"gh-pages","path":"/"}' 2>/dev/null || \
gh api "repos/$REPO/pages" -X PUT \
    -f source='{"branch":"gh-pages","path":"/"}' 2>/dev/null || \
echo "   GitHub Pages may already be configured"

echo "   ✓ GitHub Pages enabled"

echo ""
echo "6. Cleaning up local GPG key..."
gpg --batch --yes --delete-secret-keys "$KEY_ID" 2>/dev/null || true
gpg --batch --yes --delete-keys "$KEY_ID" 2>/dev/null || true
echo "   ✓ Local GPG key removed (only stored in GitHub secrets)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Package repositories will be available at:"
echo "  APT: https://aviadshiber.github.io/kapsis/apt"
echo "  RPM: https://aviadshiber.github.io/kapsis/rpm"
echo "  GPG: https://aviadshiber.github.io/kapsis/gpg/kapsis.asc"
echo ""
echo "The next release will automatically publish packages to these repositories."
echo ""
echo "Test the workflow with:"
echo "  gh workflow run packages.yml --repo $REPO -f version=0.8.4"
