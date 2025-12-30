# Kapsis Configuration Reference

Complete reference for `agent-sandbox.yaml` configuration options.

## Configuration File Resolution

When `--config` is not specified, Kapsis looks for config files in this order:

1. `./agent-sandbox.yaml` - Current directory
2. `./.kapsis/config.yaml` - Project-specific config directory
3. `<project>/.kapsis/config.yaml` - Inside target project
4. `~/.config/kapsis/default.yaml` - User default
5. Built-in defaults

## Full Configuration Schema

```yaml
#===============================================================================
# AGENT CONFIGURATION
#===============================================================================
agent:
  # Command to launch the agent (required)
  # Placeholders:
  #   {task} - Replaced with task description
  #   $(cat /task-spec.md) - Read spec file content
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""

  # Working directory inside container
  # Default: /workspace
  workdir: /workspace

#===============================================================================
# FILESYSTEM MOUNTS
#===============================================================================
filesystem:
  # Paths to mount READ-ONLY from host into container
  # Supports:
  #   - ~ expansion (e.g., ~/.gitconfig)
  #   - Absolute paths
  # Each path is mounted at the same relative location in /home/developer/
  include:
    - ~/.gitconfig
    - ~/.ssh
    - ~/.claude

  # Paths to exclude (even if matched by include)
  exclude:
    - ~/.ssh/id_rsa_personal

#===============================================================================
# ENVIRONMENT VARIABLES
#===============================================================================
environment:
  # Secrets retrieved from system keychain (macOS Keychain / Linux secret-tool)
  # These are queried automatically at launch - no manual 'export' needed!
  # Priority: passthrough > keychain (passthrough wins if both configured)
  #
  # Options:
  #   service: (required) Exact keychain service name
  #   account: (optional) Keychain account (supports ${VAR} expansion)
  #   inject_to_file: (optional) Also write credential to file path in container
  #   mode: (optional) File permissions for inject_to_file (default: 0600)
  keychain:
    # Example: API key as environment variable only
    ANTHROPIC_API_KEY:
      service: "anthropic-api"

    # Example: OAuth credentials written to file (agent-agnostic)
    AGENT_OAUTH_CREDENTIALS:
      service: "my-agent-credentials"
      inject_to_file: "~/.config/my-agent/credentials.json"
      mode: "0600"

    # Example: Service token with account name
    BITBUCKET_TOKEN:
      service: "my-bitbucket-token"
      account: "${USER}"  # Supports variable expansion

  # Variables to pass from host to container
  # Values are taken from host environment
  # Takes priority over keychain if same variable in both
  passthrough:
    - OPENAI_API_KEY
    - GITHUB_TOKEN

  # Variables to set explicitly
  # These override host values
  set:
    MAVEN_OPTS: "-Xmx4g -XX:+UseG1GC"
    JAVA_HOME: "/opt/sdkman/candidates/java/17.0.9-tem"

#===============================================================================
# RESOURCE LIMITS
#===============================================================================
resources:
  # Memory limit (Docker/Podman format)
  # Default: 8g
  memory: 8g

  # CPU limit (number or fraction)
  # Default: 4
  cpus: 4

  # Process limit (optional)
  # pids: 1000

#===============================================================================
# MAVEN ISOLATION
#===============================================================================
maven:
  # Corporate Maven mirror URL
  # Used in isolated-settings.xml
  mirror_url: "https://artifactory.company.com/maven-virtual"

  # Block SNAPSHOT downloads from remote
  # Default: true (RECOMMENDED)
  # When true: All SNAPSHOTs must be built locally via reactor
  block_remote_snapshots: true

  # Block deploy operations
  # Default: true (RECOMMENDED)
  # Prevents accidental publication to shared repositories
  block_deploy: true

#===============================================================================
# MAVEN AUTHENTICATION
#===============================================================================
# Kapsis supports automatic Maven/Artifactory authentication via the
# DOCKER_ARTIFACTORY_TOKEN environment variable.
#
# Token Format: base64(username:password)
#
# The entrypoint.sh automatically decodes this token into:
#   - KAPSIS_MAVEN_USERNAME
#   - KAPSIS_MAVEN_PASSWORD
#
# These are then used by Maven's isolated-settings.xml for authentication.
#
# Example setup:
#   export DOCKER_ARTIFACTORY_TOKEN=$(echo -n "user:pass" | base64)
#   ./scripts/launch-agent.sh ~/project --task "build"
#
# In your config:
environment:
  passthrough:
    - DOCKER_ARTIFACTORY_TOKEN  # Decoded by entrypoint.sh
  set:
    KAPSIS_MAVEN_MIRROR_URL: "https://artifactory.company.com/maven-virtual"
    # NOTE: KAPSIS_MAVEN_USERNAME and KAPSIS_MAVEN_PASSWORD are auto-set
    # from DOCKER_ARTIFACTORY_TOKEN - do NOT set them manually

#===============================================================================
# GRADLE ENTERPRISE / DEVELOCITY
#===============================================================================
gradle_enterprise:
  # GE/Develocity server URL
  server_url: "https://gradle-enterprise.company.com/"

  # Keep build scans for observability
  # Default: true
  build_scans_enabled: true

  # Disable remote build cache
  # Default: true (RECOMMENDED for isolation)
  remote_cache_disabled: true

# NOTE: The Gradle Enterprise Maven extension is pre-cached in the container
# image during build. This is necessary because Maven extensions resolve
# BEFORE settings.xml is processed, so they cannot use authenticated mirrors.
#
# The pre-cached extensions are automatically copied to the user's
# .m2/repository at container startup by entrypoint.sh.
#
# Currently pre-cached versions:
#   - com.gradle:gradle-enterprise-maven-extension:1.20
#   - com.gradle:common-custom-user-data-maven-extension:1.12.5
#
# To update versions, modify the ARGs in Containerfile and rebuild the image.

#===============================================================================
# SANDBOX BEHAVIOR
#===============================================================================
sandbox:
  # Base directory for sandbox storage
  # Each agent gets: {upper_dir_base}/{project}-{agent-id}/
  # Default: ~/.ai-sandboxes
  upper_dir_base: ~/.ai-sandboxes

  # Auto-cleanup sandbox after merge
  # Default: false (preserve for review)
  cleanup_after_merge: false

  # Prompt for interactive merge after agent exits
  # Default: true
  interactive_merge: true

#===============================================================================
# GIT HOOKS
#===============================================================================
# In a rootless isolated container, git hooks aren't a security concern -
# they can only affect the sandboxed environment. Hooks run normally by
# default; if they fail (e.g., referencing tools not in the container),
# it's graceful degradation.
#
# To explicitly disable hooks, set KAPSIS_DISABLE_HOOKS=true
#
# git_hooks:
#   disable: false  # Set via KAPSIS_DISABLE_HOOKS env var

#===============================================================================
# GIT WORKFLOW
#===============================================================================
git:
  auto_push:
    # Enable automatic git commit and push
    # Requires --branch flag at launch
    # Default: true
    enabled: true

    # Remote to push to
    # Default: origin
    remote: origin

    # Commit message template
    # Placeholders: {task}, {agent}, {timestamp}, {branch}
    commit_message: |
      feat: {task}

      Generated by AI agent ({agent})
      Branch: {branch}

    # Stage all changes before commit
    # Default: true
    stage_all: true

    # Additional git push flags
    push_flags:
      - "--set-upstream"

  # Branch naming for auto-generated branches
  branch:
    # Prefix for branch names
    # Default: ai-agent/
    prefix: "ai-agent/"

    # Include timestamp in branch name
    # Default: true
    include_timestamp: true

#===============================================================================
# SSH HOST KEY VERIFICATION
#===============================================================================
# Kapsis verifies SSH host keys before git push to prevent MITM attacks.
# Verified keys are mounted at /etc/ssh/ssh_known_hosts inside the container.
ssh:
  # Hosts to verify SSH keys for
  # Public providers (github.com, gitlab.com, bitbucket.org) are verified
  # automatically against their official APIs.
  # Enterprise hosts require one-time setup:
  #   ./scripts/lib/ssh-keychain.sh add-host git.company.com
  verify_hosts:
    - github.com
    - gitlab.com
    - bitbucket.org
    # - git.company.com  # Enterprise host (run add-host first!)

#===============================================================================
# CONTAINER IMAGE
#===============================================================================
image:
  # Image name
  # Default: kapsis-sandbox
  name: kapsis-sandbox

  # Image tag
  # Default: latest
  tag: latest

  # Base image for building
  # Default: ubuntu:24.04
  base: ubuntu:24.04

  # Java versions to install
  java_versions:
    - "17"
    - "8"

  # Default Java version
  default_java: "17"

  # Additional packages to install
  extra_packages:
    - kafkacat
    - postgresql-client
```

## Example Configurations

### Minimal Configuration

```yaml
agent:
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""

filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh
    - ~/.claude

environment:
  keychain:
    ANTHROPIC_API_KEY:
      service: "Claude Code-credentials"
```

### Multi-Agent Setup

```yaml
# ~/.config/kapsis/claude.yaml
agent:
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""
filesystem:
  include: [~/.claude, ~/.gitconfig, ~/.ssh]
environment:
  keychain:
    ANTHROPIC_API_KEY:
      service: "Claude Code-credentials"
```

```yaml
# ~/.config/kapsis/codex.yaml
agent:
  command: "codex --approval-mode full-auto \"$(cat /task-spec.md)\""
filesystem:
  include: [~/.codex, ~/.gitconfig, ~/.ssh]
environment:
  passthrough: [OPENAI_API_KEY]  # Or use keychain if stored
```

### Enterprise Setup with Full Isolation

```yaml
agent:
  command: "claude --dangerously-skip-permissions -p \"$(cat /task-spec.md)\""
  workdir: /workspace

filesystem:
  include:
    - ~/.gitconfig
    - ~/.ssh
    - ~/.claude
    - ~/.m2/settings-security.xml

environment:
  # Secrets from keychain - no manual exports needed
  keychain:
    ANTHROPIC_API_KEY:
      service: "Claude Code-credentials"
    BITBUCKET_TOKEN:
      service: "my-bitbucket-token"
      account: "${USER}"
    GRADLE_ENTERPRISE_ACCESS_KEY:
      service: "gradle-enterprise-key"

  # Non-secrets from host environment
  passthrough:
    - HOME
    - USER

  set:
    MAVEN_OPTS: "-Xmx6g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
    KAPSIS_MAVEN_USERNAME: "${ARTIFACTORY_USER}"
    KAPSIS_MAVEN_PASSWORD: "${ARTIFACTORY_TOKEN}"

resources:
  memory: 12g
  cpus: 6

maven:
  mirror_url: "https://artifactory.company.com/maven-virtual"
  block_remote_snapshots: true
  block_deploy: true

gradle_enterprise:
  server_url: "https://ge.company.com/"
  build_scans_enabled: true
  remote_cache_disabled: true

sandbox:
  upper_dir_base: /data/ai-sandboxes
  cleanup_after_merge: false

git:
  auto_push:
    enabled: true
    remote: origin
    commit_message: |
      feat: {task}

      Generated by Kapsis AI Sandbox
      Agent: {agent}
      Branch: {branch}
      Timestamp: {timestamp}
```

## Keychain Integration

Kapsis can automatically retrieve secrets from your system's native secret store at launch time, eliminating the need for manual `export` commands.

### Supported Platforms

| Platform | Secret Store | Command Used |
|----------|--------------|--------------|
| macOS | Keychain | `security find-generic-password` |
| Linux | GNOME Keyring / KDE Wallet | `secret-tool lookup` |

### How It Works

1. At launch, Kapsis parses the `keychain` section of your config
2. For each entry, it queries the system secret store using the service name (and optional account)
3. Retrieved secrets are passed to the container as environment variables
4. Secrets are **never logged** - dry-run output shows `***MASKED***`

### Configuration Schema

```yaml
environment:
  keychain:
    # Environment variable only
    ENV_VAR_NAME:
      service: "keychain-service-name"  # Required: exact service name
      account: "optional-account"        # Optional: keychain account (supports ${VAR} expansion)

    # Environment variable + file injection (agent-agnostic)
    AGENT_CREDENTIALS:
      service: "my-agent-creds"          # Required: keychain service name
      inject_to_file: "~/.agent/creds"   # Optional: also write to this file in container
      mode: "0600"                        # Optional: file permissions (default: 0600)
```

### File Injection (Agent-Agnostic)

The `inject_to_file` option allows credentials to be written to files inside the container. This is **agent-agnostic** - it works for any agent that needs file-based credentials:

```yaml
environment:
  keychain:
    # Claude Code OAuth (file-based)
    CLAUDE_OAUTH_CREDENTIALS:
      service: "Claude Code-credentials"
      inject_to_file: "~/.claude/.credentials.json"
      mode: "0600"

    # Codex credentials (hypothetical)
    CODEX_AUTH:
      service: "codex-credentials"
      inject_to_file: "~/.codex/auth.json"

    # Aider config (hypothetical)
    AIDER_API_KEY:
      service: "aider-openai"
      inject_to_file: "~/.aider/api_key"
```

**How it works:**
1. At launch, the secret is retrieved from keychain and set as an environment variable
2. The entrypoint reads `KAPSIS_CREDENTIAL_FILES` metadata
3. For each entry with `inject_to_file`, the credential is written to that file path
4. The environment variable is then **unset** (so child processes can't read it)
5. The agent reads credentials from the file as expected

### Priority Order

When the same variable appears in multiple sections:

1. **`passthrough`** - Highest priority (from host environment)
2. **`keychain`** - Retrieved from secret store
3. **`set`** - Lowest priority (static values)

This allows you to override keychain values by exporting an environment variable.

### Common Service Names

| Tool | Service Name | How to Store |
|------|--------------|--------------|
| Claude Code | `Claude Code-credentials` | Run `claude login` |
| OpenAI | `openai-api-key` | Manual: see below |
| GitHub | `github-token` | Manual: see below |

### Storing Secrets

**macOS Keychain:**

```bash
# Store a secret
security add-generic-password -s "my-service-name" -a "$USER" -w "secret-value"

# Verify it works
security find-generic-password -s "my-service-name" -a "$USER" -w
```

**Linux (secret-tool):**

```bash
# Store a secret
echo -n "secret-value" | secret-tool store --label="My Service" service "my-service-name" account "$USER"

# Verify it works
secret-tool lookup service "my-service-name" account "$USER"
```

### Security Notes

- Secrets are retrieved at launch time and passed directly to the container
- Secrets are **never written to disk** during the launch process
- Dry-run mode masks all sensitive environment variables (`***MASKED***`)
- Container processes cannot access the host keychain

## SSH Host Key Verification

Kapsis verifies SSH host keys before git push operations to prevent MITM attacks. Verified keys are mounted into containers at `/etc/ssh/ssh_known_hosts`.

### How It Works

1. At launch, Kapsis reads the `ssh.verify_hosts` list from your config
2. For each host, it fetches and verifies the SSH host key
3. Public providers (GitHub, GitLab, Bitbucket) are verified against their official APIs
4. Enterprise hosts use fingerprints cached during one-time setup
5. Verified keys are written to a temp file and mounted read-only into the container

### Public Git Providers (Automatic)

These providers work automatically - no setup required:

| Provider | Verification Source |
|----------|---------------------|
| `github.com` | GitHub Meta API |
| `gitlab.com` | GitLab static fingerprints |
| `bitbucket.org` | Bitbucket static fingerprints |

### Enterprise Git Servers (One-Time Setup)

For self-hosted or enterprise git servers, you must add the host first:

```bash
# Interactive verification (recommended)
./scripts/lib/ssh-keychain.sh add-host git.company.com

# The script will:
# 1. Scan the server's SSH host key
# 2. Display the fingerprint for verification
# 3. Ask you to confirm (verify with IT admin if unsure)
# 4. Store the fingerprint securely in system keychain
```

### Configuration Example

```yaml
ssh:
  verify_hosts:
    - github.com                    # Public (automatic)
    - gitlab.com                    # Public (automatic)
    - git.company.com               # Enterprise (requires add-host first)
```

### Managing Custom Hosts

```bash
# List configured custom hosts
./scripts/lib/ssh-keychain.sh list-hosts

# Verify a host (check if key matches stored fingerprint)
./scripts/lib/ssh-keychain.sh verify git.company.com

# Remove a custom host
./scripts/lib/ssh-keychain.sh remove-host git.company.com
```

### Fingerprint Storage

| Platform | Storage Location |
|----------|------------------|
| macOS | Keychain (service: `kapsis-ssh-hosts`) |
| Linux | GNOME Keyring / KDE Wallet |
| Fallback | `~/.kapsis/ssh-cache/` (600 permissions) |

### Security Guarantees

- Keys are verified against official APIs or user-confirmed fingerprints
- No Trust On First Use (TOFU) by default - you must explicitly trust enterprise hosts
- Fingerprints are cached securely in system keychain (not plain files)
- Container cannot modify known_hosts (mounted read-only)
- If verification fails, git push will fail (fail-secure)

## Environment Variable Substitution

Config values can reference environment variables:

```yaml
maven:
  mirror_url: "${ARTIFACTORY_URL}/maven-virtual"

environment:
  set:
    CUSTOM_VAR: "${HOST_VAR:-default_value}"
```

## Command Line Overrides

Some config values can be overridden via command line:

| Config | CLI Override |
|--------|--------------|
| `git.auto_push.enabled` | `--no-push` |
| `agent.command` | `--interactive` |
| `image.name:image.tag` | `--image <name:tag>` |
| `sandbox.upper_dir_base` | Set via environment |

## Agent Profiles

Agent profiles define how to install and configure specific AI agents in container images. This solves cross-platform compatibility issues (macOS binaries won't run in Linux containers).

### Profile Location

Agent profiles are stored in `configs/agents/`:

```
configs/agents/
├── claude-cli.yaml    # Official Claude Code CLI
├── claude-api.yaml    # Anthropic Python SDK
└── aider.yaml         # Aider AI pair programmer
```

### Profile Schema

```yaml
# configs/agents/claude-cli.yaml
name: claude-cli
description: Claude Code CLI (official Anthropic)
version: latest

# Installation method (choose one)
install:
  npm: "@anthropic-ai/claude-code"    # NPM global install
  # pip: "anthropic"                  # Pip install
  # script: |                         # Custom script
  #   curl -fsSL https://example.com/install.sh | bash

# Dependencies (validated at build time)
dependencies:
  - nodejs >= 18

# Authentication requirements
auth:
  required:
    - name: ANTHROPIC_API_KEY
      description: "Anthropic API key"
      keychain:
        macos:
          service: "Claude Code-credentials"
        linux:
          service: "anthropic-api-key"
  optional:
    - name: CLAUDE_CODE_OAUTH_TOKEN
      description: "OAuth token for headless mode"

# Config files to mount from host
config_mounts:
  - source: ~/.claude.json
    target: ~/.claude.json
  - source: ~/.claude
    target: ~/.claude

# Command template
command: >
  claude --dangerously-skip-permissions -p "$(cat ${TASK_SPEC})"

# Resource recommendations
resources:
  memory_min: 4g
  memory_recommended: 8g
  cpus_min: 2
  cpus_recommended: 4
```

### Building Agent Images

Use `build-agent-image.sh` to create agent-specific container images:

```bash
# Build Claude CLI image
./scripts/build-agent-image.sh claude-cli
# Creates: kapsis-claude-cli:latest

# Build Aider image
./scripts/build-agent-image.sh aider
# Creates: kapsis-aider:latest

# List available profiles
./scripts/build-agent-image.sh --help
```

### Using Agent Images

```bash
# Method 1: --image flag (highest priority)
./scripts/launch-agent.sh ~/project \
    --image kapsis-claude-cli:latest \
    --task "implement feature"

# Method 2: In config file
# image:
#   name: kapsis-claude-cli
#   tag: latest
```

### Creating Custom Profiles

1. Copy an existing profile:
   ```bash
   cp configs/agents/claude-cli.yaml configs/agents/my-agent.yaml
   ```

2. Edit the profile with your agent's installation method and command

3. Build the image:
   ```bash
   ./scripts/build-agent-image.sh my-agent
   ```

### Image Priority

When determining which image to use:

1. **`--image` flag** - Highest priority (command line)
2. **Config file** (`image.name:image.tag`) - From YAML config
3. **Default** (`kapsis-sandbox:latest`) - Base image without agent

## Logging Configuration

Kapsis includes comprehensive logging with file rotation. Logging is configured via environment variables (not in the YAML config file).

### Log Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_LOG_LEVEL` | INFO | Minimum log level to output. Values: `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `KAPSIS_LOG_DIR` | ~/.kapsis/logs | Directory for log files |
| `KAPSIS_LOG_TO_FILE` | true | Enable/disable file logging |
| `KAPSIS_LOG_MAX_SIZE_MB` | 10 | Maximum log file size before rotation (in MB) |
| `KAPSIS_LOG_MAX_FILES` | 5 | Number of rotated log files to keep |
| `KAPSIS_LOG_CONSOLE` | true | Enable/disable console output |
| `KAPSIS_LOG_TIMESTAMPS` | true | Include timestamps in log messages |
| `KAPSIS_DEBUG` | (unset) | Shortcut to enable DEBUG level (set to any value) |

### Log Files

Each script creates its own log file:

```
~/.kapsis/logs/
├── kapsis-launch-agent.log      # Main launch script
├── kapsis-worktree-manager.log  # Git worktree operations
├── kapsis-post-container-git.log # Post-container git ops
├── kapsis-build-image.log       # Container builds
├── kapsis-setup.log             # Setup script
└── kapsis-entrypoint.log        # Container entrypoint (in container)
```

### Log Rotation

When a log file exceeds `KAPSIS_LOG_MAX_SIZE_MB`, it is rotated:

```
kapsis-launch-agent.log      # Current log
kapsis-launch-agent.log.1    # Previous (newest rotated)
kapsis-launch-agent.log.2    # Older
kapsis-launch-agent.log.3    # ...
kapsis-launch-agent.log.4    # ...
kapsis-launch-agent.log.5    # Oldest (will be deleted on next rotation)
```

### Debug Examples

```bash
# Enable debug logging for troubleshooting
KAPSIS_DEBUG=1 ./scripts/launch-agent.sh ~/project --task "test"

# Debug with custom log directory
KAPSIS_LOG_LEVEL=DEBUG KAPSIS_LOG_DIR=/tmp/kapsis-debug \
  ./scripts/launch-agent.sh ~/project --task "test"

# Console-only logging (no file)
KAPSIS_LOG_TO_FILE=false ./scripts/launch-agent.sh ~/project --task "test"

# View logs in real-time
tail -f ~/.kapsis/logs/kapsis-launch-agent.log
```

### Log Format

**Console format** (with colors):
```
[2025-01-15 10:30:45] [INFO] [launch-agent] Starting container...
```

**File format** (with caller context):
```
[2025-01-15 10:30:45] [INFO] [launch-agent] [main:142] Starting container...
```

The file format includes the function name and line number (`main:142`) to aid debugging.

## Status Reporting Configuration

Kapsis provides JSON-based status reporting for monitoring agent progress. This is configured via environment variables.

### Status Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_STATUS_ENABLED` | true | Enable/disable status reporting |
| `KAPSIS_STATUS_DIR` | ~/.kapsis/status | Directory for status files |
| `KAPSIS_STATUS_VERSION` | 1.0 | JSON schema version |

### Status File Location

Status files are created at: `~/.kapsis/status/kapsis-{project}-{agent_id}.json`

Example: `~/.kapsis/status/kapsis-products-1.json`

### Query Status with CLI

```bash
# List all agents
./scripts/kapsis-status.sh

# Get specific agent
./scripts/kapsis-status.sh <project> <agent-id>

# Watch mode (live updates every 2s)
./scripts/kapsis-status.sh --watch

# JSON output for scripting
./scripts/kapsis-status.sh --json

# Clean up old completed status files (>24h)
./scripts/kapsis-status.sh --cleanup
```

### Status File Schema

```json
{
  "version": "1.0",
  "agent_id": "1",
  "project": "products",
  "branch": "feature/DEV-123",
  "sandbox_mode": "worktree",
  "phase": "running",
  "progress": 50,
  "message": "Agent executing task",
  "started_at": "2025-12-16T14:30:00Z",
  "updated_at": "2025-12-16T14:35:00Z",
  "exit_code": null,
  "error": null,
  "worktree_path": "/Users/user/.kapsis/worktrees/products-1",
  "pr_url": null
}
```

### Phase Definitions

| Phase | Progress | Description |
|-------|----------|-------------|
| `initializing` | 0-10% | Validating inputs, loading config |
| `preparing` | 10-20% | Creating sandbox, setting up volumes |
| `starting` | 20-25% | Launching container |
| `running` | 25-90% | Agent executing task |
| `committing` | 90-95% | Staging and committing changes |
| `pushing` | 95-99% | Pushing to remote |
| `complete` | 100% | Task finished |

### Scripting Examples

**Wait for agent completion:**

```bash
#!/bin/bash
project="products"
agent_id="1"

while true; do
    status=$(./scripts/kapsis-status.sh "$project" "$agent_id" --json 2>/dev/null)
    phase=$(echo "$status" | grep -o '"phase": *"[^"]*"' | cut -d'"' -f4)

    if [[ "$phase" == "complete" ]]; then
        exit_code=$(echo "$status" | grep -o '"exit_code": *[0-9]*' | grep -o '[0-9]*')
        echo "Agent completed with exit code: $exit_code"
        exit "$exit_code"
    fi

    sleep 5
done
```

**Monitor multiple agents:**

```bash
# Get all active agents as JSON
./scripts/kapsis-status.sh --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
active = [a for a in data if a['phase'] != 'complete']
print(f'{len(active)} agents running')
for a in active:
    print(f\"  {a['project']}/{a['agent_id']}: {a['phase']} ({a['progress']}%)\")
"
```

### Disabling Status Reporting

To disable status reporting entirely:

```bash
KAPSIS_STATUS_ENABLED=false ./scripts/launch-agent.sh ~/project --task "test"
```

---

## Cleanup

For cleanup configuration and usage, see [CLEANUP.md](CLEANUP.md).
