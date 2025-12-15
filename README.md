# Kapsis

**Hermetically Isolated AI Agent Sandbox for Parallel Development**

Kapsis enables running multiple AI coding agents in parallel on the same Maven project with complete isolation. Each agent runs in a Podman container with Copy-on-Write filesystem, ensuring Agent A's work cannot affect Agent B.

## Features

- **Agent Agnostic** - Works with Claude Code, Codex CLI, Aider, Gemini CLI, or any CLI-based agent
- **Config-Driven** - Single YAML file defines agent command and filesystem whitelist
- **Copy-on-Write Filesystem** - Project files use overlay mounts (reads from host, writes isolated)
- **Maven Isolation** - Per-agent `.m2/repository`, blocked remote SNAPSHOTs, blocked deploy
- **Build Cache Isolation** - Gradle Enterprise remote cache disabled, per-agent local cache
- **Git Workflow** - Optional branch-based workflow with PR review feedback loop
- **Rootless Containers** - Security-hardened Podman rootless mode

## Quick Start

```bash
# 1. Clone Kapsis
git clone https://github.com/your-org/kapsis.git
cd kapsis

# 2. Build the container image
./scripts/build-image.sh

# 3. Copy and customize config
cp agent-sandbox.yaml.template agent-sandbox.yaml
# Edit agent-sandbox.yaml with your settings

# 4. Run an agent
./scripts/launch-agent.sh 1 ~/project --task "fix failing tests"
```

## Usage

### Basic Usage

```bash
# Simple inline task
./scripts/launch-agent.sh 1 ~/project --task "fix failing tests in UserService"

# Complex task with spec file
./scripts/launch-agent.sh 1 ~/project --spec ./specs/feature.md

# Interactive mode (manual exploration)
./scripts/launch-agent.sh 1 ~/project --interactive
```

### Git Branch Workflow

```bash
# Create new branch and work on task
./scripts/launch-agent.sh 1 ~/project \
    --branch feature/DEV-123 \
    --spec ./specs/task.md

# Agent works, commits, pushes → PR created
# Review PR, request changes
# Update spec with feedback, re-run:

./scripts/launch-agent.sh 1 ~/project \
    --branch feature/DEV-123 \
    --spec ./specs/task-v2.md

# Agent CONTINUES from remote branch state!
```

### Parallel Agents

```bash
# Run multiple agents on same project, different branches
./scripts/launch-agent.sh 1 ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-api \
    --spec ./specs/api.md &

./scripts/launch-agent.sh 2 ~/project \
    --config configs/codex.yaml \
    --branch feature/DEV-123-ui \
    --spec ./specs/ui.md &

./scripts/launch-agent.sh 3 ~/project \
    --config configs/aider.yaml \
    --branch feature/DEV-123-tests \
    --spec ./specs/tests.md &

wait
```

## Configuration

Create `agent-sandbox.yaml` from the template:

```yaml
agent:
  # Command to launch the agent
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""
  workdir: /workspace

filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh
    - ~/.claude

environment:
  passthrough:
    - ANTHROPIC_API_KEY

resources:
  memory: 8g
  cpus: 4

maven:
  mirror_url: "https://your-artifactory.com/maven"
  block_remote_snapshots: true
  block_deploy: true

git:
  auto_push:
    enabled: true
```

See [docs/CONFIG-REFERENCE.md](docs/CONFIG-REFERENCE.md) for full configuration options.

## Supported Agents

| Agent | Command Example |
|-------|-----------------|
| Claude Code | `claude --dangerously-skip-permissions -p "$(cat /task-spec.md)"` |
| Codex CLI | `codex --approval-mode full-auto "$(cat /task-spec.md)"` |
| Aider | `aider --yes-always --message-file /task-spec.md` |
| Gemini CLI | `gemini -s docker "$(cat /task-spec.md)"` |
| Custom | Any CLI command |

Pre-built configs available in `configs/` directory.

## Isolation Guarantees

| Resource | Isolation Method |
|----------|------------------|
| Project files | Overlay mount (`:O`) - reads from host, writes to isolated upper layer |
| Maven repository | Per-agent container volume |
| Remote SNAPSHOTs | Blocked in isolated-settings.xml |
| Deploy operations | Blocked in isolated-settings.xml |
| GE/Develocity cache | Remote cache disabled |
| Host system | Podman rootless container |

## Project Structure

```
kapsis/
├── agent-sandbox.yaml.template  # Config template
├── Containerfile                # Container image definition
├── configs/                     # Pre-built agent configs
│   ├── claude.yaml
│   ├── codex.yaml
│   ├── aider.yaml
│   └── interactive.yaml
├── scripts/
│   ├── launch-agent.sh          # Main launch script
│   ├── build-image.sh           # Build container image
│   ├── merge-changes.sh         # Manual merge workflow
│   ├── entrypoint.sh            # Container entrypoint
│   ├── init-git-branch.sh       # Git branch initialization
│   ├── post-exit-git.sh         # Post-exit commit/push
│   └── switch-java.sh           # Java version switcher
├── maven/
│   └── isolated-settings.xml    # Maven isolation settings
├── docs/
│   ├── ARCHITECTURE.md
│   ├── CONFIG-REFERENCE.md
│   └── GIT-WORKFLOW.md
└── tests/                       # Validation tests
```

## Requirements

- **Podman** 4.0+ (5.0+ recommended)
- **macOS** with Apple Silicon (tested) or Linux
- **yq** (optional, for config parsing)

## License

MIT
