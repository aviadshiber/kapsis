# Kapsis Agent Profiles Architecture

## Problem Statement

Kapsis is agent-agnostic, but currently relies on mounting host binaries into containers. This breaks when:
- Host binary architecture differs from container (macOS arm64 → Linux amd64)
- Agent requires headless authentication (OAuth flows)
- Different agents need different dependencies

## Solution: Agent Profile System

### Core Concept

Separate agent **definition** (how to install) from agent **configuration** (how to run):

```
configs/
├── agents/           # Agent profile templates (install + run)
│   ├── claude-cli.yaml
│   ├── claude-api.yaml
│   ├── aider.yaml
│   └── codex.yaml
└── users/            # User configs (reference agent + customize)
    └── my-claude.yaml
```

### Agent Profile Schema

```yaml
# configs/agents/claude-cli.yaml
name: claude-cli
description: Claude Code CLI (official Anthropic)
version: latest

# How to install the agent
install:
  # Option 1: NPM global install
  npm: "@anthropic-ai/claude-code"

  # Option 2: Pip install
  # pip: "anthropic"

  # Option 3: Custom script
  # script: |
  #   curl -fsSL https://claude.ai/install.sh | bash

# Dependencies required
dependencies:
  - nodejs >= 18
  # - python >= 3.9

# Authentication required (validated at launch)
auth:
  required:
    - name: ANTHROPIC_API_KEY
      description: "Anthropic API key"
      keychain:
        macos: "Claude Code-credentials"
        linux: "anthropic-api-key"
  optional:
    - name: CLAUDE_CODE_OAUTH_TOKEN
      description: "OAuth token for headless mode (from 'claude setup-token')"
      keychain:
        macos: "claude-oauth-token"

# Config files to mount (read-only)
config_mounts:
  - source: ~/.claude.json
    target: /home/developer/.claude.json
  - source: ~/.claude
    target: /home/developer/.claude

# Command template (uses ${TASK_SPEC} placeholder)
command: >
  claude --dangerously-skip-permissions -p "$(cat ${TASK_SPEC})"

# Working directory
workdir: /workspace
```

### User Config References Agent Profile

```yaml
# configs/users/my-claude.yaml
agent:
  profile: claude-cli    # References configs/agents/claude-cli.yaml

  # Override command if needed
  # command: "claude --verbose -p \"$(cat /task-spec.md)\""

# Keychain services (auto-resolve from profile or override)
environment:
  keychain:
    ANTHROPIC_API_KEY:
      service: "Claude Code-credentials"

# User-specific config mounts (merged with profile)
filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh

# Resource limits
resources:
  memory: 8g
  cpus: 4
```

## Implementation Plan

### Phase 1: Base Image with Agent Install Support

Update `Containerfile` to support parameterized agent installation:

```dockerfile
# Build args for agent installation
ARG AGENT_NPM=""
ARG AGENT_PIP=""
ARG AGENT_SCRIPT=""

# Install via npm if specified
RUN if [ -n "$AGENT_NPM" ]; then \
      source $NVM_DIR/nvm.sh && \
      npm install -g $AGENT_NPM; \
    fi

# Install via pip if specified
RUN if [ -n "$AGENT_PIP" ]; then \
      pip3 install $AGENT_PIP; \
    fi

# Run custom script if specified
RUN if [ -n "$AGENT_SCRIPT" ]; then \
      bash -c "$AGENT_SCRIPT"; \
    fi
```

### Phase 2: Build Script for Agent Images

```bash
#!/bin/bash
# scripts/build-agent-image.sh

AGENT_PROFILE=$1  # e.g., "claude-cli"

# Parse agent profile
NPM_PKG=$(yq '.install.npm // ""' "configs/agents/${AGENT_PROFILE}.yaml")
PIP_PKG=$(yq '.install.pip // ""' "configs/agents/${AGENT_PROFILE}.yaml")

# Build image with agent installed
podman build \
  --build-arg AGENT_NPM="$NPM_PKG" \
  --build-arg AGENT_PIP="$PIP_PKG" \
  -t "kapsis-${AGENT_PROFILE}:latest" \
  -f Containerfile .
```

### Phase 3: Launch Script Updates

```bash
# scripts/launch-agent.sh additions

# New flag: --agent <profile>
# Loads profile, selects correct image, merges config

load_agent_profile() {
    local profile="$1"
    local profile_path="$KAPSIS_ROOT/configs/agents/${profile}.yaml"

    if [[ ! -f "$profile_path" ]]; then
        log_error "Agent profile not found: $profile"
        exit 1
    fi

    # Parse profile
    AGENT_NPM=$(yq '.install.npm // ""' "$profile_path")
    AGENT_COMMAND=$(yq '.command' "$profile_path")
    AGENT_AUTH_REQUIRED=$(yq '.auth.required[].name' "$profile_path")

    # Validate required auth
    for var in $AGENT_AUTH_REQUIRED; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required auth missing: $var"
            exit 1
        fi
    done

    # Select image
    if image_exists "kapsis-${profile}:latest"; then
        CONTAINER_IMAGE="kapsis-${profile}:latest"
    else
        log_warn "Agent image not found, using base image (slower)"
        CONTAINER_IMAGE="kapsis-sandbox:latest"
        # Will install at runtime
    fi
}
```

## Example: Built-in Agent Profiles

### Claude CLI (Official)

```yaml
# configs/agents/claude-cli.yaml
name: claude-cli
install:
  npm: "@anthropic-ai/claude-code"
auth:
  required:
    - name: ANTHROPIC_API_KEY
command: claude --dangerously-skip-permissions -p "$(cat /task-spec.md)"
```

### Claude API (Python SDK)

```yaml
# configs/agents/claude-api.yaml
name: claude-api
install:
  pip: anthropic
auth:
  required:
    - name: ANTHROPIC_API_KEY
command: python3 /opt/kapsis/agents/claude-api.py /task-spec.md
```

### Aider

```yaml
# configs/agents/aider.yaml
name: aider
install:
  pip: aider-chat
auth:
  required:
    - name: OPENAI_API_KEY
  optional:
    - name: ANTHROPIC_API_KEY
command: aider --yes --message-file /task-spec.md
```

### Custom/Local Agent

```yaml
# configs/agents/custom.yaml
name: custom
install:
  script: |
    curl -fsSL https://example.com/my-agent.sh | bash
command: my-agent --task /task-spec.md
```

## Usage Examples

```bash
# Build agent-specific image (once)
./scripts/build-agent-image.sh claude-cli

# Launch with agent profile
./scripts/launch-agent.sh 1 ~/git/products \
  --agent claude-cli \
  --config configs/users/my-claude.yaml \
  --task "Research Guava RateLimiter"

# Or inline agent (uses base image + runtime install)
./scripts/launch-agent.sh 1 ~/git/products \
  --agent aider \
  --task "Add unit tests for UserService"
```

## Migration Path

1. **Existing configs** continue to work (backward compatible)
2. **New `--agent` flag** is optional
3. **Pre-built images** are optional (falls back to runtime install)
4. **Gradual adoption** - users can migrate configs incrementally

## Security Considerations

1. **No secrets in profiles** - Auth references keychain, not values
2. **Validated installs** - Only allow known package managers
3. **Immutable base images** - Agent install happens at build, not runtime
4. **Config mount isolation** - Config files mounted read-only
