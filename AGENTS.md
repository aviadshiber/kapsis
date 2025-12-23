# Repository Guidelines

## Documentation First
- Before making changes, read the doc that matches the area you are touching.
- Start with `README.md` for context, then consult `CONTRIBUTING.md` for logging, tests, code style, and commit rules.
- Use `tests/README.md` for test categories, prerequisites, and platform caveats.
- Use `docs/` for configuration and deeper references (for example, logging or config details).
- If working on agent profiles or configs, review `configs/` and any related docs before editing.
- If a change is critical or user-facing, update the relevant docs in the same PR.

## Project Structure & Module Organization
- `scripts/` holds the core Bash entrypoints (agent launch, image build, cleanup); shared helpers live in `scripts/lib/`.
- `configs/` contains example config files and agent profiles; profile definitions are under `configs/agents/`.
- `tests/` is the shell-based test suite; the shared framework is `tests/lib/test-framework.sh`.
- `docs/` and `specs/` hold documentation and task specs used by agents.
- `assets/` stores static artifacts (e.g., logos); `maven/isolated-settings.xml` configures isolated Maven behavior in containers.

## Build, Test, and Development Commands
- `./scripts/build-image.sh` builds the base Podman image used by Kapsis.
- `./scripts/build-agent-image.sh <profile>` builds an agent-specific image (see `configs/agents/`).
- `./scripts/launch-agent.sh <id> <project_path> --task "..."` launches an agent in a sandboxed container.
- `./scripts/kapsis-status.sh` shows running agent status; add `--json` for machine output.
- `./tests/run-all-tests.sh` runs the full test suite (requires Podman).
- `./tests/run-all-tests.sh --quick` runs fast, non-container tests.

## Coding Style & Naming Conventions
- Bash scripts should use `set -euo pipefail` and `[[ ... ]]` for conditionals.
- Indent with 4 spaces and always quote variables (`"$var"`).
- Use `shellcheck` for linting and prefer the shared logger in `scripts/lib/logging.sh`.
- Test files live in `tests/` and follow `test-<feature>.sh` naming.

## Testing Guidelines
- Quick tests do not require containers; container tests require Podman (`podman machine start`).
- Run a single test with `./tests/test-input-validation.sh`.
- Use quiet mode with `KAPSIS_TEST_QUIET=1` or `./tests/run-all-tests.sh -q`.
- Some container overlay tests may not be reliable on macOS; run full coverage on Linux if needed.

## Commit & Pull Request Guidelines
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`; include optional scopes.
- Format: `<type>(<scope>): <description>`; use `BREAKING CHANGE:` for major changes.
- Create a feature branch, run `./tests/run-all-tests.sh -q`, and submit a PR with a clear description.
- Update `CHANGELOG.md` under `[Unreleased]` when adding user-facing changes.

## Security & Configuration Tips
- Copy `agent-sandbox.yaml.template` to `agent-sandbox.yaml` and keep secrets in keychain-backed fields.
- Avoid committing API keys or local paths; prefer `environment.passthrough` for non-secret values.
