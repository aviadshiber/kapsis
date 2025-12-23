# Kapsis Validation Tests

This directory contains tests to validate the isolation guarantees and functionality of Kapsis.

## Quick Start

```bash
# Run quick tests (no container required)
./run-all-tests.sh --quick

# Run all tests (requires Podman)
./run-all-tests.sh

# Run specific category
./run-all-tests.sh --category agent

# Run specific test
./test-agent-shortcut.sh
```

## Test Categories

### Quick Tests (No Container Required)

| Category | Script | Tests | Status |
|----------|--------|-------|--------|
| **Agent Selection** | | | |
| | test-agent-shortcut.sh | 6 | PASS |
| | test-agent-unknown.sh | 5 | PASS |
| | test-agent-config-override.sh | 5 | PASS |
| | test-config-resolution.sh | 6 | PASS |
| **Validation** | | | |
| | test-input-validation.sh | 11 | PASS |
| | test-path-spaces.sh | 5 | PASS |
| | test-dry-run-completeness.sh | 12 | PASS |

### Container Tests (Require Podman)

| Category | Script | Tests | Status |
|----------|--------|-------|--------|
| **Filesystem Isolation** | | | |
| | test-cow-isolation.sh | 8 | Ready |
| | test-host-unchanged.sh | 9 | Ready |
| **Maven Isolation** | | | |
| | test-maven-snapshot-block.sh | 6 | Ready |
| | test-maven-auth.sh | 10 | Ready |
| **Security** | | | |
| | test-security-no-root.sh | 11 | Ready |
| | test-agent-id-unique.sh | 6 | Ready |
| | test-env-api-keys.sh | 33 | Ready |
| | test-container-libs.sh | 12 | Ready |
| **Git Workflow** | | | |
| | test-git-new-branch.sh | 7 | Ready |
| | test-git-auto-commit-push.sh | 9 | Ready |
| **Cleanup** | | | |
| | test-cleanup-sandbox.sh | 9 | Ready |
| **Integration** | | | |
| | test-parallel-agents.sh | 6 | Ready |
| | test-full-workflow.sh | 10 | Ready |

## Test Counts

| Priority | Tests | Status |
|----------|-------|--------|
| P0 (Critical) | 40 | Ready |
| P1 (Important) | 60 | Ready |
| P2 (Robustness) | 37 | Ready |
| P3 (Integration) | 16 | Ready |
| **Total** | **153** | **Ready** |

## Prerequisites

- **Quick tests**: None (run without containers)
- **Container tests**:
  - Podman machine running (`podman machine start`)
  - Kapsis image built (`./scripts/build-image.sh`)

## Platform Notes

### macOS Limitation
Container tests that require read-write overlay mounts will fail on macOS due to a virtio-fs limitation. When Podman on macOS uses the `:O` (overlay) mount option, the overlay is created as **read-only** because virtio-fs doesn't support the full overlay semantics.

**Affected tests** (require Linux for full testing):
- test-cow-isolation.sh
- test-host-unchanged.sh
- test-maven-snapshot-block.sh
- test-agent-id-unique.sh
- test-git-new-branch.sh
- test-git-auto-commit-push.sh
- test-full-workflow.sh

**Tests that work on macOS**:
- All quick tests (7 scripts, 50 tests)
- test-security-no-root.sh
- test-env-api-keys.sh
- test-cleanup-sandbox.sh
- test-parallel-agents.sh

For full test coverage, run container tests on Linux or in a Linux VM.

## Running Container Tests

```bash
# Start Podman machine
podman machine start

# Build the Kapsis image (first time only)
./scripts/build-image.sh

# Run all tests
./run-all-tests.sh

# Run specific container test category
./run-all-tests.sh --category filesystem
./run-all-tests.sh --category security
./run-all-tests.sh --category integration
```

## Test Framework

The test framework (`lib/test-framework.sh`) provides:

### Assertions
- `assert_equals <expected> <actual> <message>`
- `assert_not_equals <unexpected> <actual> <message>`
- `assert_contains <haystack> <needle> <message>`
- `assert_not_contains <haystack> <needle> <message>`
- `assert_file_exists <path> <message>`
- `assert_file_not_exists <path> <message>`
- `assert_dir_exists <path> <message>`
- `assert_exit_code <expected> <actual> <message>`
- `assert_command_succeeds <command> <message>`
- `assert_command_fails <command> <message>`

### Container Helpers
- `setup_container_test <name>` - Set up container test environment
- `cleanup_container_test` - Clean up container resources
- `run_in_container <command>` - Run command in test container
- `run_in_container_detached <command>` - Run container in background
- `wait_for_container <name> <timeout>` - Wait for container to finish
- `assert_file_in_upper <path> <message>` - Check file in overlay upper dir
- `assert_host_file_unchanged <path> <content> <message>` - Verify host unchanged
- `skip_if_no_container` - Skip if prerequisites not met

### Setup/Teardown
- `setup_test_project` - Create test Maven project with git
- `cleanup_test_project` - Remove test project
- `cleanup_sandboxes` - Remove test sandbox directories

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Test setup failed |
| 3 | Prerequisites not met |

## Writing New Tests

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/test-framework.sh"

test_example() {
    log_test "Testing example functionality"

    local output
    output=$(some_command 2>&1) || true

    assert_contains "$output" "expected" "Should contain expected output"
}

main() {
    setup_test_project

    run_test test_example

    cleanup_test_project
    print_summary
}

main "$@"
```

## Coverage

### P0 - Critical (Hermetic Guarantees)
- [x] Copy-on-Write filesystem isolation
- [x] Host filesystem unchanged after container operations
- [x] Maven SNAPSHOT blocking
- [x] Agent ID uniqueness (no concurrent conflicts)

### P1 - Important (Core Features)
- [x] Git branch workflow
- [x] Auto-commit on exit
- [x] Security (non-root execution)
- [x] Environment variable passthrough

### P2 - Robustness
- [x] Input validation
- [x] Path handling (spaces, special chars)
- [x] Dry-run completeness
- [x] Cleanup operations

### P3 - Integration
- [x] Parallel agent execution
- [x] Full end-to-end workflow
