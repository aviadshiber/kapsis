# Kapsis Validation Tests

This directory contains tests to validate the isolation guarantees and functionality of Kapsis.

## Test Categories

### 1. Agent Selection & Config Resolution Tests
- `test-agent-shortcut.sh` - Verify `--agent` flag resolves to correct config
- `test-agent-unknown.sh` - Verify error message on unknown agent
- `test-agent-config-override.sh` - Verify `--config` overrides `--agent`
- `test-agent-display.sh` - Verify agent name displayed in output
- `test-config-resolution.sh` - Verify config resolution order
- `test-config-not-found.sh` - Verify helpful error when no config found

### 2. Filesystem Isolation Tests
- `test-cow-isolation.sh` - Verify Copy-on-Write overlay works correctly
- `test-upper-dir-isolation.sh` - Verify changes go to upper directory
- `test-host-unchanged.sh` - Verify host project files remain unchanged

### 3. Maven Isolation Tests
- `test-maven-snapshot-block.sh` - Verify SNAPSHOTs blocked from remote
- `test-maven-deploy-block.sh` - Verify deploy operations blocked
- `test-maven-repo-isolation.sh` - Verify per-agent .m2 isolation

### 4. Build Cache Tests
- `test-ge-cache-isolation.sh` - Verify GE remote cache disabled
- `test-parallel-build.sh` - Verify parallel builds don't interfere

### 5. Git Workflow Tests
- `test-git-new-branch.sh` - Verify new branch creation
- `test-git-continue-branch.sh` - Verify continuing from remote branch
- `test-git-auto-commit-push.sh` - Verify automatic commit and push
- `test-git-no-push.sh` - Verify `--no-push` flag works
- `test-git-auto-branch.sh` - Verify `--auto-branch` generates names

### 6. Integration Tests
- `test-parallel-agents.sh` - Run multiple agents simultaneously
- `test-full-workflow.sh` - End-to-end test of complete workflow

## Running Tests

```bash
# Run all tests
./run-all-tests.sh

# Run specific test category
./run-all-tests.sh --category agent

# Run specific test
./test-agent-shortcut.sh

# Run with verbose output
./test-agent-shortcut.sh -v
```

## Prerequisites

- Podman machine running (`podman machine start`)
- Kapsis image built (`./scripts/build-image.sh`)
- `yq` installed for YAML parsing
- Test project available (or use `--create-test-project`)

## Test Environment

Tests use a temporary test project created in `/tmp/kapsis-test-project/`.
This project is created fresh for each test run to ensure isolation.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Test setup failed |
| 3 | Prerequisites not met |

## Test Status

| Category | Test | Status |
|----------|------|--------|
| **Agent Selection** | | |
| | --agent shortcut | TODO |
| | Unknown agent error | TODO |
| | --config override | TODO |
| | Agent name display | TODO |
| | Config resolution order | TODO |
| **Filesystem** | | |
| | CoW Isolation | TODO |
| | Upper dir isolation | TODO |
| | Host unchanged | TODO |
| **Maven** | | |
| | SNAPSHOT block | TODO |
| | Deploy block | TODO |
| | Repo isolation | TODO |
| **Build Cache** | | |
| | GE cache isolation | TODO |
| | Parallel build | TODO |
| **Git Workflow** | | |
| | New branch | TODO |
| | Continue branch | TODO |
| | Auto commit/push | TODO |
| | No-push mode | TODO |
| | Auto-branch | TODO |
| **Integration** | | |
| | Parallel agents | TODO |
| | Full workflow | TODO |

## Writing New Tests

Each test script should:

1. Source the test framework: `source "$(dirname "$0")/lib/test-framework.sh"`
2. Use assertion functions: `assert_equals`, `assert_contains`, `assert_file_exists`
3. Clean up after itself
4. Return appropriate exit code

Example:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/test-framework.sh"

test_agent_shortcut_claude() {
    local output
    output=$(../scripts/launch-agent.sh 1 /tmp/test-project --agent claude --dry-run 2>&1)

    assert_contains "$output" "CLAUDE" "Agent name should be displayed"
    assert_contains "$output" "configs/claude.yaml" "Config path should be shown"
}

run_test "test_agent_shortcut_claude"
```
