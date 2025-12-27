# Installation Guide

This guide covers all available methods to install Kapsis on your system.

## Package Managers (Recommended)

Using a package manager is the recommended way to install Kapsis. Package managers provide automatic updates, dependency management, and clean uninstallation.

### Homebrew (macOS and Linux)

```bash
# Add the Kapsis tap
brew tap aviadshiber/kapsis

# Install Kapsis
brew install kapsis

# Upgrade to latest version
brew upgrade kapsis
```

### Debian/Ubuntu (APT)

Download the `.deb` package from the [releases page](https://github.com/aviadshiber/kapsis/releases):

```bash
# Get latest version automatically
VERSION=$(curl -s https://api.github.com/repos/aviadshiber/kapsis/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')

# Download package and checksums
curl -LO "https://github.com/aviadshiber/kapsis/releases/download/v${VERSION}/kapsis_${VERSION}-1_all.deb"
curl -LO "https://github.com/aviadshiber/kapsis/releases/download/v${VERSION}/checksums.sha256"

# Verify checksum (IMPORTANT: always verify before installing)
grep "kapsis_${VERSION}-1_all.deb" checksums.sha256 | sha256sum -c -

# Install (apt handles dependencies automatically)
sudo apt install "./kapsis_${VERSION}-1_all.deb"
```

#### Using APT Repository (Future)

We plan to set up an APT repository for easier updates:

```bash
# Add repository (coming soon)
echo "deb https://apt.kapsis.dev stable main" | sudo tee /etc/apt/sources.list.d/kapsis.list
curl -fsSL https://apt.kapsis.dev/gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/kapsis.gpg
sudo apt update
sudo apt install kapsis
```

### Fedora/RHEL/CentOS (DNF/YUM)

Download the `.rpm` package from the [releases page](https://github.com/aviadshiber/kapsis/releases):

```bash
# Get latest version automatically
VERSION=$(curl -s https://api.github.com/repos/aviadshiber/kapsis/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')

# Download package and checksums
curl -LO "https://github.com/aviadshiber/kapsis/releases/download/v${VERSION}/kapsis-${VERSION}-1.noarch.rpm"
curl -LO "https://github.com/aviadshiber/kapsis/releases/download/v${VERSION}/checksums.sha256"

# Verify checksum (IMPORTANT: always verify before installing)
grep "kapsis-${VERSION}-1.noarch.rpm" checksums.sha256 | sha256sum -c -

# Install with dnf (Fedora) - handles dependencies automatically
sudo dnf install "./kapsis-${VERSION}-1.noarch.rpm"

# Or install with yum (RHEL/CentOS)
sudo yum install "./kapsis-${VERSION}-1.noarch.rpm"
```

#### Using DNF Repository (Future)

```bash
# Add repository (coming soon)
sudo dnf config-manager --add-repo https://rpm.kapsis.dev/kapsis.repo
sudo dnf install kapsis
```

## Security Best Practices

When installing packages manually:

1. **Always verify checksums** - Each release includes a `checksums.sha256` file
2. **Filter checksums explicitly** - Use `grep "filename" checksums.sha256 | sha256sum -c -` to verify specific files (never use `--ignore-missing`)
3. **Use explicit paths** - Use `./package.deb` not wildcards like `*.deb`
4. **Pin versions** - Specify exact version numbers, not wildcards
5. **Download from official sources** - Only use GitHub releases or official package repos

### Cross-Platform Checksum Verification

```bash
# Linux (sha256sum)
grep "filename" checksums.sha256 | sha256sum -c -

# macOS (shasum)
grep "filename" checksums.sha256 | shasum -a 256 -c -
```

## Universal Install Script

For systems without a supported package manager, you can use the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash
```

This will install Kapsis to `~/.local` and add it to your PATH.

### Install Script Options

```bash
# Install specific version
KAPSIS_VERSION=1.0.0 curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash

# Install to custom location
KAPSIS_PREFIX=/opt/kapsis curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash

# Skip PATH modification
KAPSIS_NO_MODIFY_PATH=1 curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash
```

## Manual Installation

For users who prefer manual installation or need to customize the setup:

```bash
# Clone the repository
git clone https://github.com/aviadshiber/kapsis.git
cd kapsis

# Run setup (checks dependencies and builds container)
./setup.sh --all
```

### From Release Tarball

```bash
# Download release
VERSION=1.0.0
curl -LO https://github.com/aviadshiber/kapsis/archive/refs/tags/v${VERSION}.tar.gz
tar xzf v${VERSION}.tar.gz
cd kapsis-${VERSION}

# Run setup
./setup.sh --all
```

## Post-Installation

After installing Kapsis, you need to set up the container environment:

### 1. Install Podman

Kapsis requires Podman for container isolation.

**macOS:**
```bash
brew install podman
podman machine init
podman machine start
```

**Debian/Ubuntu:**
```bash
sudo apt install podman
```

**Fedora:**
```bash
sudo dnf install podman
```

**Arch Linux:**
```bash
sudo pacman -S podman
```

### 2. Build Container Image

```bash
kapsis-setup --build
```

Or build manually:

```bash
kapsis-build
```

### 3. Verify Installation

```bash
kapsis-setup --check
```

## Upgrading

### Homebrew
```bash
brew upgrade kapsis
```

### APT
```bash
sudo apt update
sudo apt upgrade kapsis
```

### DNF
```bash
sudo dnf upgrade kapsis
```

### Universal Install Script
Re-run the install script to upgrade:
```bash
curl -fsSL https://raw.githubusercontent.com/aviadshiber/kapsis/main/scripts/install.sh | bash
```

## Uninstalling

### Homebrew
```bash
brew uninstall kapsis
brew untap aviadshiber/kapsis
```

### APT
```bash
sudo apt remove kapsis
```

### DNF
```bash
sudo dnf remove kapsis
```

### Universal Install Script / Manual
```bash
# Remove installed files
rm -rf ~/.local/lib/kapsis
rm -rf ~/.local/share/kapsis
rm -f ~/.local/bin/kapsis*

# Remove Kapsis data (optional)
rm -rf ~/.kapsis
```

## Available Commands

After installation, the following commands are available:

| Command | Description |
|---------|-------------|
| `kapsis` | Main command to launch AI agents |
| `kapsis-build` | Build container images |
| `kapsis-cleanup` | Clean up containers and disk space |
| `kapsis-status` | Show status of running agents |
| `kapsis-setup` | Validate and configure installation |
| `kapsis-quick` | Quick start for common workflows |

## Troubleshooting

### Command not found after installation

Ensure the bin directory is in your PATH:

```bash
# For bash/zsh
export PATH="$HOME/.local/bin:$PATH"

# Add to your shell rc file
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

### Podman not starting (macOS)

```bash
podman machine stop
podman machine rm
podman machine init
podman machine start
```

### Permission denied errors

Kapsis runs containers rootless. Ensure your user has proper subuid/subgid mappings:

```bash
# Check mappings
cat /etc/subuid
cat /etc/subgid

# Add if missing (replace USER with your username)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 USER
```

### Container image build fails

Try building with verbose output:

```bash
KAPSIS_DEBUG=1 kapsis-build
```

## System Requirements

- **OS:** macOS 12+, Ubuntu 20.04+, Fedora 35+, Debian 11+, RHEL 8+
- **Podman:** 4.0 or later
- **Git:** 2.0 or later
- **Bash:** 3.2 or later
- **Disk:** 5GB for container images
- **Memory:** 4GB RAM minimum, 8GB recommended
