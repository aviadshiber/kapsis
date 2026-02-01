# Kapsis Configuration Reference

Complete reference for `agent-sandbox.yaml` configuration options.

## Configuration File Resolution

When `--config` is not specified, Kapsis looks for config files in this order:

1. `./agent-sandbox.yaml` - Current directory
2. `./.kapsis/config.yaml` - Project-specific config directory
3. `<project>/.kapsis/config.yaml` - Inside target project
4. `~/.config/kapsis/default.yaml` - User default
5. Built-in defaults

## Build Configuration (build-config.yaml)

Kapsis supports customizable container images through build configuration profiles. This allows you to create optimized images for specific use cases.

### Build Configuration vs Agent Configuration

| File | Purpose | Used By |
|------|---------|---------|
| `configs/build-config.yaml` | Container image contents (languages, tools) | `build-image.sh` |
| `configs/build-profiles/*.yaml` | Preset build configurations | `build-image.sh --profile` |
| `agent-sandbox.yaml` | Agent runtime behavior | `launch-agent.sh` |

### Quick Start

```bash
# Build with a profile
./scripts/build-image.sh --profile java-dev

# Configure interactively
./scripts/configure-deps.sh

# Configure for AI agents (JSON output)
./scripts/configure-deps.sh --profile minimal --json
```

### Build Configuration Schema

```yaml
version: "1.0"

languages:
  java:
    enabled: true
    versions:
      - "21.0.6-zulu"
      - "17.0.14-zulu"
      - "8.0.422-zulu"
    default_version: "17.0.14-zulu"

  nodejs:
    enabled: true
    versions:
      - "18.18.0"
      - "20.10.0"
    default_version: "18.18.0"
    package_managers:
      pnpm: "9.15.3"
      yarn: "latest"

  python:
    enabled: true
    version: "system"
    venv: true
    pip: true

  rust:
    enabled: false
    channel: "stable"
    components:
      - "rustfmt"
      - "clippy"

  go:
    enabled: false
    version: "1.22.0"

build_tools:
  maven:
    enabled: true
    version: "3.9.9"

  gradle:
    enabled: false
    version: "8.5"

  gradle_enterprise:
    enabled: true
    extension_version: "1.20"
    ccud_version: "1.12.5"

  protoc:
    enabled: true
    version: "25.1"

system_packages:
  development:
    enabled: true
  shells:
    enabled: true
  utilities:
    enabled: true
  overlay:
    enabled: true
  custom: []
```

### Available Profiles

| Profile | Est. Size | Languages | Best For |
|---------|-----------|-----------|----------|
| `minimal` | ~500MB | None | Shell scripts, basic tasks |
| `java-dev` | ~1.5GB | Java 17/8 | Taboola Java development |
| `java8-legacy` | ~1.3GB | Java 8 only | Legacy Java 8 projects |
| `full-stack` | ~2.1GB | Java, Node.js, Python | Multi-language projects |
| `backend-go` | ~1.2GB | Go, Python | Go microservices |
| `backend-rust` | ~1.4GB | Rust, Python | Rust backend services |
| `ml-python` | ~1.8GB | Python, Node.js, Rust | ML/AI development |
| `frontend` | ~1.2GB | Node.js, Rust | Frontend/WebAssembly |

See [BUILD-CONFIGURATION.md](BUILD-CONFIGURATION.md) for detailed documentation.

---

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

  # Enable gist instruction injection into project files (CLAUDE.md, AGENTS.md)
  # When true, appends gist update instructions to help agents report live status
  # Default: false (opt-in for safe rollout)
  inject_gist: false

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
  #   account: (optional) Keychain account - can be string or array for fallback
  #            Supports ${VAR} expansion (e.g., ${USER})
  #            Array example: ["primary@example.com", "fallback@example.com"]
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

    # Example: Fallback accounts (tries each in order until one succeeds)
    JIRA_TOKEN:
      service: "my-jira-token"
      account: ["primary@example.com", "fallback@example.com", "${USER}@example.com"]

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
# SECURITY HARDENING
#===============================================================================
# Container security profiles with increasing levels of protection.
# See docs/SECURITY-HARDENING.md for detailed documentation.
#
# Profiles:
#   minimal   - No restrictions (trusted execution only)
#   standard  - Drops capabilities, prevents privilege escalation
#   strict    - Adds syscall filtering (seccomp), noexec /tmp (untrusted execution)
#   paranoid  - Adds read-only root, requires AppArmor/SELinux
#
security:
  # Security profile to use
  # Default: standard
  profile: standard

  # Seccomp syscall filtering
  # Blocks dangerous syscalls: ptrace, mount, bpf, kexec_load, etc.
  # Default: enabled for strict/paranoid, disabled for standard/minimal
  seccomp:
    enabled: true  # Recommended even for standard profile
    # profile: /custom/seccomp.json  # Optional custom profile

  # Process isolation
  process:
    # Maximum processes the agent can spawn (prevents fork bombs)
    # Default: minimal=unlimited, standard=1000, strict=500, paranoid=300
    pids_limit: 1000

    # Prevent setuid/setgid executables from escalating privileges
    # Default: true for standard/strict/paranoid
    no_new_privileges: true

  # Filesystem hardening
  filesystem:
    # Mount /tmp with noexec flag (blocks executing code from /tmp)
    # Default: true for strict/paranoid
    noexec_tmp: false

    # Make container root (/usr, /bin) read-only (/workspace remains writable)
    # Default: true for paranoid only
    readonly_root: false

  # Linux Security Modules (AppArmor/SELinux)
  lsm:
    # Require AppArmor or SELinux policy to be installed
    # Default: true for paranoid only
    required: false

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
# PROTOBUF/PROTOC SUPPORT
#===============================================================================
# Kapsis pre-caches protoc binaries for common versions, enabling proto
# compilation without runtime network access. This is necessary because
# the protobuf-maven-plugin downloads platform-specific protoc binaries
# that cannot use authenticated mirrors.
#
# Pre-cached versions:
#   - protoc 25.1 (linux-x86_64, linux-aarch_64)
#
# Custom Protoc Versions:
# If your project requires a different protoc version, you can:
#
# 1. Rebuild the image with custom version:
#    podman build --build-arg PROTOC_VERSION=24.4 -t kapsis-custom:latest .
#
# 2. The pre-cached binaries are automatically available in ~/.m2/repository
#    when the container starts.

#===============================================================================
# JAVA VERSION CONFIGURATION
#===============================================================================
# Kapsis supports automatic Java version switching via KAPSIS_JAVA_VERSION.
# When set, the entrypoint automatically switches to the specified Java version
# using SDKMAN.
#
# Available Java versions in the container:
#   - 17 (default)
#   - 8
#
# Configuration via environment.set:
environment:
  set:
    KAPSIS_JAVA_VERSION: "8"  # Switch to Java 8 at startup
#
# This is useful for projects that require specific Java versions, such as
# legacy codebases requiring Java 8 compatibility.

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
# NETWORK ISOLATION
#===============================================================================
network:
  # Network isolation mode
  # - none:     Complete network isolation (--network=none)
  # - filtered: DNS-based allowlist filtering (default, recommended)
  # - open:     Unrestricted network access
  # Default: filtered
  mode: filtered

  # DNS allowlist - domains the agent can access in filtered mode
  # Organized by category for maintainability
  allowlist:
    # Git hosting providers
    hosts:
      - github.com
      - "*.github.com"
      - gitlab.com
      - "*.gitlab.com"
      - bitbucket.org
      - "*.bitbucket.org"

    # Package registries
    registries:
      - registry.npmjs.org
      - pypi.org
      - "*.pypi.org"
      - repo.maven.apache.org
      - "*.maven.org"

    # Container registries
    containers:
      - docker.io
      - "*.docker.io"
      - ghcr.io
      - quay.io

    # AI/LLM APIs (required for AI agents)
    ai:
      - api.anthropic.com
      - api.openai.com

    # Custom domains for your organization
    custom:
      - artifactory.company.com
      - git.company.com

  # DNS servers for domain resolution (filtered mode)
  # Default: 8.8.8.8,8.8.4.4 (Google Public DNS)
  dns_servers:
    - 8.8.8.8
    - 8.8.4.4

  # Log DNS queries for debugging
  # Default: false
  log_dns_queries: false

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
    # Available placeholders (substituted at launch time):
    #   {task}      - Task description (from --task or spec filename)
    #   {agent}     - Agent name (claude, codex, aider)
    #   {agent_id}  - Unique 6-char agent ID
    #   {branch}    - Git branch name
    #   {timestamp} - Current timestamp (YYYY-MM-DD_HHMMSS)
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

  # Co-authors added to every commit (Git trailer format)
  # These are appended as "Co-authored-by:" trailers
  # Automatically deduplicated against git config user.email
  co_authors:
    - "Aviad Shiber <aviadshiber@gmail.com>"
    # - "Another Author <another@example.com>"

  # Commit exclude patterns (issue #89)
  # Files matching these patterns are automatically unstaged before commit
  # This prevents accidental commits of files that should stay local
  # Default: ".gitignore\n**/.gitignore\n.gitattributes\n**/.gitattributes"
  commit_exclude:
    - ".gitignore"
    - "**/.gitignore"
    - ".gitattributes"
    - "**/.gitattributes"

  # Fork-first workflow for contributing to external repos
  # When enabled, provides fork fallback command when push fails
  fork_workflow:
    # Enable fork workflow fallback
    # Default: false
    enabled: false

    # Fallback behavior when push fails:
    #   "fork" - Generate gh repo fork + push command
    #   "manual" - Just show manual push command
    # Default: fork
    fallback: fork

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

    # Fallback accounts - tries each in order until one succeeds
    MY_TOKEN:
      service: "my-service"
      account: ["primary@example.com", "fallback@example.com", "${USER}@example.com"]

    # Environment variable + file injection (agent-agnostic)
    AGENT_CREDENTIALS:
      service: "my-agent-creds"          # Required: keychain service name
      inject_to_file: "~/.agent/creds"   # Optional: also write to this file in container
      mode: "0600"                        # Optional: file permissions (default: 0600)
```

### Account Fallback

When `account` is specified as an array, Kapsis tries each account in order until it finds a matching credential. This is useful when:

- Tokens may be stored under different account names on different machines
- You want to support multiple users with the same config file
- You need backward compatibility with existing keychain entries

```yaml
environment:
  keychain:
    JIRA_TOKEN:
      service: "my-jira"
      account: ["team-lead@example.com", "developer@example.com", "${USER}@example.com"]
```

Debug logging shows which account succeeded (obfuscated for security).

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

## Commit Exclude Patterns

Kapsis automatically prevents certain files from being committed. This addresses issue #89 where `.gitignore` modifications were appearing in user PRs.

### How It Works

1. **Internal patterns** use `$GIT_DIR/info/exclude` (never committed, fully transparent)
2. **Commit-time filtering** unstages files matching `KAPSIS_COMMIT_EXCLUDE` patterns before commit

### Default Excluded Patterns

These files are automatically unstaged before commit:
- `.gitignore` / `**/.gitignore` - Git ignore files
- `.gitattributes` / `**/.gitattributes` - Git attributes files

### Configuration

**Via environment variable:**

```bash
# Custom patterns (newline-separated)
export KAPSIS_COMMIT_EXCLUDE=".gitignore
**/.gitignore
.env.local"

./scripts/launch-agent.sh ~/project --task "implement feature"
```

**Via config file:**

```yaml
git:
  commit_exclude:
    - ".gitignore"
    - "**/.gitignore"
    - ".env.local"
    - "**/*.bak"
```

### Pattern Syntax

Patterns follow gitignore syntax:
- `file.txt` - Matches `file.txt` at root only
- `**/file.txt` - Matches `file.txt` at any depth
- `*.log` - Matches any `.log` file at root
- `**/*.log` - Matches any `.log` file at any depth

### Internal Excludes

These patterns are always excluded via `$GIT_DIR/info/exclude` (transparent to user):
- `.kapsis/` - Internal Kapsis files
- `.claude/`, `.codex/`, `.aider/` - AI tool configs
- `~`, `~/` - Literal tilde paths (failed expansion)

## Command Line Overrides

Some config values can be overridden via command line:

| Config | CLI Override |
|--------|--------------|
| `network.mode` | `--network-mode <none\|filtered\|open>` |
| `git.auto_push.enabled` | `--push` (enables push, default: off) |
| `agent.command` | `--interactive` |
| `image.name:image.tag` | `--image <name:tag>` |
| `sandbox.upper_dir_base` | Set via environment |

## Network Isolation

Kapsis provides DNS-based network filtering to control which external services the agent can access.

### Network Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `none` | Complete isolation (`--network=none`) | Maximum security, offline tasks |
| `filtered` | DNS-based allowlist **(default)** | Standard development workflows |
| `open` | Unrestricted network access | Special cases requiring full access |

### Using Filtered Mode

Filtered mode uses dnsmasq to implement DNS-based allowlisting. Only domains in the allowlist can be resolved; all other domains return NXDOMAIN.

```bash
# Default (filtered mode)
kapsis ~/project --task "implement feature"

# Explicit filtered mode
kapsis ~/project --network-mode filtered --task "test"
```

### Configuration Priority

Network mode can be set through multiple methods (highest to lowest priority):

1. **CLI flag**: `--network-mode filtered`
2. **Environment variable**: `KAPSIS_NETWORK_MODE=filtered`
3. **Config file**: `network.mode: filtered`
4. **Default**: `filtered`

### Customizing Allowlist

The default allowlist (`configs/network-allowlist.yaml`) includes common development domains. Override with your config:

```yaml
network:
  mode: filtered
  allowlist:
    hosts:
      - github.com
      - git.company.com
    registries:
      - artifactory.company.com
    ai:
      - api.anthropic.com
```

### Security Features

- **DNS rebinding protection**: Rejects DNS responses containing private IP ranges
- **Fail-safe initialization**: Container aborts if DNS filtering fails to start
- **Verification**: DNS filtering is verified before agent execution
- **Query logging**: Enable `log_dns_queries: true` for debugging

### Debugging Network Issues

```bash
# Enable DNS query logging
export KAPSIS_DNS_LOG_QUERIES=true

# Check if domain is blocked/allowed (inside container)
nslookup github.com 127.0.0.1

# View DNS logs (inside container)
cat /tmp/kapsis-dns.log
```

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
  # Native installer (recommended for Claude) - no Node.js required
  script: "curl -fsSL https://claude.ai/install.sh | bash"
  binary_path: "/usr/local/bin/claude"
  # npm: "@anthropic-ai/claude-code"  # (deprecated - use native installer)
  # pip: "anthropic"                  # Pip install (for claude-api)

# Dependencies (validated at build time)
# Claude CLI native installer only requires git
dependencies:
  - git

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
# Build Claude CLI with minimal profile (smallest, ~450MB)
./scripts/build-agent-image.sh claude-cli --profile minimal

# Build Claude CLI with Java 8 support (~1GB)
./scripts/build-agent-image.sh claude-cli --profile java8-legacy

# Build Claude CLI with full Java dev environment (~2.1GB)
./scripts/build-agent-image.sh claude-cli --profile java-dev

# Build Aider (requires Python, use full-stack profile)
./scripts/build-agent-image.sh aider --profile full-stack

# List available profiles
./scripts/build-agent-image.sh --help
```

**Note:** Claude CLI uses a native installer and works with the `minimal` profile (no Node.js required). Other agents like Aider, Codex, and Gemini require specific language runtimes.

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
