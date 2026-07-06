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
| `--all` | Clean all artifacts (worktrees, sandboxes, status, containers, images) |
| `--project <name>` | Clean only artifacts for specific project |
| `--agent <proj> <id>` | Clean only specific agent's artifacts |
| `--volumes` | Also clean build cache volumes (Maven, Gradle) |
| `--images` | Clean unused Kapsis container images and dangling layers (in-use and keep-pattern-protected images are skipped) |
| `--prune-dangling` | Prune only dangling (`<none>:<none>`) build layers — cheap, in-use-safe, recommended for cron/housekeepers |
| `--containers` | Clean stopped Kapsis containers |
| `--logs` | Clean log files older than 7 days |
| `--ssh-cache` | Clear cached SSH host keys from keychain |
| `--branches` | Clean stale agent branches (requires `--project`) |
| `--snapshots` | Clean per-agent snapshot dirs in `~/.kapsis/snapshots/` (included by default; explicit form for scripting) |
| `--snapshots-older-than <days>` | Override the default 14-day TTL when cleaning snapshots |
| `--vm-health` | Check Podman VM health: inode %, disk %, journal size (**macOS only**) |
| `--include-active` | Bypass the worktree in-use guard (Issue #428) and remove worktrees even if they appear to belong to an active agent. Requires `--force`. **Dangerous** — see [In-Use Guard](#in-use-guard-issue-428) |
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

# Cheap, in-use-safe dangling layer prune (ideal for cron)
./scripts/kapsis-cleanup.sh --prune-dangling --force

# Check Podman VM health (macOS only)
./scripts/kapsis-cleanup.sh --vm-health

# Dry-run VM health check (metrics only, no remediation)
./scripts/kapsis-cleanup.sh --vm-health --dry-run
```

## What Gets Cleaned

| Resource | Location | When Cleaned |
|----------|----------|--------------|
| **Worktrees** | `~/.kapsis/worktrees/` | Default |
| **Sandboxes** | `~/.ai-sandboxes/` | Default |
| **Status files** | `~/.kapsis/status/` | Default (completed only) |
| **Sanitized git** | `~/.kapsis/sanitized-git/` | Default |
| **Snapshots** | `~/.kapsis/snapshots/` | Default (14-day TTL or `--all`) |
| **Containers** | Podman | `--all` or `--containers` |
| **Images** | Podman | `--all` or `--images` (in-use/protected images skipped) |
| **Dangling layers** | Podman | `--all`, `--images`, or `--prune-dangling` |
| **Volumes** | Podman | `--volumes` only |
| **Logs** | `~/.kapsis/logs/` | `--all` or `--logs` |
| **Audit files** | `~/.kapsis/audit/` | `--all` (TTL-based) |
| **Conversations** | `~/.kapsis/conversations/` | Default (TTL-based; default 7 days via `KAPSIS_DEFAULT_CONVERSATIONS_TTL_DAYS`) |
| **SSH cache** | System keychain | `--ssh-cache` |

### Worktrees

Git worktrees created for branch-based workflows. Located in `~/.kapsis/worktrees/`.

```bash
# List worktrees
ls -la ~/.kapsis/worktrees/

# Manual cleanup
cd ~/project && git worktree prune
```

#### In-Use Guard (Issue #428)

`clean_worktrees()` no longer removes a worktree unconditionally — it first
checks whether the worktree still belongs to an active agent, using a
proportional-certainty guard (`scripts/lib/worktree-guard.sh`):

1. **Terminal success (`phase: "complete"`)** — reaped unconditionally, with
   zero Podman dependency. This is the only unambiguous "safe to reap"
   signal, so a Podman outage or `podman` being absent from `PATH` never
   blocks reclaiming these worktrees.
2. **Terminal failure (`phase: error/failed/killed`)** — falls back to the
   same age heuristic as `worktree-manager.sh`'s opportunistic GC: directory
   mtime vs. `KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS` (default 168h/7 days).
3. **Ambiguous (`phase: running/initializing/...`, or a missing status
   file)** — freshness of `status.json`'s `updated_at` against the liveness
   timeout+grace (`KAPSIS_LIVENESS_TIMEOUT` + `KAPSIS_LIVENESS_GRACE_PERIOD`,
   default 900s+300s = 1200s) decides "in use" (skipped) vs. "stale" (falls
   through to step 4).
4. **Best-effort Podman corroboration** — for stale/ambiguous entries only,
   a `podman ps --filter label=kapsis.agent-id=<id>` check (timeout-wrapped)
   can confirm a live container and force a skip. **Fail-open**: if Podman
   is unreachable, times out, or has no timeout binary available, the check
   is skipped and the verdict degrades to the age heuristic above — it
   never blocks reaping unrelated complete-phase worktrees in the same run,
   and it never forces a "reap" verdict by itself.

Skipped worktrees are reported as `[SKIPPED]` with a reason and are **not**
counted toward the cleaned-item/space-freed totals.

**Escape hatch:** `--include-active` (requires `--force`) bypasses the guard
entirely and removes worktrees regardless of phase or heartbeat freshness.
This is logged at `WARN` and intended only for operators who understand the
risk of deleting a live agent's uncommitted work:

```bash
./scripts/kapsis-cleanup.sh --worktrees --include-active --force
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

Per-agent named volumes. Cleaning the build caches requires re-downloading dependencies on next run.

| Volume | Contents | Platform |
|--------|----------|----------|
| `kapsis-<agent-id>-m2` | Maven repository cache | All |
| `kapsis-<agent-id>-gradle` | Gradle cache | All |
| `kapsis-<agent-id>-ge` | Gradle Enterprise cache | All |
| `kapsis-<agent-id>-status` | Status volume backing `/kapsis-status` (Issue #276) | macOS only |
| `kapsis-<agent-id>-overlay` | Overlay `upper/`+`work/` dirs on VM-native ext4 (Issue #376) | macOS only |

All of these are removed automatically at session end unless `--keep-volumes` is used. The
`-overlay` volume is additionally reset at the next launch with the same agent ID, so stale
upper-layer content never leaks into a new session.

```bash
# List Kapsis volumes
podman volume ls | grep kapsis

# Manual cleanup
podman volume rm kapsis-1-m2 kapsis-1-gradle kapsis-1-overlay
```

### Snapshots

Per-agent staging copies of host files listed in `filesystem.include` (`~/.claude/`, `~/.ssh/`, `~/.gitconfig`, etc.) — created so the container reads race-free copies during launch (Issue #164). The directory is removed by `backend_cleanup()` on a clean agent exit, but hung agents, hard kills, and system crashes leak them.

```bash
# List snapshot directories
ls -la ~/.kapsis/snapshots/

# Manual cleanup of one agent's snapshot
rm -rf ~/.kapsis/snapshots/<agent-id>
```

Default TTL is 14 days. Override with `--snapshots-older-than <days>` or the `KAPSIS_SNAPSHOTS_TTL_DAYS` environment variable. Tracked under issue #389 (where an unmanaged 109 GB / 852-dir accumulation filled disk to 98% and silently broke agent dispatch).

## Image Garbage Collection (Issues #418/#421)

`--images` removes `kapsis-*` container images, guarded by three layers
(hardened after the 2026-07-02 Podman outage, where cleanup removed the
in-use `kapsis-slack-bot` image and 257 dangling `<none>` layers piled up):

1. **In-use guard (primary)** — an image referenced by ANY container
   (running or stopped) is never passed to `podman rmi`. If the in-use
   query (`podman ps -a`) itself fails, cleanup **fails closed**: no named
   image is removed at all for that invocation. The dangling prune still
   runs in that case — `podman image prune` is natively in-use-safe — so
   space reclaim survives a degraded podman.
2. **Podman dependency refusal (secondary)** — `rmi` is never passed
   `--force` and its exit code is never swallowed, so podman's native
   "image used by container" / "has dependent children" refusals
   transitively protect parent layers (e.g. `kapsis-sandbox` beneath an
   in-use `kapsis-slack-bot`). Refused removals are reported as
   `[SKIPPED]` and never counted as cleaned.
3. **Keep-patterns (tertiary)** — images whose `repository:tag` matches
   `KAPSIS_IMAGE_KEEP_PATTERNS` (an ERE; default protects
   `kapsis-slack-bot`, `kapsis-claude-cli`, `kapsis-sandbox`) are always
   skipped. Set the variable explicitly empty
   (`KAPSIS_IMAGE_KEEP_PATTERNS=''`) to disable protection, or override
   it to extend protection to downstream service images.

> **Behavior change:** working (in-use or keep-pattern-protected) images now
> survive `--images`/`--all` by default. To remove a protected working image
> intentionally, use `podman rmi <image>` directly or override
> `KAPSIS_IMAGE_KEEP_PATTERNS`.

### Dangling Layer Prune

Every image rebuild leaves the previous build's layers behind as dangling
(`<none>:<none>`) images. `--prune-dangling` reclaims them without touching
any named image — it is cheap, natively in-use-safe, and the recommended
routine space reclaim for cron jobs and downstream housekeepers (e.g. the
slack-bot host):

```bash
./scripts/kapsis-cleanup.sh --prune-dangling --force
```

`--vm-health` also prunes dangling layers proactively as soon as VM health
degrades to WARNING (threshold-based trigger for issue #421), while the
heavier full image cleanup stays gated to CRITICAL.

> **Incident note (2026-07-02):** `podman machine stop && podman machine
> start` does NOT reclaim the space consumed by dangling layers —
> `--prune-dangling` does.

### Downstream Housekeepers

If your service wraps `kapsis-cleanup --images` for routine space reclaim,
migrate to `--prune-dangling` — it reclaims the actual space hogs (stale
build layers) without ever racing your running containers. Extend
`KAPSIS_IMAGE_KEEP_PATTERNS` with your service image names to also protect
them during the between-runs window when no container references them.

## Disk Pressure Warning

After every `kapsis-cleanup` run, the total size of `~/.kapsis/` is measured and compared against a configurable threshold (default 50 GB). If the threshold is exceeded, a warning prints with the top three subdirectories by size and remediation hints. The measurement is also written to `~/.kapsis/.disk-usage-cache` for downstream consumers (dashboard, preflight checks) to read without re-scanning.

Set `KAPSIS_DIR_WARN_SIZE_GB=0` to disable. The threshold is intentionally well below the 127 GB that broke the reported install (issue #389) but high enough that healthy installs won't trip it on weekly cron runs.

## Podman VM Health (macOS)

On macOS, Podman runs inside a Linux VM. The VM's XFS filesystem has a fixed inode pool that
can be exhausted independently of disk bytes — once inodes run out, no new files can be created,
even if gigabytes of disk space remain free. The `--vm-health` flag diagnoses this before it
becomes a problem.

> **Note:** This flag is macOS-only. On Linux, Podman runs natively — use `df -i /` and
> `journalctl --disk-usage` directly on the host.

### What It Checks

| Metric | Warning | Critical | Auto-action |
|--------|---------|----------|-------------|
| Inode usage | ≥ 70% | ≥ 90% | Dangling-layer prune at warning; full image cleanup at critical |
| Disk usage | ≥ 80% | ≥ 95% | Dangling-layer prune at warning |
| Journal size | — | — | Vacuums to 100 MB at critical |

The critical-tier image cleanup is safe to run unattended: it is fail-closed
by construction — if the in-use container query fails, no named image is
removed, and the dangling prune (natively in-use-safe, never `--force`) still
runs. See [Image Garbage Collection](#image-garbage-collection-issues-418421).

### Usage

```bash
# Run health check
./scripts/kapsis-cleanup.sh --vm-health

# Check without making any changes
./scripts/kapsis-cleanup.sh --vm-health --dry-run
```

### Sample Output

```
=== Podman VM Health ===
[INFO] Podman VM Health Report
[INFO]   Disk:     12G / 50G (24%)
[INFO]   Inodes:   2.1M / 3.0M (70%), 900K free
[INFO]   Journal:  45M
[WARN] Inode usage elevated: 70% (threshold: 70%)
[WARN] VM health: WARNING — consider running: kapsis-cleanup --images
```

### Threshold Configuration

All thresholds can be overridden with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_CLEANUP_VM_INODE_WARN_PCT` | `70` | Inode warning threshold (%) |
| `KAPSIS_CLEANUP_VM_INODE_CRITICAL_PCT` | `90` | Inode critical threshold — triggers auto cleanup (%) |
| `KAPSIS_CLEANUP_VM_DISK_WARN_PCT` | `80` | Disk usage warning threshold (%) |
| `KAPSIS_CLEANUP_VM_DISK_CRITICAL_PCT` | `95` | Disk usage critical threshold (%) |
| `KAPSIS_CLEANUP_VM_JOURNAL_VACUUM_SIZE` | `100M` | Journal vacuum target size |
| `KAPSIS_CLEANUP_VM_SSH_TIMEOUT` | `15` | Timeout (seconds) for VM SSH commands |

Example override:

```bash
# Lower inode warning threshold to 60%
KAPSIS_CLEANUP_VM_INODE_WARN_PCT=60 ./scripts/kapsis-cleanup.sh --vm-health
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

### Inode Exhaustion (macOS)

On macOS, Podman's XFS VM filesystem can exhaust its inode pool independently of disk space.
Symptoms include "no space left on device" errors despite gigabytes of free disk.

```bash
# Diagnose: check inode and disk usage in the VM
./scripts/kapsis-cleanup.sh --vm-health

# First try the cheap, in-use-safe dangling layer prune
./scripts/kapsis-cleanup.sh --prune-dangling --force

# If inodes are still critical: clean unused container images (primary inode consumer)
./scripts/kapsis-cleanup.sh --images --force

# Full recovery: clean images + volumes
./scripts/kapsis-cleanup.sh --images --volumes --force
```

The `--vm-health` flag prunes dangling layers as soon as health degrades to WARNING and
auto-triggers full image cleanup when inode usage reaches the critical threshold
(default 90%). Use `--dry-run` to preview what would happen without making changes.

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

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_DIR` | `~/.kapsis` | Base directory for Kapsis data |
| `KAPSIS_WORKTREE_DIR` | `~/.kapsis/worktrees` | Worktree storage |
| `KAPSIS_STATUS_DIR` | `~/.kapsis/status` | Status file directory |
| `KAPSIS_LOG_DIR` | `~/.kapsis/logs` | Log file directory |
| `KAPSIS_SANDBOX_DIR` | `~/.ai-sandboxes` | Overlay upper directories |
| `KAPSIS_SNAPSHOTS_DIR` | `~/.kapsis/snapshots` | Per-agent filesystem-include staging |
| `KAPSIS_SNAPSHOTS_TTL_DAYS` | `14` | Snapshot retention before cleanup deletes |
| `KAPSIS_DIR_WARN_SIZE_GB` | `50` | Warn when `~/.kapsis/` exceeds this size (set `0` to disable) |
| `KAPSIS_IMAGE_KEEP_PATTERNS` | protects `kapsis-slack-bot`, `kapsis-claude-cli`, `kapsis-sandbox` | ERE matched against `repository:tag`; matching images are never removed by `--images`/`--all` (set `''` to disable) |

### VM Health (macOS)

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_CLEANUP_VM_INODE_WARN_PCT` | `70` | Inode warning threshold (%) |
| `KAPSIS_CLEANUP_VM_INODE_CRITICAL_PCT` | `90` | Inode critical threshold — triggers auto image cleanup (%) |
| `KAPSIS_CLEANUP_VM_DISK_WARN_PCT` | `80` | Disk usage warning threshold (%) |
| `KAPSIS_CLEANUP_VM_DISK_CRITICAL_PCT` | `95` | Disk usage critical threshold (%) |
| `KAPSIS_CLEANUP_VM_JOURNAL_VACUUM_SIZE` | `100M` | Journal vacuum target size |
| `KAPSIS_CLEANUP_VM_SSH_TIMEOUT` | `15` | Timeout (seconds) for VM SSH commands |

## See Also

- [GIT-WORKFLOW.md](GIT-WORKFLOW.md) - Branch-based workflow documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture and data flow
- [CONFIG-REFERENCE.md](CONFIG-REFERENCE.md) - Configuration options
