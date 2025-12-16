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
  keychain:
    # Example: Claude Code API key (stored by 'claude login')
    ANTHROPIC_API_KEY:
      service: "Claude Code-credentials"

    # Example: Service token with account name
    BITBUCKET_TOKEN:
      service: "my-bitbucket-token"
      account: "${USER}"  # Optional, supports variable expansion

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
    ENV_VAR_NAME:
      service: "keychain-service-name"  # Required: exact service name
      account: "optional-account"        # Optional: keychain account (supports ${VAR} expansion)
```

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
| `sandbox.upper_dir_base` | Set via environment |

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
KAPSIS_DEBUG=1 ./scripts/launch-agent.sh 1 ~/project --task "test"

# Debug with custom log directory
KAPSIS_LOG_LEVEL=DEBUG KAPSIS_LOG_DIR=/tmp/kapsis-debug \
  ./scripts/launch-agent.sh 1 ~/project --task "test"

# Console-only logging (no file)
KAPSIS_LOG_TO_FILE=false ./scripts/launch-agent.sh 1 ~/project --task "test"

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
