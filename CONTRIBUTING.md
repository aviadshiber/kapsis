# Contributing to Kapsis

This guide covers the logging system and test framework for developers contributing to Kapsis.

## Table of Contents

- [Logging](#logging)
  - [Log Levels](#log-levels)
  - [Using the Logging Library](#using-the-logging-library)
  - [Log Configuration](#log-configuration)
- [Testing](#testing)
  - [Running Tests](#running-tests)
  - [Writing Tests](#writing-tests)
  - [Test Framework API](#test-framework-api)
  - [Test Categories](#test-categories)
- [Code Style](#code-style)
- [Submitting Changes](#submitting-changes)
- [Release Process](#release-process)
  - [Automatic Version Bumping](#automatic-version-bumping)
  - [Commit Message Format](#commit-message-format)
  - [Release Workflow](#release-workflow)
  - [Manual Releases](#manual-releases)

---

## Logging

Kapsis uses a centralized logging library (`scripts/lib/logging.sh`) that provides consistent, colorized output with file logging and rotation.

### Log Levels

| Level | Function | Purpose |
|-------|----------|---------|
| DEBUG | `log_debug` | Verbose diagnostic information |
| INFO | `log_info` | Normal operational messages |
| WARN | `log_warn` | Warning conditions |
| ERROR | `log_error` | Error conditions |

### Using the Logging Library

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/logging.sh"

# Initialize with script name (used in log entries)
init_logging "my-script"

# Log messages at different levels
log_debug "Variable value: $VAR"
log_info "Starting operation..."
log_warn "Config file not found, using defaults"
log_error "Failed to connect to service"

# Success messages (always shown in green)
log_success "Operation completed"
```

### Log Configuration

For log environment variables, file locations, and rotation settings, see [docs/CONFIG-REFERENCE.md](docs/CONFIG-REFERENCE.md#logging-configuration).

Quick reference:
```bash
# Enable debug logging
KAPSIS_DEBUG=1 ./scripts/launch-agent.sh 1 ~/project --task "test"

# View logs
tail -f ~/.kapsis/logs/kapsis-launch-agent.log
```

---

## Testing

Kapsis includes a comprehensive test suite in `tests/`. All tests use the shared framework in `tests/lib/test-framework.sh`.

### Running Tests

#### All Tests

```bash
# Run all tests (verbose output)
./tests/run-all-tests.sh

# Run all tests (quiet mode - shows only PASS/FAIL)
./tests/run-all-tests.sh -q

# Quick tests only (no containers, ~10 seconds)
./tests/run-all-tests.sh --quick

# Container tests only (requires Podman)
./tests/run-all-tests.sh --container

# Run specific test categories (comma-separated)
./tests/run-all-tests.sh --category agent,config,dry-run
```

#### Individual Tests

```bash
# Run a single test script
./tests/test-input-validation.sh

# Run in quiet mode
KAPSIS_TEST_QUIET=1 ./tests/test-input-validation.sh
```

### Quiet Mode

Quiet mode (`-q`) reduces test output for CI/CD pipelines:

| Output | Verbose Mode | Quiet Mode |
|--------|--------------|------------|
| Test headers | ✓ | ✗ |
| `[TEST]` log messages | ✓ | ✗ |
| `[PASS]` per test | ✓ | ✓ |
| `[FAIL]` with reason | ✓ | ✓ |
| Expected/Actual details | ✓ | ✗ |
| Test summary | ✓ | ✓ |

**Key feature**: Even in quiet mode, failure messages show *WHY* a test failed:

```bash
$ KAPSIS_TEST_QUIET=1 ./tests/test-input-validation.sh
[PASS] test_missing_agent_id
[FAIL] Should show error message    # <-- WHY it failed
[FAIL] test_nonexistent_project     # <-- WHAT failed
[PASS] test_help_flag
```

### Writing Tests

#### Test File Structure

```bash
#!/usr/bin/env bash
#===============================================================================
# Test: My Feature
#
# Description of what this test validates.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

#===============================================================================
# TEST CASES
#===============================================================================

test_example_passes() {
    log_test "Testing that example works"

    local result="expected"
    assert_equals "expected" "$result" "Result should match expected"
}

test_example_contains() {
    log_test "Testing string contains substring"

    local output="Hello World"
    assert_contains "$output" "World" "Should contain World"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "My Feature"

    run_test test_example_passes
    run_test test_example_contains

    print_summary
}

main "$@"
```

#### Test File Naming

- Test files must be in `tests/` directory
- Name pattern: `test-<feature>.sh`
- Examples: `test-input-validation.sh`, `test-cow-isolation.sh`

### Test Framework API

#### Output Functions

| Function | Quiet Mode | Description |
|----------|------------|-------------|
| `print_test_header "Title"` | Suppressed | Print decorated test script header |
| `log_test "message"` | Suppressed | Log test step (blue) |
| `log_pass "message"` | Shown | Log success (green) |
| `log_fail "message"` | Shown | Log failure (red) |
| `log_skip "message"` | Suppressed | Log skipped test (yellow) |
| `log_info "message"` | Suppressed | Log informational message (cyan) |

#### Assertions

All assertions return 0 on success, 1 on failure.

```bash
# Equality
assert_equals "expected" "$actual" "Values should be equal"
assert_not_equals "unexpected" "$actual" "Values should differ"

# String matching
assert_contains "$haystack" "needle" "Should contain substring"
assert_not_contains "$haystack" "needle" "Should not contain substring"

# Regular expressions
assert_matches "$string" "^pattern.*$" "Should match regex"

# File system
assert_file_exists "/path/to/file" "File should exist"
assert_file_not_exists "/path/to/file" "File should not exist"
assert_dir_exists "/path/to/dir" "Directory should exist"

# Numeric comparisons
assert_greater_than "$actual" "$threshold" "Should be greater"
assert_less_than "$actual" "$threshold" "Should be less"
```

#### Test Execution

```bash
# Run a test function (handles pass/fail counting)
run_test test_function_name

# Skip tests conditionally
skip_if_no_container  # Skip if Podman not available
skip_if_no_overlay_rw # Skip if overlay support missing

# Print final summary (call at end of main)
print_summary
```

#### Test Setup/Teardown

```bash
# Create a temporary test project
setup_test_project   # Creates $TEST_PROJECT (~/.kapsis-test-project)
cleanup_test_project # Removes $TEST_PROJECT

# Container tests
run_podman_isolated "$agent_id" "command" [-e VAR=value]
cleanup_isolated_container "$agent_id"

# Worktree tests
setup_worktree_test "test-name"
cleanup_worktree_test
```

### Test Categories

Tests are categorized for selective execution:

| Category | Description | Container Required |
|----------|-------------|-------------------|
| `agent` | Agent selection/configuration | No |
| `config` | Configuration resolution | No |
| `input` | Input validation | No |
| `dry-run` | Dry-run output verification | No |
| `path` | Path handling (spaces, special chars) | No |
| `cow` | Copy-on-Write filesystem isolation | Yes |
| `security` | Security constraints (rootless, etc.) | Yes |
| `workflow` | Full workflow integration | Yes |
| `git` | Git operations | Yes |

#### Quick vs Container Tests

- **Quick tests** (`--quick`): Run without containers, complete in ~10 seconds
- **Container tests** (`--container`): Require Podman, test isolation guarantees

```bash
# CI pipeline: run quick tests first
./tests/run-all-tests.sh --quick -q

# If quick tests pass, run container tests
./tests/run-all-tests.sh --container -q
```

### Adding New Tests

1. Create test file: `tests/test-my-feature.sh`
2. Add test category tag in file header comment
3. Add to appropriate section in `tests/run-all-tests.sh` if needed
4. Run and verify:
   ```bash
   ./tests/test-my-feature.sh         # Verbose
   KAPSIS_TEST_QUIET=1 ./tests/test-my-feature.sh  # Quiet
   ```

### Best Practices

1. **Use descriptive test names**: `test_config_overrides_agent` not `test_config_1`
2. **One assertion per behavior**: Each test should verify one specific thing
3. **Use `log_test`**: Describe what's being tested for debugging
4. **Clean up resources**: Always call cleanup functions, even on failure
5. **Handle failures gracefully**: Use `|| true` for commands expected to fail
6. **Check prerequisites**: Use `skip_if_*` functions for optional tests

---

## Code Style

- Bash scripts use `set -euo pipefail`
- Use `shellcheck` for linting
- Indent with 4 spaces
- Quote variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals, not `[ ]`

## Submitting Changes

1. Create a feature branch
2. Make changes
3. Run tests: `./tests/run-all-tests.sh -q`
4. Submit PR with description of changes

---

## Release Process

Kapsis uses automated releases triggered on every successful merge to `main`. The release system uses [Conventional Commits](https://www.conventionalcommits.org/) to automatically determine version bumps.

### Automatic Version Bumping

When a PR is merged to `main`, the auto-release workflow analyzes commit messages to determine the version bump:

| Commit Type | Version Bump | Example |
|-------------|--------------|---------|
| `feat:` or `feat(scope):` | **Minor** (1.0.0 → 1.1.0) | `feat: add user authentication` |
| `fix:` or `fix(scope):` | **Patch** (1.0.0 → 1.0.1) | `fix: resolve login timeout` |
| `BREAKING CHANGE:` or `type!:` | **Major** (1.0.0 → 2.0.0) | `feat!: redesign API` |
| Other (`docs:`, `chore:`, `refactor:`, etc.) | **Patch** | `docs: update README` |

### Commit Message Format

```
<type>(<optional scope>): <description>

[optional body]

[optional footer with BREAKING CHANGE: description]
```

**Examples:**

```bash
# Patch release (bug fix)
git commit -m "fix(agent): handle missing config gracefully"

# Minor release (new feature)
git commit -m "feat(status): add real-time monitoring dashboard"

# Major release (breaking change)
git commit -m "feat(api)!: change config format to YAML

BREAKING CHANGE: Config files must now use YAML format instead of JSON."
```

### Common Commit Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Code style (formatting, semicolons, etc.) |
| `refactor` | Code refactoring (no feature/fix) |
| `perf` | Performance improvements |
| `test` | Adding/updating tests |
| `chore` | Maintenance tasks, dependencies |
| `ci` | CI/CD configuration |
| `build` | Build system or dependencies |

### Release Workflow

1. **Merge PR to main** → CI runs tests
2. **CI completes successfully** → Triggers Auto Release via `workflow_run`
3. **Analyzes commits** → Scans commits since last tag for conventional commit patterns
4. **Determines version** → Calculates new version based on commit types (feat → minor, fix → patch, breaking → major)
5. **Creates git tag** → Pushes `v{X.Y.Z}` tag
6. **Release workflow triggers** → Builds container, creates GitHub Release

> **Note:** Since `main` is a protected branch, the Auto Release workflow creates only the git tag. Git tags are the source of truth for versioning.

### Manual Releases

For special cases (hotfixes, pre-releases), you can trigger a release manually:

```bash
# Via GitHub UI:
# Actions → Auto Release → Run workflow → Select bump type

# Or via GitHub CLI:
gh workflow run auto-release.yml -f bump_type=patch
```

### Updating the Changelog

When adding changes to your PR, update the `[Unreleased]` section in `CHANGELOG.md`:

```markdown
## [Unreleased]

### Added
- Your new feature description

### Fixed
- Your bug fix description
```

> **Note:** Since `main` is protected, changelog entries remain in `[Unreleased]` until manually moved. Periodically, a maintainer should update the changelog to move entries to released version sections based on git tags.
