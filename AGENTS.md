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

## Branch Workflow (IMPORTANT)

**NEVER work directly on `main` branch.** All development must happen on feature branches.

### When to Use Each Approach

| Scenario | Approach | Isolation Level |
|----------|----------|-----------------|
| Feature development with full isolation | Kapsis container | Full (filesystem + process) |
| Quick fixes, docs, or Kapsis development itself | Git worktree | Branch isolation only |

### Creating a Feature Branch (Non-Kapsis)

When not using Kapsis (e.g., working on Kapsis itself), always create a worktree:

```bash
# Create worktree with feature branch
git worktree add -b feature/my-feature ~/.kapsis/worktrees/kapsis-feature main

# Work in the worktree
cd ~/.kapsis/worktrees/kapsis-feature

# When done, clean up
git worktree remove ~/.kapsis/worktrees/kapsis-feature
```

### Why This Matters
- Protects `main` from accidental commits or broken states
- Enables parallel work on multiple features
- Keeps your primary checkout clean for reviews and quick switches
- Matches the isolation model Kapsis provides for other projects

## Coding Style & Naming Conventions
- Bash scripts should use `set -euo pipefail` and `[[ ... ]]` for conditionals.
- Indent with 4 spaces and always quote variables (`"$var"`).
- Use `shellcheck` for linting and prefer the shared logger in `scripts/lib/logging.sh`.
- Test files live in `tests/` and follow `test-<feature>.sh` naming.
- **Cross-platform compatibility**: All commands must work on both macOS and Linux. Use `scripts/lib/compat.sh` for OS-specific operations (e.g., `sed -i`, `date`, `stat`). Avoid GNU-only flags.
- **Arithmetic with `set -e`**: Bash arithmetic `(( ))` returns exit code 1 when the result is 0, which causes script exit under `set -e`. For counters and accumulators, use `((count++)) || true` or `((total += n)) || true`. Only omit `|| true` for arithmetic that should fail the script when the result is zero.

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

**References:**
- `tests/README.md` - Test categories, prerequisites, and platform caveats
- `tests/lib/test-framework.sh` - Shared test utilities (`assert_equals`, `assert_true`, `run_test`, etc.)

**Quick start:**
- Quick tests do not require containers; container tests require Podman (`podman machine start`).
- Run a single test with `./tests/test-input-validation.sh`.
- Use quiet mode with `KAPSIS_TEST_QUIET=1` or `./tests/run-all-tests.sh -q`.
- Some container overlay tests may not be reliable on macOS; run full coverage on Linux if needed.

### Test Plan Requirement
Every PR that adds or modifies functionality **must include a test plan**:

1. **New features** → Add tests covering the expected behavior
2. **Bug fixes** → Add regression tests that fail without the fix
3. **Refactoring** → Ensure existing tests still pass; add tests if coverage gaps exist

### Writing Effective Tests
- **Test behavior, not implementation** - Tests should verify what the code does, not how it does it
- **Use descriptive test names** - `test_agent_id_invalid_path_traversal_skips` is better than `test_validation`
- **Cover edge cases** - Empty input, invalid input, boundary conditions
- **Test error paths** - Verify graceful handling of failures (exit codes, error messages)

Example test structure:
```bash
test_feature_behavior_description() {
    # Setup
    local input="test_value"

    # Execute
    local result exit_code
    result=$(some_function "$input")
    exit_code=$?

    # Assert
    assert_equals "$exit_code" "0" "Exits successfully"
    assert_equals "$result" "expected" "Returns expected value"
}
```

## CI Integration Checklist

When adding new functionality, verify CI integration is complete:

### Adding New Tests
1. **Register in `run-all-tests.sh`** - Add to the appropriate category in `get_tests_for_category()`:
   - `agent` - Agent config, profiles, auth requirements
   - `validation` - Input validation, preflight checks
   - `status` - Status reporting and hooks
   - `filesystem` - COW isolation, host unchanged
   - `maven` - Maven/Gradle build isolation
   - `security` - Security tests (root, keys, keychain)
   - `git` - Git operations, worktrees, push verification
   - `cleanup` - Sandbox cleanup
   - `integration` - Full workflow tests

2. **Add to QUICK_TESTS** if the test doesn't require containers (most unit tests)

3. **Verify test runs**:
   ```bash
   ./tests/run-all-tests.sh --category <category>  # Category tests
   ./tests/run-all-tests.sh --quick                # Quick tests
   ```

### Adding New Scripts
1. **Check if Containerfile needs updates** - Scripts that run inside containers need to be copied
2. **Verify script is accessible** - Scripts in `scripts/lib/` are sourced, not executed directly
3. **Run shellcheck** on new scripts

### Pre-Merge Verification
```bash
# Run full test suite
./tests/run-all-tests.sh

# Or at minimum, quick tests + relevant category
./tests/run-all-tests.sh --quick
./tests/run-all-tests.sh --category <affected-category>
```

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

### CRITICAL: Never Use `bash -x` for Debugging

**Do NOT use `bash -x` or `set -x` when debugging Kapsis scripts.** Bash debug mode prints all command arguments to stderr BEFORE any sanitization functions process them, which will expose:
- API keys and OAuth tokens (ANTHROPIC_API_KEY, etc.)
- Refresh tokens and session credentials
- Passwords and secrets from keychain

**Safe debugging alternatives:**
1. Use `KAPSIS_DEBUG=1` which logs to file with sanitization
2. Add targeted `echo` statements for specific variables
3. Check log files at `~/.kapsis/logs/`
4. Ask the user before enabling any form of trace output
