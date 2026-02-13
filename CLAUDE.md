# Claude Code Guidelines for Kapsis

Essential context for AI assistants working on the Kapsis codebase.

> **Quick reference:** See `AGENTS.md` for concise repository guidelines shared across all AI agents.

## Project Overview

Kapsis is a **hermetically isolated AI agent sandbox** (v2.7.0) for running multiple AI coding agents (Claude Code, Codex CLI, Aider, Gemini CLI) in parallel with complete isolation via Podman rootless containers, Copy-on-Write filesystems, and DNS-based network filtering.

### Core Isolation Guarantees

| Resource | Isolation Method |
|----------|-----------------|
| Project files | Overlay mount (`:O`) or worktree — writes never reach host |
| Maven/Gradle cache | Per-agent container volume |
| Network | DNS allowlist + IP pinning, or complete isolation |
| Credentials | OS keychain retrieval, never written to disk |
| Containers | Podman rootless with capability dropping, seccomp, user namespaces |

## Repository Structure

```
kapsis/
├── scripts/                    # Core executables
│   ├── launch-agent.sh         # PRIMARY entry point — launches agent in sandbox
│   ├── build-image.sh          # Build base container image
│   ├── build-agent-image.sh    # Build agent-specific images
│   ├── entrypoint.sh           # Container startup script
│   ├── worktree-manager.sh     # Git worktree creation and isolation
│   ├── post-container-git.sh   # Post-exit commit/push operations
│   ├── init-git-branch.sh      # Git branch initialization
│   ├── kapsis-status.sh        # Query agent status
│   ├── kapsis-cleanup.sh       # Reclaim disk space
│   ├── preflight-check.sh      # Pre-launch validation
│   ├── merge-changes.sh        # Manual merge workflow
│   ├── configure-deps.sh       # Interactive dependency configuration
│   ├── install.sh              # Distribution installer
│   ├── switch-java.sh          # Java version switcher (in-container)
│   ├── lib/                    # Shared libraries (sourced, not executed)
│   │   ├── logging.sh          # Centralized logging with file rotation
│   │   ├── status.sh           # JSON status reporting to ~/.kapsis/status/
│   │   ├── constants.sh        # Central constants (paths, patterns, modes)
│   │   ├── compat.sh           # Cross-platform macOS/Linux helpers
│   │   ├── security.sh         # Security hardening & capability management
│   │   ├── dns-filter.sh       # DNS-based network filtering
│   │   ├── dns-pin.sh          # DNS IP pinning
│   │   ├── config-verifier.sh  # YAML config validation
│   │   ├── filter-agent-config.sh  # Agent config filtering
│   │   ├── git-remote-utils.sh # GitHub/GitLab/Bitbucket helpers
│   │   ├── ssh-keychain.sh     # SSH host key verification
│   │   ├── secret-store.sh     # OS keychain integration
│   │   ├── json-utils.sh       # JSON parsing utilities
│   │   ├── sanitize-files.sh   # File sanitization & homoglyph detection
│   │   ├── validate-scope.sh   # Filesystem scope validation
│   │   ├── version.sh          # Version management
│   │   ├── progress-display.sh # TTY progress visualization
│   │   ├── progress-monitor.sh # Progress tracking
│   │   ├── inject-status-hooks.sh # Status hook injection
│   │   └── build-config.sh     # Build configuration parser
│   └── hooks/                  # Git & pre-commit hooks
│       ├── kapsis-status-hook.sh
│       ├── kapsis-stop-hook.sh
│       ├── prepush-orchestrator.sh
│       ├── tool-phase-mapping.sh
│       ├── agent-adapters/     # Agent-specific adapters (claude, codex, gemini)
│       ├── precommit/          # Pre-commit hooks (check-tests, run-tests, spellcheck)
│       └── prepush/            # Pre-push hooks (check-docs, create-pr, pr-comments, unbiased-review)
├── configs/
│   ├── agents/                 # Agent profiles (claude-cli, claude-api, aider, codex-cli, gemini-cli)
│   ├── build-profiles/         # Container presets (minimal, java-dev, full-stack, etc.)
│   ├── specs/                  # Task specification templates (feature.md, bugfix.md)
│   ├── network-allowlist.yaml  # DNS filtering allowlist
│   └── tool-phase-mapping.yaml # Tool lifecycle mapping
├── tests/                      # 61 test files using tests/lib/test-framework.sh
│   ├── run-all-tests.sh        # Test runner with category filtering
│   └── test-*.sh               # Individual test scripts
├── docs/                       # Extended documentation (14 guides)
├── security/                   # AppArmor & seccomp profiles
├── packaging/                  # Debian, Homebrew, RPM packages
├── .github/workflows/          # CI/CD (ci, auto-release, release, security, packages, deploy-pages)
├── Containerfile               # Multi-stage container image definition
├── setup.sh                    # Initial system setup & dependency validation
└── quick-start.sh              # Simplified one-line agent launcher
```

## Documentation Map

| Topic | Reference |
|-------|-----------|
| Getting started | `README.md` |
| Architecture & data flows | `docs/ARCHITECTURE.md` |
| Configuration options | `docs/CONFIG-REFERENCE.md` |
| Build profiles & customization | `docs/BUILD-CONFIGURATION.md` |
| Git workflow | `docs/GIT-WORKFLOW.md` |
| Status & progress tracking | `docs/STATUS-TRACKING.md` |
| GitHub integration | `docs/GITHUB-SETUP.md` |
| Security hardening | `docs/SECURITY-HARDENING.md` |
| Network isolation | `docs/NETWORK-ISOLATION.md` |
| Installation | `docs/INSTALL.md` |
| Initial setup | `docs/SETUP.md` |
| Logging & testing | `CONTRIBUTING.md` |
| Cleanup operations | `docs/CLEANUP.md` |
| Test coverage analysis | `docs/TEST-COVERAGE-ANALYSIS.md` |
| Agent profiles | `configs/agents/*.yaml` |
| Security policy | `SECURITY.md` |
| AI agent guidelines | `AGENTS.md` |

## Quick Commands

```bash
# Build & run
./scripts/build-image.sh                          # Build base container image
./scripts/build-image.sh --profile java-dev       # Build with specific profile
./scripts/build-agent-image.sh claude-cli          # Build agent-specific image
./scripts/launch-agent.sh ~/project --agent claude --task "..."

# Test
./tests/run-all-tests.sh --quick            # Fast tests, no containers (~10s)
./tests/run-all-tests.sh                    # All tests (needs Podman)
./tests/run-all-tests.sh --category security # Category-specific tests
./tests/test-input-validation.sh             # Single test file

# Status & cleanup
./scripts/kapsis-status.sh                   # Show running agents
./scripts/kapsis-status.sh --json            # Machine-readable status
./scripts/kapsis-cleanup.sh                  # Reclaim disk space

# Debug
KAPSIS_DEBUG=1 ./scripts/launch-agent.sh ...
tail -f ~/.kapsis/logs/kapsis-launch-agent.log
```

## Code Style

- **Shell header:** `#!/usr/bin/env bash` then `set -euo pipefail`
- **Conditionals:** Always `[[ ]]`, never `[ ]`
- **Indentation:** 4 spaces
- **Variables:** Always quote — `"$var"`, never `$var`
- **Arithmetic with `set -e`:** Use `((count++)) || true` because `(( ))` returns exit 1 when result is 0
- **Linting:** All scripts must pass `shellcheck` (see `.shellcheckrc` for project-wide settings)
- **Logging:** Use `scripts/lib/logging.sh` — never raw `echo` for operational output
- **Tests:** Files in `tests/test-*.sh`, use `tests/lib/test-framework.sh`
- **Cross-platform:** Use `scripts/lib/compat.sh` for OS-specific operations (`sed -i`, `stat`, `date`)

### Logging Pattern

```bash
source "$SCRIPT_DIR/lib/logging.sh"
init_logging "script-name"

log_debug "Verbose diagnostic info"
log_info "Normal operation messages"
log_warn "Warning conditions"
log_error "Error conditions"
log_success "Success confirmation"
```

Logs are written to `~/.kapsis/logs/` with automatic rotation. Set `KAPSIS_DEBUG=1` or `KAPSIS_LOG_LEVEL=DEBUG` for verbose output.

### Status Reporting Pattern

```bash
source "$SCRIPT_DIR/lib/status.sh"
status_init "project" "agent-id" "branch" "worktree"
status_phase "initializing" 5 "Validating inputs"
status_phase "running" 50 "Agent executing"
status_complete 0 "Success"
```

Status is written as JSON to `~/.kapsis/status/`.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/launch-agent.sh` | Main entry point — orchestrates config, image, worktree, container |
| `scripts/entrypoint.sh` | Container startup — SDKMAN, NVM, Maven settings, credential injection |
| `scripts/worktree-manager.sh` | Git worktree isolation — creates sanitized git views for containers |
| `scripts/post-container-git.sh` | Post-exit git operations — auto-commit, push, branch creation |
| `scripts/lib/logging.sh` | Shared logging with rotation (used by all scripts) |
| `scripts/lib/status.sh` | JSON status reporting for external monitoring |
| `scripts/lib/constants.sh` | Central constants — mount paths, network modes, git patterns |
| `scripts/lib/security.sh` | Security hardening — capabilities, seccomp, security profiles |
| `scripts/lib/compat.sh` | Cross-platform helpers — macOS/Linux compatibility |
| `scripts/lib/config-verifier.sh` | Config validation — YAML schema checking |
| `scripts/lib/validate-scope.sh` | Filesystem scope enforcement — blocks out-of-bounds writes |
| `scripts/lib/sanitize-files.sh` | File sanitization — homoglyph detection, binary filtering |
| `Containerfile` | Multi-stage build with configurable languages/tools |
| `configs/agents/*.yaml` | Agent install instructions, auth, config mounts |
| `configs/build-profiles/*.yaml` | Container presets (minimal ~500MB to full-stack ~2.1GB) |
| `tests/lib/test-framework.sh` | Shared test utilities, assertions, container helpers |
| `tests/run-all-tests.sh` | Test runner with category filtering and quiet mode |

## Config Resolution Order

When `--config` is not specified, configuration is resolved in this order:

1. `./agent-sandbox.yaml` (current directory)
2. `./.kapsis/config.yaml` (project directory)
3. `<project>/.kapsis/config.yaml` (inside target project)
4. `~/.config/kapsis/default.yaml` (user home)
5. Built-in defaults

## Test Categories

| Category | Container Required | What It Tests |
|----------|--------------------|---------------|
| `agent` | No | Agent selection, config overrides, profiles, auth |
| `validation` | No | Input validation, path handling, preflight checks |
| `status` | No | Status reporting and hooks |
| `filesystem` | Yes | Copy-on-Write isolation, host unchanged |
| `maven` | Yes | Maven SNAPSHOT blocking, auth, Gradle cache |
| `security` | Partial | SSH keychain, API keys, rootless, scope validation |
| `git` | Yes | Branch creation, commit/push, worktree isolation |
| `cleanup` | Yes | Sandbox cleanup operations |
| `integration` | Yes | Full workflow, parallel agents |

Quick tests (`--quick`) run without containers in ~10 seconds. Container tests require Podman.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):

| Type | Description | Version Bump |
|------|-------------|-------------|
| `feat:` | New feature | Minor |
| `fix:` | Bug fix | Patch |
| `feat!:` / `BREAKING CHANGE:` | Breaking change | Major |
| `docs:` | Documentation only | Patch |
| `refactor:` | Code refactoring | Patch |
| `test:` | Adding/updating tests | Patch |
| `chore:` | Maintenance, dependencies | Patch |
| `ci:` | CI/CD configuration | Patch |

Format: `<type>(<optional scope>): <description>`

Releases are automated — merges to `main` trigger version bumping based on commit types, tag creation, GitHub Release, and package updates. See `CONTRIBUTING.md` for full release process.

## CI Pipeline

CI (`.github/workflows/ci.yml`) runs on every push to `main` and on PRs:

1. **Change detection** — only runs affected jobs
2. **ShellCheck lint** — all shell scripts
3. **Quick tests** — non-container tests
4. **Container tests** — isolation and workflow tests (when Containerfile or lib changes)
5. **Build validation** — container image builds successfully

### Pre-Push Checklist

```bash
# Required: lint modified scripts
shellcheck scripts/**/*.sh tests/*.sh

# Required: run quick tests
./tests/run-all-tests.sh --quick

# If configs/ changed: validate YAML configs
./scripts/lib/config-verifier.sh --all --test
```

## Security Profiles

| Profile | Features |
|---------|----------|
| `minimal` | Basic isolation only |
| `standard` (default) | Capability dropping + no-new-privileges |
| `strict` | Standard + seccomp + noexec /tmp + lower PID limit |
| `paranoid` | Strict + read-only root + LSM required |

## Network Modes

| Mode | Description |
|------|-------------|
| `none` | Complete network isolation (`--network=none`) |
| `filtered` (default) | DNS-based allowlist (git, npm, PyPI, Maven) |
| `open` | Unrestricted network access |

## Things to Avoid

1. **Hardcoding paths** — use `$KAPSIS_HOME`, `$SCRIPT_DIR`, constants from `scripts/lib/constants.sh`
2. **Platform-specific commands** — use `scripts/lib/compat.sh` helpers
3. **`[ ]` conditionals** — always use `[[ ]]`
4. **Skipping shellcheck** — all scripts must lint cleanly
5. **Committing secrets** — use keychain integration (`scripts/lib/secret-store.sh`)
6. **Raw echo for logging** — use `scripts/lib/logging.sh` functions
7. **GNU-only flags** — code must work on both macOS and Linux
8. **Bare arithmetic** — `((x++))` fails under `set -e` when result is 0; use `((x++)) || true`
9. **Working on main** — always use feature branches

## Push Fallback (Agent Recovery)

When push fails (common in containers without credentials), Kapsis outputs a structured fallback:

```
KAPSIS_PUSH_FALLBACK: cd /path/to/worktree && git push -u origin branch-name
```

**For orchestrating agents:** Grep output for `KAPSIS_PUSH_FALLBACK:` and execute the command from the host where git credentials are available.

**In status.json:** The `push_fallback_command` field contains the same command when `push_status` is `"failed"`.

## Cross-Platform Notes

- macOS container overlay tests may fail due to virtio-fs limitations — run full test coverage on Linux
- Use `compat.sh` helpers for OS-specific commands (`sed -i`, `stat`, `date`, `md5`, `xargs`)
- The `is_macos` and `is_linux` functions are available for conditional logic
