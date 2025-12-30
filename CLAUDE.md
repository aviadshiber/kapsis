# Claude Code Guidelines for Kapsis

Essential context for AI assistants working on the Kapsis codebase.

> **Quick reference:** See `AGENTS.md` for concise repository guidelines shared across all AI agents.

## Project Overview

Kapsis is a **hermetically isolated AI agent sandbox** for running multiple AI coding agents (Claude Code, Codex CLI, Aider) in parallel with complete isolation via Podman containers and Copy-on-Write filesystems.

## Documentation Map

| Topic | Reference |
|-------|-----------|
| Getting started | `README.md` |
| Architecture & data flows | `docs/ARCHITECTURE.md` |
| Configuration options | `docs/CONFIG-REFERENCE.md` |
| Git workflow | `docs/GIT-WORKFLOW.md` |
| Logging & testing | `CONTRIBUTING.md` |
| Cleanup operations | `docs/CLEANUP.md` |
| Agent profiles | `configs/agents/*.yaml` |

## Quick Commands

```bash
# Build & run
./scripts/build-image.sh                    # Build container image
./scripts/launch-agent.sh ~/project --agent claude --task "..."

# Test
./tests/run-all-tests.sh --quick            # Fast tests (~10s)
./tests/run-all-tests.sh                    # All tests (needs Podman)

# Debug
KAPSIS_DEBUG=1 ./scripts/launch-agent.sh ...
tail -f ~/.kapsis/logs/kapsis-launch-agent.log
```

## Code Style

- **Bash:** `set -euo pipefail`, `[[ ]]` conditionals, 4-space indent, quote variables
- **Linting:** All scripts must pass `shellcheck`
- **Logging:** Use `scripts/lib/logging.sh` - see `CONTRIBUTING.md` for details
- **Tests:** Files in `tests/test-*.sh`, use `tests/lib/test-framework.sh`

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:` / `ci:`
- Breaking changes: `feat!:` or `BREAKING CHANGE:` footer

See `CONTRIBUTING.md` for full release process.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/launch-agent.sh` | Main entry point |
| `scripts/entrypoint.sh` | Container startup |
| `scripts/lib/logging.sh` | Shared logging |
| `scripts/lib/status.sh` | Status reporting |
| `Containerfile` | Container image definition |

## Things to Avoid

1. Hardcoding paths - use `$KAPSIS_HOME`, `$SCRIPT_DIR`
2. Platform-specific commands - use `scripts/lib/compat.sh`
3. `[ ]` conditionals - always use `[[ ]]`
4. Skipping shellcheck
5. Committing secrets - use keychain integration

## Push Fallback (Agent Recovery)

When push fails (common in containers without credentials), Kapsis outputs a structured fallback:

```
KAPSIS_PUSH_FALLBACK: cd /path/to/worktree && git push -u origin branch-name
```

**For orchestrating agents:** Grep output for `KAPSIS_PUSH_FALLBACK:` and execute the command from the host where git credentials are available.

**In status.json:** The `push_fallback_command` field contains the same command when `push_status` is `"failed"`.

## Cross-Platform

macOS container overlay tests may fail due to virtio-fs limitations. Run full test coverage on Linux. Use `compat.sh` helpers for OS-specific commands.
