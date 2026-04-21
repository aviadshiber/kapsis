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
      - "24.14.1"
      - "22.14.0"
    default_version: "24.14.1"
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
  # Agent type for LSP injection, status hooks, and Claude-specific features.
  # When omitted, inferred from config filename, image name, or command string.
  # Values: claude-cli, codex-cli, gemini-cli, aider, python, interactive
  # Default: (inferred)
  type: claude-cli

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
  # Global default for inject_to (applies to all keychain entries unless overridden)
  # Valid values: "secret_store" (default, preferred) | "env" (legacy)
  # inject_to: "secret_store"

  # Secrets retrieved from system keychain (macOS Keychain / Linux secret-tool)
  # These are queried automatically at launch - no manual 'export' needed!
  # Priority: passthrough > keychain (passthrough wins if both configured)
  #
  # Options:
  #   service: (required) Exact keychain service name
  #   account: (optional) Keychain account - can be string or array for fallback
  #            Supports ${VAR} expansion (e.g., ${USER})
  #            Array example: ["primary@example.com", "fallback@example.com"]
  #   inject_to: (optional) Where to inject in container (default: "secret_store")
  #              "secret_store" = Linux Secret Service (gnome-keyring) — preferred, not visible in /proc
  #              "env" = environment variable (legacy, visible via /proc/PID/environ)
  #              Falls back to "env" if gnome-keyring is unavailable in the container.
  #              Unrecognized values produce a warning and default to "env".
  #   inject_to_file: (optional) Also write credential to file path in container
  #              Can be combined with inject_to — file injection happens first,
  #              then secret store injection (both receive the secret value).
  #   mode: (optional) File permissions for inject_to_file (default: 0600)
  #   keyring_collection: (optional) D-Bus Secret Service collection label
  #              Required for Go tools using 99designs/keyring (bkt, etc.)
  #              When set, secrets are stored with the 'profile' attribute
  #              in a named collection, making them discoverable by
  #              99designs/keyring's SecretService backend.
  #              Without this, secrets use standard service/account attributes
  #              in the default collection (works with secret-tool).
  #   keyring_profile: (optional) Override D-Bus item key / profile attribute.
  #              When set, this value is used as the 'profile' attribute key
  #              in the D-Bus collection instead of the 'account' field.
  #              Allows 'account' to be the macOS Keychain lookup key while
  #              'keyring_profile' is the container-side D-Bus key.
  #              Only meaningful when keyring_collection is also set.
  #   git_credential_for: (optional) Git hostname this credential serves.
  #              When set, registers a container-native git credential helper
  #              that returns this credential for the specified host.
  #              Replaces macOS-specific helpers (osxkeychain) automatically.
  #              Value must be a hostname (e.g., "github.com"). Issue #188.
  keychain:
    # Example: Token stored in container secret store (default behavior)
    BITBUCKET_TOKEN:
      service: "my-bitbucket-token"
      account: "${USER}"  # Supports variable expansion

    # Example: API key kept as environment variable (opt-in legacy behavior)
    ANTHROPIC_API_KEY:
      service: "anthropic-api"
      inject_to: "env"

    # Example: OAuth credentials written to file (agent-agnostic)
    AGENT_OAUTH_CREDENTIALS:
      service: "my-agent-credentials"
      inject_to_file: "~/.config/my-agent/credentials.json"
      mode: "0600"

    # Example: Fallback accounts (tries each in order until one succeeds)
    JIRA_TOKEN:
      service: "my-jira-token"
      account: ["primary@example.com", "fallback@example.com", "${USER}@example.com"]

    # Example: Token for Go CLI tools using 99designs/keyring (bkt, etc.)
    BKT_CREDENTIAL:
      service: "bkt"
      account: "host/git.taboolasyndication.com/token"
      keyring_collection: "bkt"  # Store in 'bkt' collection with profile attribute

    # Example: Different macOS account and D-Bus profile key (Issue #176)
    BKT_CREDENTIAL_V2:
      service: "bitbucket-deeperdive-bot"
      account: "aviad.s"                                    # macOS Keychain account lookup
      keyring_collection: "bkt"                              # D-Bus collection label
      keyring_profile: "host/git.taboolasyndication.com/token"  # D-Bus profile key

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
    # Default: false (true for strict/paranoid profiles)
    readonly_root: false

  # Linux Security Modules (AppArmor/SELinux)
  lsm:
    # Require AppArmor or SELinux policy to be installed
    # Default: true for paranoid only
    required: false

  # Container capabilities
  # By default, Kapsis drops all capabilities and adds back a minimal set.
  # Use this to add additional capabilities required by specific features.
  capabilities:
    # Additional capabilities to add to the container
    # Common use case: NET_BIND_SERVICE for DNS filtering (dnsmasq on port 53)
    add:
      - NET_BIND_SERVICE  # Required for network.mode: filtered

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
# CLEANUP BEHAVIOR (Fix #183)
#
# Controls automatic cleanup of stale worktrees and agent branches.
# All parameters can be overridden via environment variables.
#===============================================================================
cleanup:
  worktree:
    # Maximum age (hours) for stale worktrees. Worktrees older than this
    # are cleaned up even without a "complete" status file.
    # Default: 168 (7 days). Set to 0 to disable age-based cleanup.
    # Env: KAPSIS_CLEANUP_WORKTREE_MAX_AGE_HOURS
    max_age_hours: 168

    # Run opportunistic GC when launching a new agent
    # Default: true
    # Env: KAPSIS_CLEANUP_GC_ON_LAUNCH
    gc_on_launch: true

    # Run GC in background (non-blocking) during agent launch.
    # Prevents large-repo cleanup from delaying agent startup.
    # Default: true
    # Env: KAPSIS_CLEANUP_GC_BACKGROUND
    gc_background: true

  branch:
    # Enable automatic branch deletion after worktree cleanup.
    # When true, agent-created branches are deleted alongside their worktrees.
    # Default: false (opt-in to prevent accidental branch loss)
    # Env: KAPSIS_CLEANUP_BRANCH_ENABLED
    enabled: false

    # Branch prefixes to consider for cleanup.
    # Only branches starting with these prefixes are candidates for deletion.
    # Default: ["ai-agent/", "kapsis/"]
    # Env: KAPSIS_CLEANUP_BRANCH_PREFIXES (pipe-separated, e.g., "ai-agent/|kapsis/")
    prefixes:
      - "ai-agent/"
      - "kapsis/"

    # Protected branch patterns — never deleted, even if they match prefixes.
    # Supports regex patterns (e.g., "release/.*").
    # Default: [main, master, develop, release/.*, stable/.*]
    # Env: KAPSIS_CLEANUP_BRANCH_PROTECTED (pipe-separated)
    protected:
      - "main"
      - "master"
      - "develop"
      - "release/.*"
      - "stable/.*"

    # Only delete branches that are fully pushed to remote.
    # When true, branches with unpushed commits or no remote tracking are preserved.
    # Default: true
    # Env: KAPSIS_CLEANUP_BRANCH_REQUIRE_PUSHED
    require_pushed: true

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

  #=============================================================================
  # DNS IP PINNING (security enhancement for filtered mode)
  #=============================================================================
  # Resolves allowed domains on the trusted HOST before container launch and
  # pins those IPs inside the container via dnsmasq address=/ directives and
  # Podman --add-host flags.
  #
  # Attack vectors mitigated:
  #   1. Agent kills dnsmasq, rewrites /etc/resolv.conf to bypass filtering
  #   2. Upstream DNS poisoning returns malicious IPs for allowed domains
  #   3. Agent modifies /etc/hosts after dnsmasq is killed
  #
  # Limitations:
  #   - Wildcard domains (*.github.com) cannot be pre-resolved - they fall
  #     back to dynamic DNS and emit a security warning
  #   - CDN domains with rotating IPs may cause stale pinning
  #   - Requires network on host during container launch
  #
  dns_pinning:
    # Enable DNS IP pinning (default: true for filtered mode)
    enabled: true

    # Fallback behavior when resolution fails:
    #   dynamic - Continue with dynamic upstream DNS (degrades to current behavior)
    #   abort   - Fail container launch if resolution fails
    # Default: dynamic
    fallback: dynamic

    # Timeout for DNS resolution in seconds (1-60)
    # Default: 5
    resolve_timeout: 5

    # Protect /etc/resolv.conf and /etc/hosts from modification inside container
    # Sets chmod 444 after DNS setup (agent runs as non-root, cannot override)
    # Default: true
    protect_dns_files: true

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

  # Attribution block appended to commits and PR descriptions.
  # Placeholders: {version}, {agent_id}, {branch}, {worktree}
  #
  # For Claude Code (agent.type claude-cli/claude/claude-code), these templates
  # are injected into ~/.claude/settings.local.json as Claude's native
  # `attribution.commit` and `attribution.pr` — Claude writes them itself on
  # each commit/PR it creates. For other agents (codex, gemini, aider), Kapsis
  # appends the commit template to its host-side commits directly.
  #
  # Empty string ("") disables that attribution. Omit the `attribution` key
  # entirely to use the built-in default (Kapsis-only, no Claude co-author).
  attribution:
    commit: |
      [Generated by Kapsis](https://github.com/aviadshiber/kapsis) v{version}
      Agent: {agent_id}
    pr: "[Generated by Kapsis](https://github.com/aviadshiber/kapsis)"

  # Co-authors added to every commit (Git trailer format)
  # These are appended as "Co-authored-by:" trailers
  # Automatically deduplicated against git config user.email
  # Can also be added via the CLI flag: --co-author "Name <email>" (repeatable)
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
# CLAUDE - Agent-specific config filtering (whitelist mode)
#
# Controls which host hooks and MCP servers are available in the container.
# Only whitelisted entries are kept; everything else is removed.
# Omit a section entirely to pass everything through (no filtering).
#===============================================================================
claude:
  hooks:
    # Whitelist hooks by substring match on the command field
    # Only hooks whose command contains one of these substrings are kept
    include:
      - block-secrets          # Security hook
      - claudeignore           # File ignore patterns

  mcp_servers:
    # Whitelist MCP servers by exact key name match
    # Only servers whose JSON key exactly matches are kept
    include:
      - context7               # Documentation lookup
      - atlassian              # Jira/Confluence

#===============================================================================
# LSP SERVERS
#
# Configures Language Server Protocol servers for AI agents inside the container.
# LSP servers provide diagnostics, completions, hover, and go-to-definition.
#
# Kapsis transforms this agent-agnostic config into the agent's native format.
# CLI tools installed in the container (e.g., java-functional-lsp, pyright) are
# available as shell commands for all agents, but LSP protocol integration
# requires native agent support.
#
# Agent support:
#   Claude Code  - Native: lspServers injected into settings.local.json
#   Codex CLI    - Not yet: warning logged; LSP binary usable as CLI command
#   Gemini CLI   - Not yet: warning logged; LSP binary usable as CLI command
#   Aider        - Not yet: warning logged; LSP binary usable as CLI command
#
# When native LSP support is added by other agent vendors, open a Kapsis
# feature request for integration.
#===============================================================================
lsp_servers:
  # Each key is the server name (used in Claude Code's lspServers config)
  java-functional-lsp:
    # Required: LSP server binary (must be in container's PATH)
    command: java-functional-lsp
    # Optional: CLI arguments passed to the server
    # args: ["--stdio"]
    # Required: Language-to-extension mapping
    # Keys are LSP language IDs, values are arrays of file extensions (with dot)
    # Transformed to Claude's extensionToLanguage format (extension → language)
    languages:
      java: [".java"]

  pyright:
    command: pyright-langserver
    args: ["--stdio"]
    languages:
      python: [".py", ".pyi"]

  typescript-lsp:
    command: typescript-language-server
    args: ["--stdio"]
    languages:
      typescript: [".ts", ".tsx"]
      javascript: [".js", ".jsx"]
    # Optional: Environment variables for the LSP server process
    env:
      NODE_OPTIONS: "--max-old-space-size=4096"
    # Optional: Passed to server during LSP initialization
    initialization_options:
      preferences:
        importModuleSpecifierPreference: "relative"
    # Optional: Sent via workspace/didChangeConfiguration
    # settings:
    #   typescript.format.semicolons: "insert"

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

## Liveness Monitoring

Built-in agent liveness monitoring detects and kills hung agent processes. **Enabled by default** (Issue #257). The monitor checks three signals: hook-driven `updated_at` timestamps, process tree I/O activity across all container descendants, and TCP connection quality to AI API endpoints. All three must indicate inactivity before the agent is killed, with a two-tier grace period based on how active the API connection appears (data in flight vs. idle keepalive).

### Configuration

```yaml
liveness:
  enabled: true              # Enable liveness monitoring (default: true)
  timeout: 900               # Kill after N seconds of no activity (default: 900, min: 60)
  grace_period: 300          # Skip checks for N seconds after start (default: 300)
  check_interval: 30         # Check every N seconds (default: 30, min: 10)
  completion_timeout: 120    # Shorter timeout when agent reports done (default: 120)
  api_soft_skip: 20          # Grace cycles when API connection has data in flight (default: 20 = 10 min)
  api_hard_skip: 6           # Grace cycles when API connection is idle/keepalive (default: 6 = 3 min)
```

### K8s Backend (AgentRequest CR)

```yaml
spec:
  liveness:
    enabled: true
    timeoutSeconds: 900
    gracePeriodSeconds: 300
    checkIntervalSeconds: 30
```

### Behavior

1. **Grace period**: No checks for the first `grace_period` seconds after agent start
2. **Activity check**: Every `check_interval` seconds, monitor reads:
   - `updated_at` from status.json (set by PostToolUse hooks)
   - `read_bytes + write_bytes` from `/proc/[0-9]*/io` (all container process I/O)
   - TCP connection quality to AI API endpoints (port 443) via `/proc/net/tcp` queue depths
3. **Kill decision**: If `updated_at` is stale for >= `timeout` seconds AND I/O counters unchanged for 2+ consecutive cycles, Signal 3 provides a two-tier grace: active connections (data in flight or TCP retransmitting) get up to `api_soft_skip` cycles of grace; idle connections (open but queues empty) get up to `api_hard_skip` cycles. When all grace is exhausted → SIGTERM, wait 10s, SIGKILL
4. **Post-completion timeout** (Issue #257): When status.json phase is "complete", "committing", or "pushing", the shorter `completion_timeout` (120s) applies unconditionally — API connections do not extend the timeout in the completion phase
5. **Exit code 5**: When liveness kills an agent that had completed its work (phase="complete"/"committing"/"pushing"), exit code 5 is used instead of 137
6. **Auto-diagnostics**: Before killing, captures process tree, open FDs, TCP connections, and status.json to `kapsis-liveness-diagnostics.txt`
7. **Heartbeat**: Monitor writes `heartbeat_at` to status.json on every check cycle (independent of agent activity)

### Claude Hang Fix

For Claude Code agents, Kapsis automatically sets `CLAUDE_CODE_EXIT_AFTER_STOP_DELAY=10000` to fix the known hang-after-completion bug ([anthropics/claude-code#21099](https://github.com/anthropics/claude-code/issues/21099)). This is always enabled for Claude agents regardless of liveness config.

### Health Diagnostics

```bash
# Pretty output
kapsis-status --health <project> <agent-id>

# JSON output (for automation)
kapsis-status --health --json <project> <agent-id>
```

Shows process state, I/O activity, TCP connections, memory/CPU, hook staleness, and overall health status (HEALTHY / WARNING / CRITICAL / STOPPED / MOUNT_FAILURE).

### Mount Health Check (Issue #248)

Detects mid-run virtio-fs mount drops on macOS (Apple Hypervisor). The mount works at startup but can disconnect silently ~30 minutes in, making all `/workspace` files inaccessible.

```yaml
liveness:
  enabled: true
  mount_check: true             # Enable workspace mount health check (default: true when liveness enabled)
  mount_check_retries: 2        # Retries before declaring failure (default: 2)
  mount_check_retry_delay: 5    # Seconds between retries (default: 5)
  mount_check_probe_timeout: 5  # Seconds before probe times out (default: 5)
  mount_check_delay: 30         # Grace period before first check (default: 30s)
```

**How it works:**

1. Periodic probe runs `timeout <probe_timeout> stat /workspace` + checks workspace is non-empty + (worktree mode) verifies `.git-safe/HEAD` exists
2. A hung probe (degraded virtio-fs) counts as immediate failure — no retries
3. On confirmed failure: writes `KAPSIS_MOUNT_FAILURE:` sentinel to stderr, kills agent (SIGTERM → 10s → SIGKILL)
4. Host-side `launch-agent.sh` detects the sentinel in captured container output and overrides exit code to 4
5. Sentinel is only honored when container exit code is 143 (SIGTERM) or 137 (SIGKILL) — prevents a compromised agent from faking mount failures

**Integration with liveness:**

- When liveness IS enabled: mount probe runs inside the liveness loop (one loop, two concerns)
- When liveness is NOT enabled: standalone mount check loop via `KAPSIS_MOUNT_CHECK_ENABLED=true` env var

**Recovery:**

```bash
podman machine stop
podman machine start
# Re-run the agent
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
3. Retrieved secrets are temporarily passed to the container via `--env-file`
4. The container entrypoint stores secrets in the target location based on `inject_to`:
   - `"secret_store"` (default): Stored in Linux Secret Service (gnome-keyring), env var unset
   - `"env"`: Kept as environment variable (legacy behavior)
5. Secrets are **never logged** - dry-run output shows `***MASKED***`

### Configuration Schema

```yaml
environment:
  # Global default for inject_to (optional, default: "secret_store")
  inject_to: "secret_store"

  keychain:
    # Secret stored in container's Linux secret store (default)
    BITBUCKET_TOKEN:
      service: "my-bitbucket-token"       # Required: exact service name
      account: "optional-account"          # Optional: keychain account (supports ${VAR} expansion)

    # Secret kept as environment variable (legacy opt-in)
    ANTHROPIC_API_KEY:
      service: "anthropic-api"
      inject_to: "env"                    # Override: keep as env var

    # Fallback accounts - tries each in order until one succeeds
    MY_TOKEN:
      service: "my-service"
      account: ["primary@example.com", "fallback@example.com", "${USER}@example.com"]

    # Both file injection AND secret store (can coexist)
    AGENT_CREDENTIALS:
      service: "my-agent-creds"            # Required: keychain service name
      inject_to: "secret_store"            # Store in keyring (also the default)
      inject_to_file: "~/.agent/creds"     # Additionally write to this file in container
      mode: "0600"                         # Optional: file permissions (default: 0600)

    # Go keyring tool (99designs/keyring) — named collection with profile attribute
    BKT_CREDENTIAL:
      service: "bkt"                       # macOS keychain service name
      account: "host/example.com/token"    # Used as the keyring key
      keyring_collection: "bkt"            # Store in 'bkt' D-Bus collection
```

### Secret Store Injection (Default)

By default, keychain secrets are stored in the container's Linux Secret Service (gnome-keyring) instead of remaining as environment variables. This provides:

- Secrets **not visible** via `/proc/PID/environ`
- Secrets **not inherited** by child processes
- CLI tools using keyring libraries (e.g., `bkt`) work natively
- No per-tool workarounds needed (e.g., `BKT_ALLOW_INSECURE_STORE`)

**Requirements:** The container image must include `gnome-keyring`, `libsecret-tools`, and `dbus` (installed by default when `ENABLE_SECRET_STORE=true` in the build profile). If these packages are unavailable, Kapsis falls back to environment variable injection with a warning.

**Validation:** Unrecognized `inject_to` values (e.g., typos like `"keyring"`) produce a warning and default to `"env"`.

**Combining `inject_to_file` and `inject_to`:** These are orthogonal — both can be specified on the same entry. File injection writes the secret to disk first, then secret store injection stores it in the keyring and unsets the env var. The file and the keyring entry both receive the secret value. When `inject_file_template` is also specified, the secret is embedded inside the template before writing to the file.

To globally use environment variables instead: set `environment.inject_to: "env"` in your config.

### Go Keyring Compatibility (`keyring_collection`)

Go CLI tools using [99designs/keyring](https://github.com/99designs/keyring) (e.g., `bkt`) search for secrets differently than `secret-tool`:

- **`secret-tool`** stores with `service`/`account` attributes in the default "login" collection
- **99designs/keyring** searches by a `profile` attribute in a collection matching its `ServiceName`

The `keyring_collection` field bridges this gap. When set, Kapsis stores the secret with the correct `profile` attribute in a named D-Bus collection, making it discoverable by 99designs/keyring's SecretService backend.

```yaml
environment:
  keychain:
    BKT_CREDENTIAL:
      service: "bkt"                                    # macOS keychain service name
      account: "host/git.taboolasyndication.com/token"  # keychain account / keyring key
      keyring_collection: "bkt"                         # D-Bus collection label
```

**How it works:**
1. The secret is retrieved from macOS Keychain using `service` + `account`
2. Inside the container, `kapsis-ss-inject` (Python helper) creates the named collection if needed
3. The secret is stored with `{"profile": "<account>"}` attribute — matching what 99designs/keyring expects
4. Go tools find the secret via their standard keyring lookup

**Without `keyring_collection`:** Secrets are stored using `secret-tool` with `service`/`account` attributes (the default behavior, works with `secret-tool lookup` and libsecret-based tools).

#### Separate Host and Container Keys (`keyring_profile`)

When the macOS Keychain account name differs from the D-Bus profile key expected by the Go tool, use `keyring_profile` to decouple them:

```yaml
environment:
  keychain:
    BKT_CREDENTIAL:
      service: "bitbucket-deeperdive-bot"                       # macOS keychain service name
      account: "aviad.s"                                        # macOS keychain account (host lookup)
      keyring_collection: "bkt"                                 # D-Bus collection label
      keyring_profile: "host/git.taboolasyndication.com/token"  # D-Bus profile key
```

**How it works:**
1. The secret is retrieved from macOS Keychain using `service` + `account` (i.e., `"bitbucket-deeperdive-bot"` + `"aviad.s"`)
2. Inside the container, `kapsis-ss-inject` creates the named collection if needed
3. The secret is stored with `{"profile": "host/git.taboolasyndication.com/token"}` attribute
4. Go tools find the secret via their standard `profile` attribute lookup

**Without `keyring_profile`:** The `account` field is used as both the host keychain lookup account and the D-Bus profile key (the original behavior from Issue #170).

**Requirements:** `python3-secretstorage` must be installed in the container image (included when `ENABLE_SECRET_STORE=true`).

### Git Credential Helper (`git_credential_for`)

When host `~/.gitconfig` is mounted into containers, macOS-specific credential helpers (like `osxkeychain`) don't work in Linux containers. The `git_credential_for` field bridges this gap by registering a container-native git credential helper that reads from the gnome-keyring.

```yaml
environment:
  keychain:
    BITBUCKET_TOKEN:
      service: "taboola-bitbucket"
      account: "aviad.s"
      inject_to: "secret_store"
      git_credential_for: "git.taboolasyndication.com"  # git host to serve credentials for

    GITHUB_TOKEN:
      service: "github-pat"
      account: "myuser"
      inject_to: "secret_store"
      git_credential_for: "github.com"
```

**How it works:**
1. At launch, Kapsis builds a host-to-keyring map from entries with `git_credential_for`
2. The map is passed to the container as `KAPSIS_GIT_CREDENTIAL_MAP_DATA`
3. The entrypoint writes the map file and replaces any macOS credential helpers in `~/.gitconfig` with the container-native `git-credential-keyring`
4. When git needs credentials for a host, the helper looks up the matching keyring entry

**Both keyring paths are supported:**
- With `keyring_collection`: Uses `secret-tool lookup profile <key>` (99designs/keyring compat)
- Without `keyring_collection`: Uses `secret-tool lookup service <svc> account <acct>` (standard)

**The value is a hostname** (e.g., `github.com`, `git.example.com`). Only alphanumeric characters, dots, hyphens, and underscores are allowed.

**Without `git_credential_for`:** The secret is injected into the keyring but not registered as a git credential helper. Git operations requiring auth must use alternative methods (e.g., `bkt` CLI).

See: [Issue #188](https://github.com/aviadshiber/kapsis/issues/188)

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

### Formatted Files with `inject_file_template`

Some CLI tools require credentials embedded inside a structured config file rather than as a raw value. The `inject_file_template` field lets you define the file format inline, with `{{VALUE}}` as the placeholder for the secret:

```yaml
environment:
  keychain:
    GH_TOKEN:
      service: "gh:github.com"
      account: "aviadshiber"
      inject_to: "secret_store"
      inject_to_file: "~/.config/gh/hosts.yml"
      inject_file_template: |
        github.com:
          oauth_token: {{VALUE}}
          user: aviadshiber
          git_protocol: https
      mode: "0600"
```

**How it works:**
1. At launch, the template is base64-encoded and passed to the container via an env var
2. The entrypoint decodes the template and replaces every `{{VALUE}}` with the secret
3. The result is written to the `inject_to_file` path with the specified `mode`
4. No trailing newline is added — the template controls whitespace (use YAML `|` block scalar for a trailing newline)

**Validation rules:**
- `inject_to_file` is required when `inject_file_template` is set
- The template must contain at least one `{{VALUE}}` placeholder
- Maximum 5 `{{VALUE}}` placeholders per template
- Maximum 64 KB template size (pre-encoding)
- NUL bytes are rejected

**Without `inject_file_template`:** The raw secret value is written to the file (existing behavior, unchanged).

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
| (none) | `--remote-branch <name>` (remote branch name when different from local) |

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
- **DNS IP pinning** (new): Resolves domains on the host before container launch and pins IPs to prevent DNS manipulation inside the container
- **DNS file protection**: `/etc/resolv.conf` and `/etc/hosts` are set to read-only after DNS setup

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
# Debug with bash -x (safe - secrets use env-file, not command line)
bash -x ./scripts/launch-agent.sh ~/project --task "test"

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

> **Note:** Kapsis uses `--env-file` to pass secrets to containers, preventing
> exposure in `bash -x` traces. If `/tmp` is not writable, secrets fall back
> to inline `-e` flags and a warning is logged. Avoid `bash -x` in this case.

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

### Progress Display Environment Variables

In TTY environments, Kapsis renders in-place progress updates with animated spinners and progress bars.

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_PROGRESS_DISPLAY` | (auto) | Set to `1` when progress display is active (set automatically by `display_init`) |
| `KAPSIS_NO_PROGRESS` | (unset) | Set to `true` or `1` to disable progress display entirely |
| `NO_COLOR` | (unset) | Standard variable to disable colors (also disables progress display) |
| `TERM` | (auto) | Terminal type; `dumb` disables progress display |

**Note:** Progress display is automatically disabled for non-TTY environments (e.g., CI pipelines, piped output). In these cases, simple line-based output is used instead.

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

## Audit Logging Configuration

Kapsis provides tamper-evident, hash-chained audit logging for all agent actions inside the sandbox. Audit logging is opt-in and configured via environment variables or YAML config. For the full audit system guide, see [AUDIT-SYSTEM.md](AUDIT-SYSTEM.md).

### Audit Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `audit.enabled` | bool | `false` | Enable audit logging. When true, all agent actions are recorded as hash-chained JSONL events |
| `audit.max_file_size_mb` | int | `50` | Maximum size of a single audit file (MB) before rotation. Rotated files are suffixed `.1`, `.2`, `.3` |
| `audit.ttl_days` | int | `30` | Auto-delete audit files older than this many days |
| `audit.max_total_size_mb` | int | `500` | Total size cap for the audit directory (MB). Oldest files are pruned first when exceeded |

### YAML Example

```yaml
audit:
  enabled: true
  max_file_size_mb: 50
  ttl_days: 30
  max_total_size_mb: 500
```

### Audit Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_AUDIT_ENABLED` | `false` | Enable audit logging (`true` or `false`) |
| `KAPSIS_AUDIT_DIR` | `~/.kapsis/audit` | Directory for audit files |
| `KAPSIS_AUDIT_MAX_FILE_SIZE_MB` | `50` | Per-session file size cap (MB) before rotation |
| `KAPSIS_AUDIT_TTL_DAYS` | `30` | Auto-delete audit files older than this (days) |
| `KAPSIS_AUDIT_MAX_TOTAL_SIZE_MB` | `500` | Total audit directory size cap (MB) |

### Quick Start

```bash
# Enable audit for a single run
KAPSIS_AUDIT_ENABLED=true ./scripts/launch-agent.sh ~/project --task "implement feature"

# Generate report from latest audit file
./scripts/audit-report.sh --latest

# Verify hash chain integrity
./scripts/audit-report.sh --latest --verify
```

---

## Cleanup

For cleanup configuration and usage, see [CLEANUP.md](CLEANUP.md).

### VM Health Environment Variables (macOS)

These variables tune the `--vm-health` flag thresholds. Set them in the environment or in
your shell profile to override the built-in defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_CLEANUP_VM_INODE_WARN_PCT` | `70` | Inode warning threshold (%) |
| `KAPSIS_CLEANUP_VM_INODE_CRITICAL_PCT` | `90` | Inode critical threshold — triggers auto image cleanup (%) |
| `KAPSIS_CLEANUP_VM_DISK_WARN_PCT` | `80` | Disk usage warning threshold (%) |
| `KAPSIS_CLEANUP_VM_DISK_CRITICAL_PCT` | `95` | Disk usage critical threshold (%) |
| `KAPSIS_CLEANUP_VM_JOURNAL_VACUUM_SIZE` | `100M` | Journal vacuum target size |
| `KAPSIS_CLEANUP_VM_SSH_TIMEOUT` | `15` | Timeout (seconds) for VM SSH commands |
