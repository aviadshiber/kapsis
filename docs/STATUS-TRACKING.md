<!-- markdownlint-disable MD060 -->
# Status Tracking Design

Kapsis provides real-time status tracking through agent-agnostic hooks that report progress without requiring modifications to the AI agents themselves.

## Architecture

```text
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

## Supported Agents

| Agent | Hook System | Hook Types | Config Location |
|-------|-------------|------------|-----------------|
| Claude Code | Yes | PreToolUse, PostToolUse, Stop | ~/.claude/settings.local.json |
| Codex CLI | Yes | exec.pre, exec.post, item.* | ~/.codex/config.yaml |
| Gemini CLI | Yes | tool_call, completion | ~/.gemini/hooks/ |
| Aider | No (fallback) | N/A | Instruction injection + monitor |
| Python | No (direct) | N/A | Import status.py directly |

## Automatic Hook Injection

Kapsis automatically injects status tracking hooks at container startup. This happens inside the container after Copy-on-Write setup, so **user's host configuration is never modified**.

```text
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

### Design Decisions

- **Merge-based injection**: User's existing hooks are preserved, Kapsis hooks are added alongside them
- **Idempotent**: Running injection twice doesn't duplicate hooks (checks before adding)
- **Agent type inference**: When config name doesn't normalize to a known type, agent type is inferred from image name (e.g., `kapsis-claude-cli` → `claude-cli`)
- **CoW isolation**: All modifications happen in container's overlay layer, never touching host files

### Per-Agent Injection Methods

**Claude Code** - Uses `settings.local.json` which Claude automatically merges with `settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "*",
      "hooks": [{"type": "command", "command": "/opt/kapsis/hooks/kapsis-status-hook.sh", "timeout": 5}]
    }],
    "Stop": [{
      "hooks": [{"type": "command", "command": "/opt/kapsis/hooks/kapsis-stop-hook.sh", "timeout": 5}]
    }]
  }
}
```

**Codex CLI** - Merges hooks into `config.yaml`:

```yaml
hooks:
  exec.post:
    - /opt/kapsis/hooks/kapsis-status-hook.sh
  item.create:
    - /opt/kapsis/hooks/kapsis-status-hook.sh
  item.update:
    - /opt/kapsis/hooks/kapsis-status-hook.sh
  completion:
    - /opt/kapsis/hooks/kapsis-stop-hook.sh
```

**Gemini CLI** - Creates or appends to shell script hooks:

```bash
# ~/.gemini/hooks/post-tool.sh
#!/usr/bin/env bash
# Kapsis status tracking
"/opt/kapsis/hooks/kapsis-status-hook.sh" "$@" || true
```

## Tool-to-Phase Mapping

The hook script maps agent tool usage to semantic phases:

| Category | Tool Patterns | Progress Range |
|----------|---------------|----------------|
| `exploring` | Read, Grep, Glob, Bash(git status*) | 25-35% |
| `implementing` | Edit, Write, Bash(mkdir*) | 35-60% |
| `building` | Bash(mvn*), Bash(npm build*) | 50-70% |
| `testing` | Bash(mvn test*), Bash(pytest*) | 60-80% |
| `committing` | Bash(git commit*) | 85-90% |
| `other` | TodoWrite, mcp__* | 25-50% |

Configuration is stored in `configs/tool-phase-mapping.yaml`.

## Status Phases

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

## Status File Format

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
  "gist": "Refactoring authentication module to use JWT tokens",
  "gist_updated_at": "2025-12-16T14:34:55Z",
  "started_at": "2025-12-16T14:30:00Z",
  "updated_at": "2025-12-16T14:35:00Z",
  "exit_code": null,
  "error": null,
  "worktree_path": "/Users/user/.kapsis/worktrees/products-1",
  "pr_url": null
}
```

## Agent Gist (Live Activity Summary)

During long "thinking" periods, the standard status message may become stale. The **gist** feature provides a signaling file that agents can update in real-time to communicate what they're currently working on.

### How It Works

```text
AGENT (inside container)              KAPSIS STATUS SYSTEM
         │                                    │
         │  writes current activity           │
         ├──────────────────────────────────► /workspace/.kapsis/gist.txt
         │                                    │
         │  makes tool call (Edit, Bash...)   │
         ├──────────────────────────────────► PostToolUse hook fires
         │                                    │
         │                                    ├─► reads gist.txt
         │                                    ├─► includes in status.json
         │                                    │
         │                                    │
USER     │                                    │
         │  kapsis-status                     │
         ├──────────────────────────────────► reads status.json
         │                                    │
         │  sees: "Refactoring auth module"   │
         ◄────────────────────────────────────┤
```

### For Agent Authors

Agents should update the gist file whenever they begin a new logical step. The gist persists until overwritten, so it always reflects the most recent activity.

**Write to gist (Bash):**

```bash
echo "your current activity" > /workspace/.kapsis/gist.txt
```

**Guidelines:**

- Update at the START of each significant work phase
- Keep messages short (< 100 chars; truncated at 500)
- Use present tense, action-oriented language
- Overwrite (not append) - file should contain only current activity

**Example workflow - agent dynamically updates gist as it works:**

```text
[Agent starts task]
  └─► echo "Exploring codebase structure" > gist.txt

[Agent reads several files, finds relevant code]
  └─► echo "Analyzing UserService authentication flow" > gist.txt

[Agent begins implementing]
  └─► echo "Adding JWT validation to AuthController" > gist.txt

[Agent runs tests]
  └─► echo "Running auth module integration tests" > gist.txt
```

Each write overwrites the previous gist, so `kapsis-status` always shows the agent's current focus.

### Configuration

```bash
# Default path (can be overridden)
export KAPSIS_GIST_FILE=/workspace/.kapsis/gist.txt
```

### Viewing Gists

```bash
# List view - gist shown in STATUS column (preferred over message when present)
kapsis-status

# Detailed view - gist shown in "Agent Activity" section
kapsis-status products 1
```

## Container-to-Host Communication

```text
HOST                                    CONTAINER
~/.kapsis/status/  ←──volume mount──→  /kapsis-status/
     ↓                                       ↓
kapsis-products-1.json              /kapsis-status/kapsis-products-1.json
     ↑                                       ↑
External tools poll                  Agent hooks write updates
```

## Monitoring Status

```bash
# Check all running agents
kapsis-status

# Watch specific agent
kapsis-status products 1

# Watch all agents (refreshes every 2s)
kapsis-status --watch

# JSON output for scripting
kapsis-status --json
```

## Fallback: Progress Monitor

For agents without native hook support (Aider, custom agents), Kapsis uses a background monitor:

1. **Instruction injection**: Task spec gets an appendix instructing the agent to write progress
2. **Progress file format**: Agent writes to `/workspace/.kapsis/progress.json`
3. **Monitor daemon**: `progress-monitor.sh` polls the file every 2 seconds
4. **Progress scaling**: Agent's 0-100% maps to Kapsis's 25-90% (running phase)

```json
{
  "version": "1.0",
  "current_step": 2,
  "total_steps": 5,
  "description": "Implementing user authentication"
}
```

## Terminal Progress Display

For TTY environments, Kapsis provides in-place terminal progress updates using ANSI escape codes. This replaces the traditional line-by-line output with a smooth, animated display.

### Features

- **In-place updates**: Progress bar updates without repeating output lines
- **Animated spinner**: Braille pattern spinner during active phases
- **Progress bar**: Unicode block characters (█░) showing completion percentage
- **Elapsed time**: Real-time tracking of task duration
- **Non-TTY fallback**: Simple line-based output for CI/piped environments

### Environment Variables

| Variable | Description |
|----------|-------------|
| `KAPSIS_PROGRESS_DISPLAY` | Set to `1` when progress display is active (set by `display_init`) |
| `KAPSIS_NO_PROGRESS` | Set to `true` or `1` to disable progress display entirely |
| `NO_COLOR` | Standard variable to disable colors (also disables progress display) |

### Integration

The progress display library (`scripts/lib/progress-display.sh`) reads status updates from `status.json` and renders them in the terminal. It works alongside the status tracking system:

```text
Agent hooks → status.json → progress-display.sh → Terminal output
```

## Files

| File | Purpose |
|------|---------|
| `scripts/lib/inject-status-hooks.sh` | Auto-inject hooks at container startup |
| `scripts/lib/status.sh` | JSON status file management |
| `scripts/lib/status.py` | Python status library for custom agents |
| `scripts/lib/progress-display.sh` | Terminal progress display with ANSI rendering |
| `scripts/lib/progress-monitor.sh` | Background progress file monitor (fallback) |
| `scripts/hooks/kapsis-status-hook.sh` | Universal hook for all agents |
| `scripts/hooks/kapsis-stop-hook.sh` | Completion hook |
| `scripts/hooks/tool-phase-mapping.sh` | Tool → phase mapping (loads YAML config) |
| `scripts/hooks/agent-adapters/claude-adapter.sh` | Parse Claude Code hook format |
| `scripts/hooks/agent-adapters/codex-adapter.sh` | Parse Codex CLI hook format |
| `scripts/hooks/agent-adapters/gemini-adapter.sh` | Parse Gemini CLI hook format |
| `configs/tool-phase-mapping.yaml` | Tool → phase mapping configuration |
