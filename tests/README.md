# Kapsis Validation Tests

This directory contains tests to validate the isolation guarantees of Kapsis.

## Test Categories

### 1. Filesystem Isolation Tests
- `test-cow-isolation.sh` - Verify Copy-on-Write overlay works correctly
- `test-upper-dir-isolation.sh` - Verify changes go to upper directory

### 2. Maven Isolation Tests
- `test-maven-snapshot-block.sh` - Verify SNAPSHOTs blocked from remote
- `test-maven-deploy-block.sh` - Verify deploy operations blocked
- `test-maven-repo-isolation.sh` - Verify per-agent .m2 isolation

### 3. Build Cache Tests
- `test-ge-cache-isolation.sh` - Verify GE remote cache disabled
- `test-parallel-build.sh` - Verify parallel builds don't interfere

### 4. Git Workflow Tests
- `test-new-branch.sh` - Verify new branch creation
- `test-continue-branch.sh` - Verify continuing from remote branch
- `test-auto-commit-push.sh` - Verify automatic commit and push

## Running Tests

```bash
# Run all tests
./run-all-tests.sh

# Run specific test
./test-cow-isolation.sh
```

## Prerequisites

- Podman machine running
- Kapsis image built (`./scripts/build-image.sh`)
- Test project available

## Test Status

| Test | Status |
|------|--------|
| CoW Isolation | TODO |
| Maven SNAPSHOT Block | TODO |
| Maven Deploy Block | TODO |
| GE Cache Isolation | TODO |
| Parallel Build | TODO |
| Git New Branch | TODO |
| Git Continue Branch | TODO |
