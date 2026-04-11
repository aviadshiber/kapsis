# Kapsis Cleanup Guide

Reclaim disk space and clean up artifacts after agent work.

## Quick Start

```bash
# See what would be cleaned
./scripts/kapsis-cleanup.sh --dry-run

# Clean everything
./scripts/kapsis-cleanup.sh --all --force
```

## Usage

```bash
./scripts/kapsis-cleanup.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be cleaned without removing anything |
| `--all` | Clean all artifacts (worktrees, sandboxes, status, containers) |
| `--project <name>` | Clean only artifacts for specific project |
| `--agent <proj> <id>` | Clean only specific agent's artifacts |
| `--volumes` | Also clean build cache volumes (Maven, Gradle) |
| `--containers` | Clean stopped Kapsis containers |
| `--logs` | Clean log files older than 7 days |
| `--force`, `-f` | Skip confirmation prompts |
| `--help`, `-h` | Show help message |

### Examples

```bash
# Preview cleanup
./scripts/kapsis-cleanup.sh --dry-run

# Clean all artifacts for a project
./scripts/kapsis-cleanup.sh --project products --force

# Clean specific agent
./scripts/kapsis-cleanup.sh --agent products 1

# Full cleanup including build caches
./scripts/kapsis-cleanup.sh --all --volumes --force

# Clean only old logs
./scripts/kapsis-cleanup.sh --logs
```

## What Gets Cleaned

| Resource | Location | When Cleaned |
|----------|----------|--------------|
| **Worktrees** | `~/.kapsis/worktrees/` | Default |
| **Sandboxes** | `~/.ai-sandboxes/` | Default |
| **Status files** | `~/.kapsis/status/` | Default (completed only) |
| **Sanitized git** | `~/.kapsis/sanitized-git/` | Default |
| **Containers** | Podman | `--all` or `--containers` |
| **Volumes** | Podman | `--volumes` only |
| **Logs** | `~/.kapsis/logs/` | `--all` or `--logs` |

### Worktrees

Git worktrees created for branch-based workflows. Located in `~/.kapsis/worktrees/`.

```bash
# List worktrees
ls -la ~/.kapsis/worktrees/

# Manual cleanup
cd ~/project && git worktree prune
```

### Sandboxes

Overlay upper directories containing agent file changes. Located in `~/.ai-sandboxes/`.

These directories may have special permissions from Podman's user namespace mapping. See [Permission Issues](#permission-issues) below.

### Status Files

JSON status files tracking agent progress. Only **completed** status files are cleaned by default. Active agents are preserved.

```bash
# List status files
ls -la ~/.kapsis/status/

# View specific status
cat ~/.kapsis/status/kapsis-products-1.json
```

### Build Cache Volumes

Per-agent Maven and Gradle cache volumes. Cleaning these requires re-downloading dependencies on next run.

```bash
# List Kapsis volumes
podman volume ls | grep kapsis

# Manual cleanup
podman volume rm kapsis-1-m2 kapsis-1-gradle
```

## Permission Issues

Some sandbox directories have overlay-specific permissions that prevent normal deletion.

### macOS (Podman VM)

On macOS, Podman runs in a VM with different UID mapping:

```bash
# Use sudo to remove overlay directories
sudo rm -rf ~/.ai-sandboxes/kapsis-*
sudo rm -rf ~/.ai-sandboxes/products-*
```

### Linux (Native Podman)

On Linux with rootless Podman, use `podman unshare` to enter the user namespace:

```bash
# Remove overlay directories
podman unshare rm -rf ~/.ai-sandboxes/kapsis-*
podman unshare rm -rf ~/.ai-sandboxes/products-*
```

### Automatic Handling

The cleanup script attempts to handle permissions automatically:
1. First tries normal `rm -rf`
2. On macOS: tries `sudo rm -rf`
3. On Linux: tries `podman unshare rm -rf`
4. If all fail: reports skipped directories with manual instructions

## Cleanup Strategies

### After Each Task

Clean up after completing work on a specific task:

```bash
./scripts/kapsis-cleanup.sh --agent products 1
```

### After PR Merge

Clean up after a PR is merged:

```bash
./scripts/kapsis-cleanup.sh --project products
cd ~/project && git worktree prune
```

### Weekly Maintenance

Periodic cleanup of all old artifacts:

```bash
./scripts/kapsis-cleanup.sh --all --logs --force
```

### Disk Space Emergency

When disk space is critically low:

```bash
# Clean everything including volumes
./scripts/kapsis-cleanup.sh --all --volumes --force

# Also clean Podman system
podman system prune -a --volumes
```

## Automation

### Cron Job

Set up automatic weekly cleanup:

```bash
# Add to crontab (crontab -e)
0 3 * * 0 ~/git/kapsis/scripts/kapsis-cleanup.sh --all --logs --force >> ~/.kapsis/logs/cleanup.log 2>&1
```

### Post-Merge Hook

Add cleanup to your git post-merge hook:

```bash
# In ~/project/.git/hooks/post-merge
#!/bin/bash
~/git/kapsis/scripts/kapsis-cleanup.sh --project "$(basename $(pwd))" --force
```

## Troubleshooting

### Cleanup Hangs

If cleanup hangs, there may be a container still running:

```bash
# Check for running containers
podman ps --filter "name=kapsis"

# Stop all Kapsis containers
podman stop $(podman ps -q --filter "name=kapsis")
```

### Worktree Removal Fails

If worktree removal fails with "is not a working tree":

```bash
# Prune stale worktree references
cd ~/project && git worktree prune

# Force remove directory
rm -rf ~/.kapsis/worktrees/project-agent-1
```

### Volume Still In Use

If volume removal fails:

```bash
# Find containers using the volume
podman ps -a --filter "volume=kapsis-1-m2"

# Remove the container first
podman rm <container-id>

# Then remove volume
podman volume rm kapsis-1-m2
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_DIR` | `~/.kapsis` | Base directory for Kapsis data |
| `KAPSIS_WORKTREE_DIR` | `~/.kapsis/worktrees` | Worktree storage |
| `KAPSIS_STATUS_DIR` | `~/.kapsis/status` | Status file directory |
| `KAPSIS_LOG_DIR` | `~/.kapsis/logs` | Log file directory |
| `KAPSIS_SANDBOX_DIR` | `~/.ai-sandboxes` | Overlay upper directories |

## See Also

- [GIT-WORKFLOW.md](GIT-WORKFLOW.md) - Branch-based workflow documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture and data flow
- [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) - Configuration options
