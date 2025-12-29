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

## Pre-Push Checklist
Before pushing changes, run these checks locally to avoid CI feedback delays:
```bash
# Required: Run shellcheck on all modified scripts
shellcheck scripts/**/*.sh tests/*.sh

# Required: Run quick tests
./tests/run-all-tests.sh --quick

# Optional: Validate YAML configs if configs/ was modified
./scripts/lib/config-verifier.sh --all --test
```

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

## Version Documentation Updates
When completing a PR that will trigger a release, update version references in documentation:

1. **Verify current date**: Always run `date -u` to get the correct UTC date before updating changelogs or documentation with dates. Do not assume the year.

2. **Determine the new version** based on conventional commit type:
   - `feat:` → minor bump (0.7.5 → 0.8.0)
   - `fix:` → patch bump (0.7.5 → 0.7.6)
   - `feat!:` or `BREAKING CHANGE:` → major bump (0.7.5 → 1.0.0)

3. **Check current version**: `git tag --sort=-v:refname | head -1`

4. **Update hardcoded versions** in these files if they exist:
   - `docs/INSTALL.md` - example version in install commands
   - `packaging/homebrew/kapsis.rb` - formula version (auto-updated by CI)
   - `packaging/rpm/kapsis.spec` - RPM version (auto-updated by CI)
   - `packaging/debian/debian/changelog` - Debian changelog (auto-updated by CI)
   - Any other docs with explicit version numbers

5. **Prefer dynamic fetching** where possible - the landing page and install docs already fetch versions dynamically from GitHub API.

6. **Package definitions are auto-updated** by CI on release - see `.github/workflows/release.yml` `update-packages` job.

## Security & Configuration Tips
- Copy `agent-sandbox.yaml.template` to `agent-sandbox.yaml` and keep secrets in keychain-backed fields.
- Avoid committing API keys or local paths; prefer `environment.passthrough` for non-secret values.
