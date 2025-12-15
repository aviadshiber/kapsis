# Kapsis Setup Guide

Quick guide for new users to set up Kapsis AI agent sandboxes.

## Prerequisites

| Requirement | Minimum | Recommended | Notes |
|-------------|---------|-------------|-------|
| **OS** | macOS 12+ / Linux | macOS 14+ (Apple Silicon) | Windows via WSL2 may work |
| **RAM** | 8 GB | 16+ GB | 8GB per parallel agent |
| **Disk** | 20 GB | 50+ GB | Container image + caches |
| **Podman** | 4.0 | 5.0+ | Container runtime |
| **Git** | 2.0 | Latest | For worktree mode |

## Quick Start

### 1. Run Setup Script

```bash
# Clone the repo (if you haven't)
git clone <kapsis-repo-url>
cd kapsis

# Run interactive setup
./setup.sh

# Or full automated setup
./setup.sh --all
```

### 2. Set Your API Key

```bash
# Add to ~/.zshrc or ~/.bashrc
export ANTHROPIC_API_KEY="your-api-key-here"

# Reload shell
source ~/.zshrc
```

### 3. Build Container Image

```bash
./scripts/build-image.sh
```

### 4. Launch Your First Agent

```bash
# Interactive shell in sandbox
./scripts/launch-agent.sh 1 ~/your-project

# With git branch (recommended)
./scripts/launch-agent.sh 1 ~/your-project --branch feature/test

# With task specification
./scripts/launch-agent.sh 1 ~/your-project --branch feature/DEV-123 --spec task.md
```

## Setup Script Options

```bash
./setup.sh --check      # Check dependencies only
./setup.sh --install    # Install missing deps
./setup.sh --build      # Build container image
./setup.sh --config     # Create config file
./setup.sh --validate   # Run tests
./setup.sh --all        # Everything
```

## Manual Installation

### macOS (Homebrew)

```bash
# Install Homebrew if needed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
brew install podman git yq

# Initialize Podman machine
podman machine init --cpus 4 --memory 8192 --disk-size 100
podman machine start
```

### Linux (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y podman git

# Install yq
sudo snap install yq
# Or: sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
```

### Linux (RHEL/Fedora)

```bash
sudo dnf install -y podman git
```

## Configuration

### Basic Config (`agent-sandbox.yaml`)

```yaml
agent:
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""
  workdir: /workspace

filesystem:
  include:
    - ~/.claude
    - ~/.gitconfig
    - ~/.ssh

environment:
  passthrough:
    - ANTHROPIC_API_KEY
  set:
    MAVEN_OPTS: "-Xmx4g"

resources:
  memory: 8g
  cpus: 4

maven:
  mirror_url: "https://repo1.maven.org/maven2"
  block_remote_snapshots: true
  block_deploy: true
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes* | Claude API key |
| `OPENAI_API_KEY` | Yes* | For Codex/GPT agents |
| `BITBUCKET_TOKEN` | No | Git operations |
| `GITHUB_TOKEN` | No | GitHub API access |

*At least one AI API key required

## Verify Installation

```bash
# Check all dependencies
./setup.sh --check

# Run quick tests (no container)
./tests/run-all-tests.sh --quick

# Run full test suite
./tests/run-all-tests.sh
```

## Troubleshooting

### Podman Machine Won't Start (macOS)

```bash
# Reset machine
podman machine stop
podman machine rm
podman machine init --cpus 4 --memory 8192
podman machine start
```

### Permission Denied Errors

```bash
# Ensure scripts are executable
chmod +x scripts/*.sh setup.sh quick-start.sh

# Check SSH key permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_*
```

### Container Build Fails

```bash
# Check Podman is running
podman info

# Clean and rebuild
podman system prune -a
./scripts/build-image.sh
```

### Git Push Fails in Agent

1. Ensure SSH keys are mounted (`~/.ssh` in filesystem.include)
2. Check SSH agent is running
3. Verify git config has user.name and user.email

## Next Steps

1. **Read Architecture**: [docs/ARCHITECTURE.md](ARCHITECTURE.md)
2. **Create Custom Config**: Copy `configs/claude.yaml` and customize
3. **Try Parallel Agents**: Launch multiple agents on same project
4. **Explore Worktree Mode**: Use `--branch` for git-based isolation

## Getting Help

- Check logs: `~/.kapsis/logs/`
- Run diagnostics: `./setup.sh --check`
- Run tests: `./tests/run-all-tests.sh --quick`
