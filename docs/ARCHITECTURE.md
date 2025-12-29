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
├── .git (file, ignored) ─────────────→ ├── .git (file, host path - ignored)
├── src/                                ├── .git-safe/ (sanitized, ro mount)
├── pom.xml                             │   ├── config (minimal)
└── ...                                 │   ├── objects → .git-objects
                                        │   └── hooks/ (empty)
                                        ├── .git-objects/ (shared objects, ro)
                                        ├── src/
                                        └── pom.xml
    ↓                                       ↓
Post-container: git commit/push         Agent makes changes
(on HOST with full git access)          (GIT_DIR=.git-safe for git ops)
```

**Key insight:** The worktree's `.git` file contains a host path that doesn't exist in the
container. We mount the sanitized git at `.git-safe` and set `GIT_DIR=/workspace/.git-safe`
so git commands work. We can't mount over the `.git` file because OCI runtimes (crun) don't
allow mounting a directory over a file.

**Auto-selected when:** `--branch` flag provided AND project is a git repository

**Security features:**
- Worktrees created on HOST (trusted environment)
- Container receives sanitized .git view (read-only)
- Hooks run in sandbox isolation (cannot affect host)
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

### Status Reporting Flow

Kapsis provides JSON-based status reporting for external monitoring with **agent-agnostic hook-based tracking**:

```
1. launch-agent.sh
   │
   ├─→ status_init()              → initializing (0%)
   │   └── Creates ~/.kapsis/status/kapsis-{project}-{agent_id}.json
   │
   ├─→ Validate inputs            → initializing (5%)
   ├─→ Parse config               → initializing (10%)
   ├─→ Setup sandbox              → preparing (18%)
   ├─→ Configure container        → preparing (20%)
   ├─→ Launch container           → starting (22%)
   │
   ├─→ entrypoint.sh (in container)
   │   ├─→ setup_status_tracking() → Sets up hooks or monitor
   │   │   ├─→ Claude Code: PostToolUse hooks
   │   │   ├─→ Codex CLI: exec.post hooks
   │   │   ├─→ Gemini CLI: tool_call hooks
   │   │   └─→ Other agents: progress-monitor.sh (polling)
   │   │
   │   └─→ Agent executes task
   │       │
   │       ├─→ Tool: Read/Grep/Glob  → exploring (25-35%)
   │       ├─→ Tool: Edit/Write      → implementing (35-60%)
   │       ├─→ Tool: Bash(mvn/npm)   → building (50-70%)
   │       ├─→ Tool: Bash(*test*)    → testing (60-80%)
   │       └─→ Tool: git commit      → committing (85-90%)
   │
   ├─→ Agent exits                → running (90%)
   │
   ├─→ post-container-git.sh (on host)
   │   ├─→ commit_changes()       → committing (92%)
   │   └─→ push_changes()         → pushing (97%)
   │
   └─→ status_complete()          → complete (100%)
       └── exit_code, error, pr_url recorded
```

**Hook-Based Status Tracking Architecture:**

```
                         KAPSIS STATUS TRACKER
                                  │
    ┌────────────────┬────────────┼────────────┬────────────────┐
    ▼                ▼            ▼            ▼                ▼
CLAUDE CODE     CODEX CLI    GEMINI CLI    AIDER/OTHER    PYTHON AGENT
┌──────────┐   ┌──────────┐  ┌──────────┐  ┌──────────┐   ┌──────────┐
│PostToolUse│   │exec.post │  │tool_call │  │Instruction│   │Direct    │
│hook       │   │hook      │  │hook      │  │injection +│   │status.py │
│           │   │          │  │          │  │file monitor│   │import    │
└─────┬─────┘   └─────┬────┘  └─────┬────┘  └─────┬─────┘   └─────┬────┘
      │               │            │              │              │
      ▼               ▼            ▼              ▼              ▼
    claude-       codex-        gemini-       progress-       status.py
    adapter.sh    adapter.sh    adapter.sh    monitor.sh
      │               │            │              │              │
      └───────────────┴────────────┼──────────────┴──────────────┘
                                   ▼
                    kapsis-status-hook.sh
                           │
                           ▼
                    tool-phase-mapping.sh
                    (config: tool-phase-mapping.yaml)
                           │
                           ▼
               /kapsis-status/kapsis-{project}-{id}.json
```

**Tool-to-Phase Mapping (configs/tool-phase-mapping.yaml):**

| Category | Tool Patterns | Progress Range |
|----------|---------------|----------------|
| `exploring` | Read, Grep, Glob, Bash(git status*) | 25-35% |
| `implementing` | Edit, Write, Bash(mkdir*) | 35-60% |
| `building` | Bash(mvn*), Bash(npm build*) | 50-70% |
| `testing` | Bash(mvn test*), Bash(pytest*) | 60-80% |
| `committing` | Bash(git commit*) | 85-90% |
| `other` | TodoWrite, mcp__* | 25-50% |

**Status File Schema:**

```json
{
  "version": "1.0",
  "agent_id": "1",
  "project": "products",
  "branch": "feature/DEV-123",
  "sandbox_mode": "worktree",
  "phase": "implementing",
  "progress": 45,
  "message": "Implementing feature",
  "started_at": "2025-12-16T14:30:00Z",
  "updated_at": "2025-12-16T14:35:00Z",
  "exit_code": null,
  "error": null,
  "worktree_path": "/Users/user/.kapsis/worktrees/products-1",
  "pr_url": null
}
```

**Automatic Hook Injection:**

Kapsis automatically injects status tracking hooks at container startup. This happens inside the container
after Copy-on-Write setup, so **user's host configuration is never modified**.

```
Container Startup (entrypoint.sh)
        │
        ├─→ CoW/Worktree setup (host configs mounted read-only)
        │
        ├─→ Copy staged configs to home directory (~/.claude/, etc.)
        │
        └─→ inject-status-hooks.sh (merges Kapsis hooks)
            │
            ├─→ Claude Code: ~/.claude/settings.local.json
            │   (Claude merges settings.local.json with settings.json)
            │
            ├─→ Codex CLI: ~/.codex/config.yaml
            │   (Adds exec.post, item.create, completion hooks)
            │
            └─→ Gemini CLI: ~/.gemini/hooks/*.sh
                (Creates or appends to hook scripts)
```

**Key design decisions:**
- **Merge-based injection**: User's existing hooks are preserved, Kapsis hooks are added
- **Idempotent**: Running injection twice doesn't duplicate hooks
- **Agent type inference**: When config name doesn't normalize (e.g., `aviad-claude.yaml`),
  agent type is inferred from image name (`kapsis-claude-cli` → `claude-cli`)
- **CoW isolation**: All modifications happen in container's overlay layer

**Container-to-Host Communication:**

```
HOST                                    CONTAINER
~/.kapsis/status/  ←──volume mount──→  /kapsis-status/
     ↓                                       ↓
kapsis-products-1.json              /kapsis-status/kapsis-products-1.json
     ↑                                       ↑
External tools poll                  Agent hooks write updates
```

**Phases:**

| Phase | Progress | Location | Description |
|-------|----------|----------|-------------|
| `initializing` | 0-10% | launch-agent.sh | Validating inputs, config |
| `preparing` | 10-20% | launch-agent.sh | Creating sandbox, volumes |
| `starting` | 20-25% | launch-agent.sh | Launching container |
| `exploring` | 25-35% | hook (in container) | Reading files, searching |
| `implementing` | 35-60% | hook (in container) | Writing code, editing |
| `building` | 50-70% | hook (in container) | Compilation, dependencies |
| `testing` | 60-80% | hook (in container) | Running tests |
| `committing` | 85-95% | hook / post-git | Git commit operations |
| `pushing` | 95-99% | post-container-git.sh | Pushing to remote |
| `complete` | 100% | launch-agent.sh | Final status |

## Volume Mounts

| Mount | Source | Target | Mode |
|-------|--------|--------|------|
| Project | `~/project` | `/workspace` | `:O` (overlay) |
| Maven Repo | `kapsis-{id}-m2` | `~/.m2/repository` | volume |
| Gradle Cache | `kapsis-{id}-gradle` | `~/.gradle` | volume |
| GE Workspace | `kapsis-{id}-ge` | `~/.m2/.gradle-enterprise` | volume |
| Status Dir | `~/.kapsis/status` | `/kapsis-status` | bind |
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
    └── SDKMAN + Java 8/17 + Maven 3.9.9
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

## Cleanup

After agent work completes, use the cleanup script to reclaim disk space:

```bash
./scripts/kapsis-cleanup.sh --dry-run    # Preview
./scripts/kapsis-cleanup.sh --all        # Clean everything
```

See [CLEANUP.md](CLEANUP.md) for full documentation on cleanup options, what gets cleaned, and handling permission issues.

## Shared Libraries

Kapsis scripts use shared libraries for common functionality:

```
scripts/lib/
├── compat.sh              # Cross-platform compatibility helpers
├── logging.sh             # File-based logging with rotation
├── status.sh              # JSON status file management
├── json-utils.sh          # JSON parsing utilities
├── agent-types.sh         # Agent type detection and normalization
├── progress-monitor.sh    # Background progress file monitor (fallback)
├── config-verifier.sh     # YAML config validation for CI
├── inject-status-hooks.sh # Auto-inject status hooks for all agents
└── status.py              # Python status library for custom agents

scripts/hooks/
├── kapsis-status-hook.sh      # Universal hook for all agents
├── kapsis-stop-hook.sh        # Completion hook
├── tool-phase-mapping.sh      # Tool → phase mapping (loads YAML config)
└── agent-adapters/
    ├── claude-adapter.sh      # Parse Claude Code hook format
    ├── codex-adapter.sh       # Parse Codex CLI hook format
    └── gemini-adapter.sh      # Parse Gemini CLI hook format

configs/
├── tool-phase-mapping.yaml    # Tool → phase mapping configuration
├── claude.yaml                # Claude Code launch config
├── codex.yaml                 # Codex CLI launch config
├── aider.yaml                 # Aider launch config
├── interactive.yaml           # Interactive mode config
└── agents/                    # Agent profiles (detailed definitions)
    ├── claude-cli.yaml
    ├── codex-cli.yaml
    ├── gemini-cli.yaml
    ├── aider.yaml
    └── claude-api.yaml
```

### compat.sh - Cross-Platform Helpers

Provides consistent behavior across macOS and Linux where command syntax differs:

```bash
source "$SCRIPT_DIR/lib/compat.sh"

# Get file size (works on both macOS and Linux)
size=$(get_file_size "/path/to/file")

# Get file modification time as Unix epoch
mtime=$(get_file_mtime "/path/to/file")

# Get MD5 hash of file
hash=$(get_file_md5 "/path/to/file")

# OS detection
if is_macos; then
    # macOS-specific code
fi
```

**Why this exists:** Common commands differ between macOS and Linux:
- `stat`: macOS uses `-f%z`, Linux uses `-c%s`
- `md5`: macOS has `md5`, Linux has `md5sum`

The fallback pattern `cmd1 || cmd2` doesn't work reliably because some commands exit 0 with wrong output.

### logging.sh - Structured Logging

See the header comments in `scripts/lib/logging.sh` for full documentation.

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
