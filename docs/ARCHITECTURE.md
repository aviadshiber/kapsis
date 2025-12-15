# Kapsis Architecture

## Overview

Kapsis provides hermetically isolated sandboxes for AI coding agents. Each agent runs in a Podman container with Copy-on-Write filesystem overlay, ensuring complete isolation between parallel agents.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 HOST SYSTEM                                      │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  agent-sandbox.yaml    ← Single config file defines everything          │    │
│  │  - agent.command: "claude --dangerously-skip-permissions -p {task}"     │    │
│  │  - filesystem.include: [~/.ssh, ~/.gitconfig, ~/.claude, ...]           │    │
│  │  - environment.passthrough: [ANTHROPIC_API_KEY, ...]                    │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│  ~/projects/my-app/                    ← UNCHANGED (overlay lower layer)        │
│       │                                                                          │
│       ├──────────────────┬──────────────────┬──────────────────┐                │
│       │                  │                  │                  │                │
│       ▼                  ▼                  ▼                  ▼                │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐         │
│  │  AGENT 1    │   │  AGENT 2    │   │  AGENT 3    │   │  AGENT N    │         │
│  │  CONTAINER  │   │  CONTAINER  │   │  CONTAINER  │   │  CONTAINER  │         │
│  │             │   │             │   │             │   │             │         │
│  │ /workspace  │   │ /workspace  │   │ /workspace  │   │ /workspace  │         │
│  │ (CoW view)  │   │ (CoW view)  │   │ (CoW view)  │   │ (CoW view)  │         │
│  │             │   │             │   │             │   │             │         │
│  │ .m2 (own)   │   │ .m2 (own)   │   │ .m2 (own)   │   │ .m2 (own)   │         │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘         │
│         │                 │                 │                 │                 │
│         ▼                 ▼                 ▼                 ▼                 │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐         │
│  │ upper-dir-1 │   │ upper-dir-2 │   │ upper-dir-3 │   │ upper-dir-N │         │
│  │ (changes)   │   │ (changes)   │   │ (changes)   │   │ (changes)   │         │
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘         │
│                                                                                  │
│  After work: review each upper-dir, merge selectively via rsync/git             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Isolation Layers

### 1. Filesystem Isolation (Copy-on-Write)

```
Project Directory (Host)     Container View
─────────────────────────   ───────────────────
~/project/                   /workspace/
├── src/                     ├── src/          (read from host)
├── pom.xml                  ├── pom.xml       (read from host)
└── ...                      ├── NewFile.java  (written to upper)
                             └── ...

Upper Directory (Host)
─────────────────────────
~/.ai-sandboxes/project-1/upper/
└── src/
    └── NewFile.java        (agent's changes)
```

**How it works:**
- Podman `:O` overlay mount creates a union filesystem
- Reads come from host project (lower layer)
- Writes go to isolated upper directory
- Host project remains UNCHANGED until explicit merge

### 2. Maven Repository Isolation

```
Per-Agent Volumes:
─────────────────────────
kapsis-1-m2:/home/developer/.m2/repository
kapsis-2-m2:/home/developer/.m2/repository
kapsis-3-m2:/home/developer/.m2/repository
```

**Protection mechanisms:**
- Each agent has its own `.m2/repository` volume
- SNAPSHOT downloads blocked in `isolated-settings.xml`
- Deploy operations blocked
- Only release artifacts downloaded from Artifactory

### 3. Build Cache Isolation

```
Gradle Enterprise Configuration:
─────────────────────────
Remote Cache: DISABLED
Local Cache: Per-agent volume
Build Scans: ENABLED (observability)
```

**Prevents:**
- Agent A uploading compiled classes that Agent B downloads
- Stale cache entries affecting builds
- Cross-agent contamination via shared cache

### 4. Container Security

```
Podman Configuration:
─────────────────────────
--userns=keep-id          # UID mapping
--memory=8g               # Resource limits
--cpus=4
--security-opt label=disable
```

**Security features:**
- Rootless Podman (no root access on host)
- UID/GID mapping to host user
- Resource limits prevent runaway builds
- Network access preserved for downloads

## Sandbox Modes

Kapsis supports two sandbox modes for different use cases:

### Overlay Mode (Legacy)

The original isolation method using fuse-overlayfs:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Container with fuse-overlayfs                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │  /workspace (merged view)                                               │   │
│  │  ├── lower: host project (read-only)                                    │   │
│  │  ├── upper: changes go here                                             │   │
│  │  └── work: overlay metadata                                             │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│  + .git directory copied to upper layer (workaround)                           │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Auto-selected when:** No `--branch` flag OR project is not a git repository

### Worktree Mode (New, Recommended)

Uses git worktrees for simpler branch management with container security:

```
HOST (Trusted)                          CONTAINER (Untrusted)
─────────────────────────────────────   ─────────────────────────────────
~/project/.git/  (PROTECTED)
    ↓
git worktree add
    ↓
~/.kapsis/worktrees/project-agent-1/    /workspace (bind mount)
├── .git (file) ──────────────────────→ ├── .git-safe/ (sanitized, ro)
├── src/                                │   ├── config (minimal)
├── pom.xml                             │   ├── objects → (ro link)
└── ...                                 │   └── hooks/ (EMPTY)
                                        ├── src/
                                        └── pom.xml
    ↓                                       ↓
Post-container: git commit/push         Agent makes changes
(on HOST with full git access)          (restricted git env)
```

**Auto-selected when:** `--branch` flag provided AND project is a git repository

**Security features:**
- Worktrees created on HOST (trusted environment)
- Container receives sanitized .git view (read-only)
- Empty hooks directory prevents hook-based attacks
- Objects mounted read-only prevents corruption
- Git commit/push runs on HOST after container exits

**Advantages over overlay mode:**
- No fuse-overlayfs permission issues
- No .git copy workaround needed
- Native git operations
- Simpler cleanup (`git worktree remove`)
- No `--cap-add SYS_ADMIN` required

### Mode Selection

| Condition | Mode Selected |
|-----------|---------------|
| `--branch` + `.git` exists | Worktree mode |
| No `.git` or no `--branch` | Overlay mode |
| `--worktree-mode` flag | Force worktree |
| `--overlay-mode` flag | Force overlay |

## Data Flow

### Launch Flow

```
1. launch-agent.sh
   │
   ├─→ Parse config (agent-sandbox.yaml)
   │
   ├─→ Create sandbox directories
   │   └── ~/.ai-sandboxes/project-1/{upper,work}
   │
   ├─→ Generate Podman command
   │   ├── Volume mounts (overlay, .m2, configs)
   │   ├── Environment variables
   │   └── Resource limits
   │
   ├─→ Start container
   │   └── entrypoint.sh
   │       ├── Initialize environment (SDKMAN, NVM)
   │       ├── Initialize git branch (if --branch)
   │       └── Run agent command
   │
   └─→ Agent works in isolated environment
```

### Git Workflow Flow

```
1. Launch with --branch feature/DEV-123
   │
   ├─→ entrypoint.sh: init-git-branch.sh
   │   ├── git fetch origin
   │   ├── If remote exists: checkout and track
   │   └── If new: create from HEAD
   │
   ├─→ Agent works, makes changes
   │
   ├─→ Agent exits
   │   └── trap: post-exit-git.sh
   │       ├── git add -A
   │       ├── git commit
   │       └── git push (unless --no-push)
   │
   └─→ User reviews PR
       │
       └─→ Re-launch with same branch
           └── Agent continues from remote state
```

## Volume Mounts

| Mount | Source | Target | Mode |
|-------|--------|--------|------|
| Project | `~/project` | `/workspace` | `:O` (overlay) |
| Maven Repo | `kapsis-{id}-m2` | `~/.m2/repository` | volume |
| Gradle Cache | `kapsis-{id}-gradle` | `~/.gradle` | volume |
| GE Workspace | `kapsis-{id}-ge` | `~/.m2/.gradle-enterprise` | volume |
| Git Config | `~/.gitconfig` | `~/.gitconfig` | `:ro` |
| SSH Keys | `~/.ssh` | `~/.ssh` | `:ro` |
| Agent Config | `~/.claude` | `~/.claude` | `:ro` |
| Spec File | `./spec.md` | `/task-spec.md` | `:ro` |

## Merge Strategies

### 1. Git Branch Workflow (Recommended)

```bash
# Launch with branch
./launch-agent.sh 1 ~/project --branch feature/DEV-123 --spec task.md

# Agent commits and pushes automatically
# Review PR → Request changes → Update spec → Re-run
```

**Advantages:**
- Full git history preserved
- PR review before merge
- Feedback loop for iterations
- Works with any git platform

### 2. Manual Merge Workflow

```bash
# Launch without branch
./launch-agent.sh 1 ~/project --spec task.md

# Review changes in upper directory
tree ~/.ai-sandboxes/project-1/upper/

# Merge selectively
./scripts/merge-changes.sh project-1 ~/project

# Or with rsync
rsync -av ~/.ai-sandboxes/project-1/upper/ ~/project/
```

**Advantages:**
- Full control over what gets merged
- Can cherry-pick specific files
- No git branch required

### 3. Discard Workflow

```bash
# Review changes
ls ~/.ai-sandboxes/project-1/upper/

# Discard all changes
rm -rf ~/.ai-sandboxes/project-1/
```

## Container Image Layers

```dockerfile
ubuntu:24.04
└── Base dependencies (curl, git, ripgrep, etc.)
    └── SDKMAN + Java 8/17
        └── Maven 3.9.11
            └── NVM + Node.js 18.18.0
                └── Kapsis scripts + Maven settings
                    └── Runtime configuration
```

## Performance Considerations

### Warm Cache Strategy

For faster startup, pre-populate Maven repository:

```bash
# Build image with dependencies pre-downloaded
# In Containerfile, add after Maven install:
COPY pom.xml /tmp/pom.xml
RUN cd /tmp && mvn dependency:go-offline -q
```

### Parallel Build Settings

```yaml
resources:
  memory: 8g   # Per agent
  cpus: 4      # Per agent

# For 3 parallel agents on 16-core machine:
# 3 × 4 = 12 cores, 3 × 8GB = 24GB RAM
```

### Overlay Performance

- Native overlay diff requires Linux kernel 5.11+
- macOS uses applehv abstraction (slightly slower)
- Large file operations may be slower due to CoW

## Troubleshooting

### Common Issues

1. **Podman machine not running**
   ```bash
   podman machine start podman-machine-default
   ```

2. **Permission denied on mounted files**
   - Check `--userns=keep-id` is set
   - Verify file permissions on host

3. **Maven downloads failing**
   - Check Artifactory URL in config
   - Verify network access from container

4. **Git push failing**
   - Check SSH keys mounted correctly
   - Verify git remote configured
