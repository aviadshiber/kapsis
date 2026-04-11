# Test Coverage Analysis

Analysis of the Kapsis test suite coverage, identifying gaps and recommending improvements.

**Codebase snapshot:** 24 main scripts, 21 library modules, 14 hook scripts, ~550+ tests across 61 test files.

---

## 1. Completely Untested Modules

### 1.1 `scripts/lib/config-verifier.sh` — 0% coverage

This module validates YAML configuration files (tool-phase-mapping, agent profiles, launch configs, network configs). It exposes 8 public functions, none of which have tests:

- `validate_tool_phase_mapping(file)` — Validates tool-phase-mapping.yaml structure
- `validate_agent_profile(file)` — Validates agent profile YAML schema
- `validate_launch_config(file)` — Validates launch configuration YAML
- `validate_network_config(file)` — Validates network allowlist configuration
- `detect_config_type(file)` — Auto-detects config file type
- `test_pattern_matching(file)` — Tests tool-to-phase mapping logic
- `check_dependencies()` — Verifies yq/yamllint availability
- `print_summary()` — Reports validation results with error/warning counts

**Risk:** Config validation is a CI/CD gate. Silent regressions here would allow broken configs to ship.

**Recommended tests:**
- Valid config files pass each validator without errors
- Malformed YAML produces clear error messages
- Missing required fields are caught (e.g., agent profile without `command`)
- `detect_config_type()` correctly classifies all config types
- `test_pattern_matching()` maps tools to correct phases
- Invalid patterns produce warnings, not crashes

### 1.2 `scripts/lib/secret-store.sh` — 0% coverage

Cross-platform credential retrieval (macOS Keychain, Linux secret-tool). 3 public functions:

- `detect_os()` — Returns `"macos"` | `"linux"` | `"unknown"`
- `query_secret_store(service, account)` — Retrieves a credential
- `query_secret_store_with_fallbacks(service, accounts, var_name)` — Tries multiple accounts in order

**Risk:** Credential handling is security-sensitive. Fallback logic and error handling must be verified.

**Recommended tests:**
- `detect_os()` returns correct value on current platform
- `query_secret_store()` returns empty and non-zero exit when credential is missing
- `query_secret_store_with_fallbacks()` tries accounts in declared order
- Account masking in logs hides all but first 3 characters
- Graceful behavior when `secret-tool`/`security` binary is absent

### 1.3 `scripts/lib/constants.sh` — 0% dedicated coverage

Central constants used across the entire codebase. While other tests _consume_ these constants, nothing validates the constants themselves.

**Recommended tests:**
- Container mount path constants match what `Containerfile` and `entrypoint.sh` expect
- `KAPSIS_CODE_FILE_EXTENSIONS` regex matches all documented language extensions
- `KAPSIS_GIT_EXCLUDE_PATTERNS` includes all AI tool config files
- `KAPSIS_DEFAULT_COMMIT_EXCLUDE` covers known problematic files
- Guard variable prevents double-sourcing

---

## 2. Partially Tested Modules

### 2.1 `scripts/lib/agent-types.sh` — ~33% coverage

Only `normalize_agent_type()` and `agent_supports_hooks()` are tested (indirectly via `test-status-hooks.sh`). 7 functions are untested:

| Function | Risk |
|----------|------|
| `is_known_agent_type()` | Could accept invalid agent types |
| `agent_needs_fallback()` | Wrong fallback decision breaks monitoring |
| `agent_uses_python_status()` | Status reporting breaks for Python agents |
| `get_agent_hook_config_path()` | Wrong path → hooks silently fail |
| `get_agent_hook_types()` | Missing hook types → incomplete injection |
| `get_agent_display_name()` | Minor — cosmetic |
| `list_agent_types()` / `list_hook_agents()` | Affects CLI help output |

### 2.2 `scripts/lib/progress-monitor.sh` — ~40% coverage

`calculate_kapsis_progress()` and `map_progress_to_phase()` are tested. Untested:

- `parse_progress_file(file)` — Parses `progress.json` from agent output
- `update_status()` — Updates Kapsis status JSON
- Main monitoring loop — polling behavior, error recovery

---

## 3. Untested Main Scripts

Seven main scripts (39% of non-lib scripts) lack dedicated tests:

### 3.1 `scripts/build-agent-image.sh` (488 lines) — HIGH priority

Builds agent-specific container images. Key untested functionality:
- Agent YAML profile parsing (name, NPM/PIP deps, custom scripts)
- Dependency validation against enabled languages in build config
- Platform architecture detection and base image digest resolution
- `--pull` flag for pre-built image registry pull
- Dangling image cleanup after successful builds

### 3.2 `scripts/init-git-branch.sh` (91 lines) — HIGH priority

Initializes git branches for agent workflows. Key untested functionality:
- Remote branch existence checking (fetch + check)
- Branch creation from base-branch vs. current HEAD
- Checkout and tracking of existing remote branches

### 3.3 `scripts/post-exit-git.sh` (133 lines) — HIGH priority

Post-exit commit and push logic. Key untested functionality:
- Change detection (staged, unstaged, untracked)
- Branch correctness verification and switching
- Push fallback mechanism (`KAPSIS_PUSH_FALLBACK`)
- PR URL generation

### 3.4 `scripts/merge-changes.sh` (154 lines) — MEDIUM priority

Sandbox-to-project merge workflow. Key untested functionality:
- Sandbox directory discovery by agent ID
- Change categorization ([NEW] vs [MODIFY])
- `--dry-run`, `--force`, `--cleanup` modes
- rsync-based file merging

### 3.5 Setup scripts (3 scripts) — LOW priority

`setup-github-protection.sh`, `setup-homebrew-tap-sync.sh`, `setup-package-repos.sh` are interactive scripts that call GitHub APIs. Testing would require extensive mocking of the `gh` CLI.

---

## 4. Untested Hook Scripts

### 4.1 `scripts/hooks/precommit/run-tests.sh` — MEDIUM priority

Pre-commit hook that runs quick test suite. Key untested behavior:
- Unsets `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, `GIT_OBJECT_DIRECTORY` to prevent index corruption
- Runs test runner with `--quick -q` flags
- Blocks commit on test failure

---

## 5. Test Quality Gaps

### 5.1 Missing error path coverage

Tests generally cover happy paths well, but several failure scenarios are missing:

- **Container timeout/kill** — No tests for what happens when a container exceeds its time limit
- **Network failures during push** — No tests for broken connections mid-push
- **Permission denied** — Few tests for `chmod 000` directories or read-only filesystems
- **Disk space exhaustion** — No tests for out-of-space scenarios during commits or builds
- **Empty git repos** (no commits yet) — Could crash branch conflict detection

### 5.2 Missing concurrency/race condition tests

- Two agents writing to the same git worktree simultaneously
- Two agents pushing to the same branch simultaneously
- Status file reads during concurrent writes from multiple containers
- Container removal while another agent reads its status file
- Rapid sequential container starts (stress test)

### 5.3 Integration test gaps

`test-full-workflow.sh` and `test-parallel-agents.sh` cover basic scenarios, but miss:

- **Scalability** — No test with 10+ concurrent agents
- **Agent crash recovery** — What happens when a container crashes mid-operation
- **Interrupted push** — Push starts but connection drops before completion
- **Stale status cleanup** — Orphaned status files from crashed agents
- **Partial commit** — Agent stages files but crashes before `git commit`
- **Real remote interaction** — All git push tests use local mocks

### 5.4 Mocking concerns

**Over-mocking (may miss real bugs):**
- `test-git-auto-commit-push.sh` simulates push detection but never actually pushes to a remote
- `test-security.sh` validates generated capability arguments but doesn't verify Podman enforces them
- `test-status-reporting.sh` tests status writes in a single process — doesn't test concurrent writes from multiple containers

**Under-mocking (may be flaky):**
- `test-build-config.sh` reads actual `configs/build-profiles/*.yaml` — changes to those files break tests
- `test-filter-agent-config.sh` modifies files relative to the real home directory during tests

### 5.5 Test framework limitations

Missing assertion types:
- `assert_json_valid` — Currently tests call Python manually for JSON validation
- `assert_json_field_equals` — No jq-based field assertion
- `assert_exit_code_range` — For signal-terminated processes (128-139)
- `assert_file_contains_multiline` — Current grep-based assertion can't match across lines
- Timing/performance assertions

Missing infrastructure:
- No test fixture system — repetitive setup code across files
- No parallel test execution mode
- No container log capture on failure (makes debugging hard)
- No automatic flakiness detection or rerun

---

## 6. Prioritized Recommendations

### Tier 1 — High impact, addresses real risk

| # | Action | Rationale |
|---|--------|-----------|
| 1 | **Create `test-config-verifier.sh`** | Config validation is a CI gate; regressions silently ship broken configs |
| 2 | **Create `test-init-git-branch.sh`** | Branch initialization is used on every agent launch; base-branch logic is complex |
| 3 | **Create `test-post-exit-git.sh`** | Post-exit commit/push is the final step of every agent run; push fallback logic is critical |
| 4 | **Create `test-build-agent-image.sh`** | Agent image builds involve profile parsing, dependency validation, and platform detection |
| 5 | **Add concurrent write tests to `test-status-reporting.sh`** | Status files are written by multiple agents in production |
| 6 | **Add agent crash recovery integration test** | No coverage for container crash → stale status → cleanup path |

### Tier 2 — Strengthens coverage, moderate effort

| # | Action | Rationale |
|---|--------|-----------|
| 7 | **Create `test-secret-store.sh`** | Credential handling is security-sensitive |
| 8 | **Extend `test-agent-types.sh`** with full function coverage | 7 untested functions including hook config path resolution |
| 9 | **Create `test-merge-changes.sh`** | rsync-based merge has edge cases (conflicts, permissions) |
| 10 | **Add timeout/kill scenario tests** | Container time limits are enforced but never tested |
| 11 | **Add `assert_json_valid` and `assert_json_field_equals`** to framework | Reduces boilerplate; 5+ test files manually shell out to Python for JSON checks |
| 12 | **Add container log capture on test failure** | Debugging container test failures currently requires manual reproduction |

### Tier 3 — Polish and hardening

| # | Action | Rationale |
|---|--------|-----------|
| 13 | **Create `test-constants.sh`** | Verify mount paths match Containerfile expectations |
| 14 | **Add network failure injection tests** | Push/pull over network is untested for partial failures |
| 15 | **Extend `test-parallel-agents.sh`** to 5+ agents | Current test uses only 2 agents |
| 16 | **Add test data fixtures to framework** | Reduce 20+ lines of boilerplate per test file |
| 17 | **Create `test-precommit-run-tests.sh`** | Validate GIT env var cleanup prevents index corruption |
