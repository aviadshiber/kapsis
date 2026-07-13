# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Quick reference:** See `AGENTS.md` for concise repository guidelines shared across all AI agents.

## Project Overview

Kapsis is a **hermetically isolated AI agent sandbox** for running multiple AI coding agents (Claude Code, Codex CLI, Aider, Gemini CLI) in parallel with complete isolation via Podman rootless containers, Copy-on-Write filesystems, and DNS-based network filtering. Current version: see `VERSION` (or the latest GitHub Release) — released on every merge to `main`, so any version noted here would be stale within days.

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
│   ├── post-exit-git.sh        # Post-exit commit/push (host-side)
│   ├── init-git-branch.sh      # Git branch initialization
│   ├── kapsis-status.sh        # Query agent status
│   ├── kapsis-cleanup.sh       # Reclaim disk space (incl. TTL snapshot/conversation expiry)
│   ├── kapsis-recovery-action.sh # Map error_type → recovery action (Issue #262)
│   ├── preflight-check.sh      # Pre-launch validation
│   ├── merge-changes.sh        # Manual merge workflow
│   ├── configure-deps.sh       # Interactive dependency configuration
│   ├── install.sh              # Distribution installer
│   ├── switch-java.sh          # Java version switcher (in-container)
│   ├── audit-report.sh         # Audit report generation
│   ├── k8s-deploy.sh           # K8s operator deployment helper
│   ├── kapsis-ss-inject.py     # Status hook injector (Python)
│   ├── git-credential-keyring  # Git credential helper using OS keychain
│   ├── setup-github-protection.sh  # GitHub branch protection setup
│   ├── setup-homebrew-tap-sync.sh  # Homebrew tap sync setup
│   ├── setup-package-repos.sh  # Package repository setup
│   ├── setup-release-app.sh    # Release app setup
│   ├── lib/                    # Shared libraries (sourced, not executed) —
│   │                           #   see the Key Files table below for the
│   │                           #   important ones, `ls scripts/lib/` for
│   │                           #   the full current list (it grows often)
│   ├── backends/               # Backend implementations
│   │   ├── podman.sh           # Podman backend (default)
│   │   └── k8s.sh              # Kubernetes backend (AgentRequest CRD)
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
│   ├── build-profiles/         # Container presets (minimal, java-dev, java8-legacy, frontend,
│   │                           #   backend-go, backend-rust, ml-python, full-stack)
│   ├── specs/                  # Task specification templates (feature.md, bugfix.md)
│   ├── network-allowlist.yaml  # DNS filtering allowlist
│   ├── tool-phase-mapping.yaml # Tool lifecycle mapping
│   └── k8s/                    # K8s backend configs and examples
├── tests/                      # Test files using tests/lib/test-framework.sh
│                               #   (`ls tests/test-*.sh | wc -l` for current count)
│   ├── run-all-tests.sh        # Test runner with category filtering
│   └── test-*.sh               # Individual test scripts
├── docs/                       # Extended documentation — see Documentation Map below
│   ├── designs/                # Design documents (agent-profiles-architecture.md)
│   └── *.md                    # Reference guides
├── cmd/
│   └── kapsis-ctl/             # Host-side Podman query/control binary (Phases 1–2, issue #266)
│       ├── go.mod              # Separate module — stdlib-only, no operator deps
│       ├── main.go             # Entry point + subcommand dispatch
│       └── podman/             # libpod REST API client + types + validation
├── operator/                   # K8s operator (Go, kubebuilder)
│   ├── api/v1alpha1/           # AgentRequest CRD types
│   ├── internal/controller/    # Reconciliation logic (pod builder, network policy, status bridge)
│   ├── config/                 # Kustomize manifests, CRD, RBAC
│   └── test/                   # E2E tests and utilities
├── dashboard/                  # Local web dashboard (Bun + TypeScript, single binary)
│   ├── server/                 # Bun.serve() HTTP/SSE; consumes ~/.kapsis/ state
│   │   ├── src/store/          # Status, audit, logs, conversations, disk, health readers
│   │   ├── src/control/        # kill / cleanup wrappers + dashboard audit writer
│   │   └── tests/              # bun:test
│   └── ui/                     # Vite + React + TypeScript SPA (embedded into the binary)
├── bin/                        # Built binaries (git-ignored); produced by `make build-ctl`
├── maven/                      # Maven config (isolated-settings.xml for in-container builds)
├── assets/                     # Static artifacts (logos, etc.)
├── security/                   # AppArmor & seccomp profiles
├── packaging/                  # Debian, Homebrew, RPM packages
├── .github/workflows/          # CI/CD (ci, auto-release, release, security, packages, deploy-pages, sync-homebrew-tap)
├── Makefile                    # Top-level targets: build-ctl, test-ctl, vet-ctl, all-ctl
├── Containerfile               # Multi-stage container image definition
├── setup.sh                    # Initial system setup & dependency validation
├── quick-start.sh              # Simplified one-line agent launcher
├── agent-sandbox.yaml.template # Configuration template
└── index.html                  # Landing page
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
| Audit system | `docs/AUDIT-SYSTEM.md` |
| Network isolation | `docs/NETWORK-ISOLATION.md` |
| K8s backend | `docs/K8S-BACKEND.md` |
| Podman `libkrun`/`krunkit` provider (opt-in, macOS) | `docs/KRUNKIT-PROVIDER.md` |
| Installation | `docs/INSTALL.md` |
| Initial setup | `docs/SETUP.md` |
| Logging & testing | `CONTRIBUTING.md` |
| Testing guide (test tiers & conventions) | `docs/TESTING.md` |
| Cleanup operations | `docs/CLEANUP.md` |
| Test coverage analysis | `docs/TEST-COVERAGE-ANALYSIS.md` |
| Security vulnerability scan | `docs/SECURITY-VULNERABILITY-SCAN.md` |
| Agent profiles design | `docs/designs/agent-profiles-architecture.md` |
| Agent profiles | `configs/agents/*.yaml` |
| Plugin hook injection | `docs/PLUGINS.md` |
| Security policy | `SECURITY.md` |
| AI agent guidelines | `AGENTS.md` |
| Dashboard | `docs/DASHBOARD.md` |

## Quick Commands

```bash
# Build & run
./scripts/build-image.sh                          # Build base container image
./scripts/build-image.sh --profile java-dev       # Build with specific profile
./scripts/build-agent-image.sh claude-cli          # Build agent-specific image
./scripts/launch-agent.sh ~/project --agent claude --task "..."
./scripts/launch-agent.sh ~/project --backend k8s --task "..."  # K8s backend
./scripts/launch-agent.sh ~/project --backend k8s --task "..." --dry-run  # Preview CR YAML

# Test
./tests/run-all-tests.sh --quick            # Fast tests, no containers (~10s)
./tests/run-all-tests.sh                    # All tests (needs Podman)
./tests/run-all-tests.sh --category security # Category-specific tests
./tests/test-input-validation.sh             # Single test file

# Status & cleanup
./scripts/kapsis-status.sh                   # Show running agents
./scripts/kapsis-status.sh --json            # Machine-readable status
./scripts/kapsis-cleanup.sh                  # Reclaim disk space

# Dashboard (local web UI)
cd dashboard && bun install
bun run dev                                  # parallel server + Vite dev (proxy → 127.0.0.1:7777)
bun run compile                              # single-binary release → dashboard/bin/kapsis-dashboard
./dashboard/bin/kapsis-dashboard --open      # start + open browser; token printed to stdout

# Audit
./scripts/audit-report.sh                    # Generate audit report

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
| `cmd/kapsis-ctl/` | **Phases 1–2 — packaged for macOS only, via Homebrew, libexec-only (issue #429).** Read-only queries (`inspect`, `list`, `alive`) + control (`stop`, `logs`, `cp`). Build with `make build-ctl`; `--version` is stamped at build time (`-X main.version=...`, `dev` otherwise). Staged into `libexec/bin/kapsis-ctl` by the Homebrew formula — deliberately NOT symlinked into `bin/`, since it's an internal helper for `scripts/lib/podman-health.sh`'s macOS-only auto-heal path, not a supported public command. No RPM/Debian packaging and no Linux build: the only caller (`maybe_autoheal_podman_vm`) early-returns on Linux and is additionally gated behind `is_macos` at its call site, so there is no Linux consumer. MUST NOT be installed inside container images (see issue #266 for the Phase 3 roadmap). |
| `cmd/kapsis-ctl/podman/client.go` | libpod REST API client — socket discovery, validation, Inspect/List/Alive/Stop/Logs/Archive |
| `Makefile` | Top-level build targets for `kapsis-ctl` (`build-ctl`, `test-ctl`, `vet-ctl`) |
| `scripts/launch-agent.sh` | Main entry point — orchestrates config, image, worktree, container |
| `scripts/entrypoint.sh` | Container startup — SDKMAN, NVM, Maven settings, credential injection |
| `scripts/worktree-manager.sh` | Git worktree isolation — creates sanitized git views for containers |
| `scripts/post-container-git.sh` | Post-exit git operations — auto-commit, push, branch creation |
| `scripts/audit-report.sh` | Audit report generation from recorded events |
| `scripts/lib/logging.sh` | Shared logging with rotation (used by all scripts) |
| `scripts/lib/status.sh` | JSON status reporting for external monitoring |
| `scripts/lib/constants.sh` | Central constants — mount paths, network modes, git patterns |
| `scripts/lib/security.sh` | Security hardening — capabilities, seccomp, security profiles |
| `scripts/lib/compat.sh` | Cross-platform helpers — macOS/Linux compatibility |
| `scripts/lib/config-verifier.sh` | Config validation — YAML schema checking |
| `scripts/lib/validate-scope.sh` | Filesystem scope enforcement — blocks out-of-bounds writes |
| `scripts/lib/sanitize-files.sh` | File sanitization — homoglyph detection, binary filtering |
| `scripts/lib/audit.sh` | Audit trail — records container and agent events |
| `scripts/lib/audit-patterns.sh` | Audit pattern detection — identifies suspicious activity |
| `scripts/lib/atomic-copy.sh` | Atomic file copy — safe copy with rollback |
| `scripts/lib/liveness-monitor.sh` | Container liveness — heartbeat monitoring and recovery |
| `scripts/lib/podman-health.sh` | Podman VM health probe & auto-heal (macOS pre-launch mount check) |
| `scripts/lib/status-sync.sh` | Mirrors per-agent named volumes to `~/.kapsis/status/` (macOS) |
| `scripts/lib/inject-lsp-config.sh` | LSP config injection — editor integration inside containers |
| `scripts/lib/inject-plugin-hooks.sh` | Plugin hook injection — merges Claude Code plugin hooks into settings.json |
| `scripts/lib/rewrite-plugin-paths.sh` | Plugin path rewriting — adjusts paths for container mounts |
| `scripts/lib/ssh-config-compat.sh` | SSH config portability — normalizes SSH config across environments |
| `scripts/backends/podman.sh` | Podman backend — local container execution |
| `scripts/backends/k8s.sh` | K8s backend — AgentRequest CRD lifecycle |
| `scripts/lib/k8s-config.sh` | Config translator — Docker-style to K8s format |
| `Containerfile` | Multi-stage build with configurable languages/tools |
| `configs/agents/*.yaml` | Agent install instructions, auth, config mounts |
| `configs/build-profiles/*.yaml` | Container presets (minimal ~500MB to full-stack ~2.1GB) |
| `tests/lib/test-framework.sh` | Shared test utilities, assertions, container helpers |
| `tests/run-all-tests.sh` | Test runner with category filtering and quiet mode |

## Config Resolution Order

When `--config` is not specified, `scripts/launch-agent.sh` resolves configuration in this order (first existing file wins):

1. `./agent-sandbox.yaml` (current directory)
2. `./.kapsis/config.yaml` (current directory)
3. `<project>/agent-sandbox.yaml` (inside the target project)
4. `<project>/.kapsis/config.yaml` (inside the target project)
5. `~/.config/kapsis/default.yaml` (user home)
6. Built-in defaults

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
| `k8s` | No | Backend abstraction, K8s config translation |

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

## Build Profiles

| Profile | Description |
|---------|-------------|
| `minimal` | Smallest image, basic tools only |
| `java-dev` | Java development with Maven/Gradle |
| `java8-legacy` | Java 8 compatibility environment |
| `frontend` | Node.js, npm, frontend tooling |
| `backend-go` | Go development environment |
| `backend-rust` | Rust development with Cargo |
| `ml-python` | Python ML/AI libraries |
| `full-stack` | Everything combined (~2.1GB) |

## Dashboard Sync Rule

**Whenever a user-facing feature is added, changed, or removed in Kapsis, the dashboard (`dashboard/`) must be updated in the same PR to reflect it.**

A "user-facing feature" includes:
- New CLI flags or commands (e.g., `launch-agent.sh`, `kapsis-cleanup.sh`)
- New status fields in `scripts/lib/status.sh` (the dashboard's primary data source)
- New audit event types in `scripts/lib/audit.sh`
- New error types or exit codes
- New configuration options surfaced in `agent-sandbox.yaml`
- New container resources (volumes, mounts, named directories) that affect disk usage

The PR should either:
1. Extend `dashboard/server/` to read/expose the new data, and `dashboard/ui/` to render it, or
2. Open a follow-up GitHub issue tagged `dashboard-sync` if the surface change is large enough to warrant a separate PR.

The TypeScript mirror of the status schema — the `AgentStatus` interface — actually lives in `dashboard/shared/src/index.ts`; `dashboard/server/src/types.ts` only re-exports it (`export * from "@kapsis/dashboard-shared"`). Edit the `shared` package, not `server/src/types.ts` directly. Keep it in lockstep with `scripts/lib/status.sh`. CI enforces this via `.github/workflows/dashboard-sync.yml`.

## Release Artifact Rule

**Whenever a new user-facing binary, CLI script, or release artifact is added, ALL FOUR distribution surfaces must be updated in the same PR.** Missing one means users on that platform silently lose the feature.

The four surfaces:

1. **`.github/workflows/release.yml`** — if the artifact needs to be built or downloaded for the GitHub Release, add a build job (gated by `validate`) and append the file to the `files:` list of the `softprops/action-gh-release` step. Include it in `checksums.sha256`. Add a section to the release notes block describing how to download/use it.
2. **`packaging/homebrew/kapsis.rb`** — add either (a) a `bin/<name>` wrapper to the wrapper-script hash in `install` (for shell scripts shipped in the source tarball), or (b) an `on_macos`/`on_linux` + `on_arm`/`on_intel` `resource` block (for per-platform binaries downloaded from release assets). Add an `assert_predicate` to the `test` block that runs `<name> --version` (or another no-side-effect smoke check) — this is what catches the regression upfront.
3. **`packaging/rpm/kapsis.spec`** — add an `install -m 755 …` line under "Install executable scripts" (for shell scripts) or copy the binary from the staged location, add the corresponding `cat > %{buildroot}%{_bindir}/<name> << 'EOF' … EOF` wrapper, and list `%{_bindir}/<name>` in the `%files` section.
4. **`packaging/debian/debian/rules`** — add the matching `install -m 755 …` line under "Install main executable scripts" plus the `echo '#!/bin/bash' > … kapsis/usr/bin/<name>` wrapper block. For per-platform binaries staged from CI, also update `debian/install` if needed.

Also update any CI workflow that builds the artifact (e.g., `.github/workflows/dashboard-build.yml`-style helper jobs) AND `.github/workflows/release.yml`'s `update-packages` job if the formula/spec contains version-locked URLs or sha256s that need to be patched after the release is cut (look for `RELEASE_VERSION_MARKER_START` / `DASHBOARD_*_MARKER_START` markers as the pattern to follow).

Marker naming convention: `<ARTIFACT>_<TARGET>_MARKER_START` / `_END`, where the prefix is **artifact-specific** (not universal) and the target transformation is lowercase-hyphenated → uppercase-underscored via `tr '[:lower:]-' '[:upper:]_'`. Examples: for the `kapsis-dashboard` artifact, `darwin-arm64` becomes `DASHBOARD_DARWIN_ARM64_MARKER_START` / `_END`. For a hypothetical future `my-new-tool` artifact, the same target would become `MY_NEW_TOOL_DARWIN_ARM64_MARKER_START` / `_END`. Only the target portion is mechanically transformed; the prefix is yours to choose per artifact.

For shell scripts, prefer adding them to `scripts/` so the existing `cp -r scripts ...` step in release.yml automatically picks them up for the source tarball — no release.yml change needed beyond the wrapper plumbing.

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
10. **Organization-specific data in shared/tracked files** — see "Personal/Organization Configuration Separation" below

## Personal/Organization Configuration Separation

Kapsis is a general-purpose, publicly-shared tool. Any file that is tracked by git (i.e. not covered by `.gitignore`) must stay organization-agnostic: no real internal hostnames, employer names, personal usernames/emails, or product/team codenames. This applies to config defaults, code comments, doc examples, and test fixtures alike — a comment naming an employer is just as much a leak as a hardcoded internal domain in a config file.

**Where personal/organization config belongs instead:**
- `configs/*-personal.yaml` and `configs/aviad-*.yaml` are gitignored (see `.gitignore`) — put real internal hostnames, tokens-adjacent identifiers, and org-specific tuning there, and reference them via `--config` or your own `agent-sandbox.yaml` (also gitignored).
- If a mechanism is currently hardcoded to one specific vendor/tool/organization's needs (e.g. a single company's Maven extension, a single Bitbucket Server domain), prefer making it configurable/pluggable (env var, YAML list, etc.) with a generic default, rather than hardcoding the specific case into shared code. See `build_tools.maven_extensions` in `configs/build-config.yaml` for the pattern, and `KAPSIS_BITBUCKET_SERVER_HOSTS` in `scripts/lib/git-remote-utils.sh` for a small env-var-based example.

**In docs and test fixtures, use these placeholders instead of anything real:**
- Hostnames: `git.example.com`, `artifactory.example.com`, `ci.example.com`
- Usernames/accounts: `jon.d` (not `${USER}` — not reliably evaluated in every config context this repo has; not a real teammate's name either)
- Service/product names: generic terms (`bitbucket-token`, `bitbucket-ci-bot`) rather than a real internal service or product codename

Before committing a change to a shared/tracked file, grep the diff for your own username, employer name, and known internal domains — the same way you'd check for accidentally-committed secrets.

## Commit Artifact Filtering (Issue #391)

Before the post-container commit, Kapsis unstages its own infrastructure artifacts so they never land on the user's branch:

1. **Commit excludes** — `.claude/settings.json` (mutated by LSP/plugin injection) is in `KAPSIS_DEFAULT_COMMIT_EXCLUDE`. `KAPSIS_COMMIT_EXCLUDE` replaces the list wholesale; `KAPSIS_EXTRA_COMMIT_EXCLUDE` appends without redeclaring defaults.
2. **Ephemeral patterns** (non-overridable) — `**/*.bak` and `**/.mvn/*.bak*` cover Maven plugin backups (e.g. `.mvn/extensions.xml.bak2`) without over-matching names like `README.bakery.md`.

## Push Fallback (Agent Recovery)

When push fails (common in containers without credentials), Kapsis outputs a structured fallback:

```
KAPSIS_PUSH_FALLBACK: cd /path/to/worktree && git push -u origin branch-name
```

**For orchestrating agents:** Grep output for `KAPSIS_PUSH_FALLBACK:` and execute the command from the host where git credentials are available.

**In status.json:** The `push_fallback_command` field contains the same command when `push_status` is `"failed"`.

## Exit Codes

| Code | Meaning | Detection |
|------|---------|-----------|
| 0 | Success (changes committed or no changes) | Normal exit |
| 1 | Agent failure | Container exit non-zero |
| 2 | Push failed | Post-container push failure |
| 3 | Uncommitted changes remain | Commit status check |
| 4 | Mount failure (virtio-fs drop, Issues #248, #276) | `KAPSIS_MOUNT_FAILURE:` sentinel in stderr, or host pre-launch probe refusal |
| 5 | Agent completed but process hung (Issue #257) | Liveness monitor kills + status.json phase is "complete" |
| 6 | Commit failure (Issue #256) | Post-container `git commit` error, `commit_status: "failed"` |

## Mount Failure Detection (Issues #248, #276, #303)

Exit code 4 surfaces virtio-fs mount drops (macOS Virtualization.framework bug) across the full agent lifecycle — pre-launch host probe, container-startup probe, mid-run liveness probe, and a host-side vfkit watchdog (needed because the in-container probe can get stuck in an uninterruptible D-state when FUSE dies). Named-volume status storage and `caffeinate` sleep-prevention reduce how often this triggers on macOS.

Breadcrumb — implementation and exact current thresholds live in, not repeated here:
`scripts/lib/podman-health.sh`, `scripts/entrypoint.sh` (`probe_mount_readiness()`), `scripts/lib/liveness-monitor.sh`, `scripts/lib/vfkit-watchdog.sh`, `scripts/lib/status-sync.sh`, `scripts/launch-agent.sh` (exit-code override logic). Config: `prevent_sleep`, `KAPSIS_VFKIT_WATCHDOG_ENABLED`, `KAPSIS_VFKIT_WATCHDOG_INTERVAL`.

Recovery when auto-heal is refused or fails: `podman machine stop && podman machine start`, then re-run.

## Hung Agent Detection (Issue #257)

Liveness monitoring is **enabled by default**. It kills agents that stop making progress, judged by `updated_at` staleness, descendant-process I/O activity, and TCP connection quality (active vs. idle, with different grace periods for each). Exit code 5 means the agent finished its work but the process itself hung afterward.

Breadcrumb — exact current defaults/thresholds live in `scripts/lib/liveness-monitor.sh`'s header comment, not repeated here. Configurable per-agent under `liveness:` in `agent-sandbox.yaml` (`enabled`, `timeout`, `completion_timeout`, `grace_period`, `check_interval`, `api_soft_skip`, `api_hard_skip`).

## Agent Partial Completion (Issue #260)

When a container exits non-zero but the agent's work was successfully committed, `error_type` is set to `"agent_partial"` instead of `"agent_failure"`. This tells callers (slack-bot) NOT to retry — the work exists on the branch. Exit code remains 1.

| Scenario | exit_code | error_type |
|----------|-----------|-----------|
| Container crashed, no work | 1 | `agent_failure` |
| Container crashed, work committed | 1 | `agent_partial` |

## Commit Failure Detection (Issue #256)

Exit code 6 means the agent produced file changes but the post-container `git commit` itself failed (pre-commit hook failure, permission issue, empty diff after filtering). The worktree is preserved with staged changes rather than discarded. `status.json` reports `error_type: "commit_failure"`. Set `KAPSIS_COMMIT_NO_VERIFY=true` to skip pre-commit hooks in the post-container context if that's the cause.

Recovery:
```bash
cd <worktree-path>
git status           # See what was staged
git diff --cached    # Review staged changes
git commit -m "fix: manual recovery commit"
```

## Cross-Platform Notes

- macOS container overlay tests may fail due to virtio-fs limitations — run full test coverage on Linux
- Use `compat.sh` helpers for OS-specific commands (`sed -i`, `stat`, `date`, `md5`, `xargs`)
- The `is_macos` and `is_linux` functions are available for conditional logic
