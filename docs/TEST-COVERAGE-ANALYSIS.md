# Test Coverage Analysis

Analysis of the Kapsis test suite coverage, identifying gaps and recommending improvements.

**Codebase snapshot (2026-04-24):** 20 main scripts, 29 library modules, 15 hook scripts, 2 backends, 85 Bash test files, 6 Go test files (operator).

---

## 1. Completely Untested Modules

### 1.1 `scripts/lib/secret-store.sh` — 0% direct coverage

Cross-platform credential retrieval (macOS Keychain, Linux secret-tool). `tests/test-secret-store-injection.sh` covers the secret *injection* feature, but does not exercise the library's public API:

- `detect_os()` — returns `"macos"` | `"linux"` | `"unknown"`
- `query_secret_store(service, account)` — retrieves a credential
- `query_secret_store_with_fallbacks(service, accounts, var_name)` — tries multiple accounts in order

**Risk:** Credential handling is security-sensitive. Fallback ordering, masking, and graceful-absent-binary behavior are all unverified.

**Recommended tests:**
- `detect_os()` returns correct value on current platform (gate with `is_macos`/`is_linux` helpers from `compat.sh`)
- `query_secret_store()` returns empty + non-zero exit when credential is missing
- `query_secret_store_with_fallbacks()` tries accounts in declared order, stops on first hit
- Account masking in logs hides all but first 3 characters
- Graceful behavior when `secret-tool` / `security` binary is absent (shim PATH)

### 1.2 `scripts/lib/config-verifier.sh` — no dedicated function-level coverage

842 LOC. Referenced by 4 tests as a side-source, but none exercise its 8 public functions directly:

- `validate_tool_phase_mapping(file)` — tool-phase-mapping.yaml structure
- `validate_agent_profile(file)` — agent profile YAML schema
- `validate_launch_config(file)` — launch configuration YAML
- `validate_network_config(file)` — network allowlist configuration
- `detect_config_type(file)` — auto-detects config file type
- `test_pattern_matching(file)` — tool-to-phase mapping logic
- `check_dependencies()` — verifies yq/yamllint availability
- `print_summary()` — reports validation results

**Risk:** Config validation is a CI gate. Silent regressions here allow broken configs to ship.

**Recommended tests:**
- Valid/malformed fixtures for each validator (including each missing-required-field case)
- `detect_config_type()` correctly classifies all config types
- Invalid patterns produce warnings, not crashes

### 1.3 `scripts/lib/constants.sh` — 0% dedicated coverage

311 LOC. Heavily consumed by tests (36 references across 15 files), but nothing validates the constants themselves against their real callers (`Containerfile`, `entrypoint.sh`).

**Recommended tests:**
- Container mount path constants match what `Containerfile` and `entrypoint.sh` expect
- `KAPSIS_CODE_FILE_EXTENSIONS` regex matches all documented language extensions
- `KAPSIS_GIT_EXCLUDE_PATTERNS` includes all AI tool config files
- `KAPSIS_DEFAULT_COMMIT_EXCLUDE` covers known problematic files
- Guard variable prevents double-sourcing

### 1.4 `operator/internal/controller/status_bridge.go` — 0% coverage

167 LOC. Bridges container `status.json` → `AgentRequest` CRD status. Sibling files (`agentrequest_controller.go`, `pod_builder.go`, `networkpolicy_builder.go`) all have test files; this one does not.

**Risk:** Silent drift affects every K8s-backend agent. Every documented `error_type` (`agent_failure`, `agent_partial`, `commit_failure`, etc.) and phase transition should be asserted.

---

## 2. Partially Tested Modules

### 2.1 `scripts/lib/agent-types.sh` — ~33% coverage

`normalize_agent_type()` and `agent_supports_hooks()` are tested indirectly via `test-status-hooks.sh` and `test-agent-type-detection.sh`. Untested:

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

- `parse_progress_file(file)` — parses `progress.json` from agent output
- `update_status()` — updates Kapsis status JSON
- Main monitoring loop — polling behavior, error recovery

### 2.3 `scripts/lib/audit-patterns.sh` — pattern-level only

Exercised by `test-audit-system.sh` for the end-to-end audit report path, but the individual pattern detectors (curl `-v`, base64 data URIs, token-shaped strings, credential-file access) are not directly asserted. Issue #246 (curl `-v` detection) would have caught silently before merge with a pattern-level test matrix.

### 2.4 `scripts/backends/k8s.sh` — config translation only

192 LOC. Covered indirectly via `test-k8s-config-translation.sh` and `test-backend-abstraction.sh`, but the backend-abstraction contract (launch → status polling → teardown) is not asserted end-to-end. No dry-run CR YAML fixture.

---

## 3. Untested Main Scripts

Eight main scripts (40% of top-level scripts) lack dedicated tests:

### 3.1 `scripts/build-agent-image.sh` (487 lines) — HIGH priority

Builds agent-specific container images. Key untested functionality:
- Agent YAML profile parsing (name, NPM/PIP deps, custom scripts)
- Dependency validation against enabled languages in build config
- Platform architecture detection and base image digest resolution
- `--pull` flag for pre-built image registry pull
- Dangling image cleanup after successful builds

### 3.2 `scripts/init-git-branch.sh` (99 lines) — HIGH priority

Initializes git branches for agent workflows. Key untested functionality:
- Remote branch existence checking (fetch + check)
- Branch creation from base-branch vs. current HEAD
- Checkout and tracking of existing remote branches

### 3.3 `scripts/post-exit-git.sh` (137 lines) — HIGH priority

Post-exit commit and push logic. Key untested functionality:
- Change detection (staged, unstaged, untracked)
- Branch correctness verification and switching
- Push fallback mechanism (`KAPSIS_PUSH_FALLBACK`)
- Exit codes 2 (push failed) and 6 (commit failed)
- PR URL generation

### 3.4 `scripts/merge-changes.sh` (153 lines) — MEDIUM priority

Sandbox-to-project merge workflow. Key untested functionality:
- Sandbox directory discovery by agent ID
- Change categorization ([NEW] vs [MODIFY])
- `--dry-run`, `--force`, `--cleanup` modes
- rsync-based file merging

### 3.5 Setup scripts (4 scripts) — LOW priority

`setup-github-protection.sh` (273 L), `setup-homebrew-tap-sync.sh` (79 L), `setup-package-repos.sh` (236 L), `setup-release-app.sh` (185 L) are interactive scripts that call external APIs (GitHub, package registries). Testing would require extensive mocking of `gh` / `curl`.

---

## 4. Untested Hook Scripts

### 4.1 `scripts/hooks/precommit/run-tests.sh` (48 L) — MEDIUM priority

Pre-commit hook that runs the quick test suite. Key untested behavior:
- Unsets `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, `GIT_OBJECT_DIRECTORY` to prevent index corruption
- Runs test runner with `--quick -q` flags
- Blocks commit on test failure

This was called out in v1 of this doc; still uncovered.

---

## 5. Coverage Fixed Since v1

These modules were flagged as untested in the previous revision and now have dedicated tests:

| Module | Test file |
|--------|-----------|
| `scripts/lib/audit.sh` | `test-audit-system.sh` |
| `scripts/lib/liveness-monitor.sh` | `test-liveness-monitor.sh` |
| `scripts/lib/dns-filter.sh` | `test-dns-filtering.sh` |
| `scripts/lib/dns-pin.sh` | `test-dns-pinning.sh` |
| `scripts/lib/k8s-config.sh` | `test-k8s-config-translation.sh` |
| `scripts/lib/atomic-copy.sh` | `test-atomic-copy.sh` |
| `scripts/lib/build-config.sh` | `test-build-config.sh` |
| `scripts/lib/validate-scope.sh` | `test-scope-validation.sh`, `test-lib-namespace-isolation.sh` |
| `scripts/lib/progress-display.sh` | `test-progress-display.sh` |
| `scripts/lib/sanitize-files.sh` | `test-sanitize-files.sh` |
| `scripts/lib/git-remote-utils.sh` | `test-git-remote-utils.sh` |
| `scripts/lib/ssh-keychain.sh` | `test-ssh-keychain.sh`, `test-keychain-platform.sh` |
| `scripts/lib/inject-lsp-config.sh` | `test-lsp-config.sh` |
| `scripts/lib/inject-status-hooks.sh` | `test-status-hooks.sh` |
| `scripts/lib/rewrite-plugin-paths.sh` | `test-plugin-path-rewrite.sh` |
| `scripts/lib/ssh-config-compat.sh` | `test-ssh-config-portability.sh` |

---

## 6. Test Quality Gaps

### 6.1 Exit-code contract is not asserted

`CLAUDE.md` documents exit codes 0–6 with specific sentinel triggers (`KAPSIS_MOUNT_FAILURE:` → 4, post-completion hang → 5, `git commit` failure → 6). No test injects the sentinels and asserts the mapping. A regression here silently degrades caller behavior (e.g. slack-bot retrying on `agent_partial` instead of treating the work as landed, per Issue #260).

### 6.2 Missing error-path coverage

Happy paths are well covered. Failure scenarios that are not:

- **Container timeout / kill mid-run** — time-limit enforcement untested
- **Network failure during push** — broken connection mid-push
- **Permission denied** — `chmod 000` directories, read-only filesystems
- **Disk space exhaustion** — out-of-space during commits or builds
- **Empty git repos** (no commits yet) — could crash branch-conflict detection

### 6.3 Missing concurrency / race-condition tests

- Two agents writing to the same git worktree simultaneously
- Two agents pushing to the same branch simultaneously
- Status-file reads during concurrent writes from multiple containers
- Container removal while another agent reads its status file
- Rapid sequential container starts (stress test)

### 6.4 Integration test gaps

`test-full-workflow.sh` and `test-parallel-agents.sh` cover basic scenarios but miss:

- **Scalability** — `test-parallel-agents.sh` uses only 2 agents; no 5+/10+ case
- **Agent crash recovery** — what happens when a container crashes mid-operation
- **Interrupted push** — push starts but connection drops before completion
- **Stale status cleanup** — orphaned status files from crashed agents
- **Partial commit** — agent stages files but crashes before `git commit` (Issue #256 path)
- **Real remote interaction** — all `git push` tests use local mocks; capabilities we generate are not verified against an actual Podman enforce-point

### 6.5 Test framework limitations

Missing assertions:
- `assert_json_valid` — tests currently shell out to Python for JSON validation
- `assert_json_field_equals` — no jq-based field assertion
- `assert_exit_code_range` — for signal-terminated processes (128–139)
- `assert_file_contains_multiline` — current grep-based assertion can't match across lines
- Timing / performance assertions

Missing infrastructure:
- No test fixture system — repetitive setup code across files
- No parallel test execution mode
- No container log capture on failure (makes debugging hard)
- No automatic flakiness detection or rerun

---

## 7. Prioritized Recommendations

### Tier 1 — High impact, addresses real risk

| # | Action | Rationale |
|---|--------|-----------|
| 1 | Create `tests/test-config-verifier.sh` | Config validation is a CI gate; regressions silently ship broken configs |
| 2 | Create `tests/test-secret-store.sh` | Credential handling is security-sensitive; inject-feature test is not a substitute |
| 3 | Create `tests/test-audit-patterns.sh` | Direct pattern-matcher coverage would have caught Issue #246 pre-merge |
| 4 | Create `tests/test-init-git-branch.sh` | Branch init runs on every agent launch; base-branch logic is complex |
| 5 | Create `tests/test-post-exit-git.sh` | Covers exit codes 2 & 6, push-fallback sentinel, PR-URL logic |
| 6 | Create `tests/test-build-agent-image.sh` | Image builds involve profile parsing, dep validation, platform detection |
| 7 | Create `tests/test-exit-code-contract.sh` | Inject all documented sentinels; assert 4/5/6 mapping matches `CLAUDE.md` |
| 8 | Create `operator/internal/controller/status_bridge_test.go` | Every `error_type` and phase transition for the K8s backend is untested |
| 9 | Add concurrent-writer case to `test-status-reporting.sh` | Status files are written by multiple agents in production |

### Tier 2 — Strengthens coverage, moderate effort

| # | Action | Rationale |
|---|--------|-----------|
| 10 | Extend `test-agent-type-detection.sh` to full function coverage | 7 untested functions including hook-config-path resolution |
| 11 | Create `tests/test-merge-changes.sh` | rsync-based merge has edge cases (conflicts, permissions) |
| 12 | Add container-timeout/kill scenario tests | Time limits are enforced but never asserted |
| 13 | Add `assert_json_valid` / `assert_json_field_equals` / `assert_exit_code_range` / `assert_file_contains_multiline` to framework | Reduces boilerplate; 5+ tests manually shell out to Python |
| 14 | Add container-log capture on test failure (EXIT trap in framework) | Debugging container failures currently requires manual reproduction |
| 15 | Extend `test-parallel-agents.sh` from 2 → 5 agents; add 10-agent case behind `KAPSIS_STRESS=1` | Current coverage asserts nothing about fan-out at realistic scale |
| 16 | Add agent crash-recovery integration test | No coverage for container crash → stale status → cleanup path; verifies `error_type=agent_partial` |

### Tier 3 — Polish and hardening

| # | Action | Rationale |
|---|--------|-----------|
| 17 | Create `tests/test-constants.sh` | Verify mount paths match `Containerfile` / `entrypoint.sh` expectations |
| 18 | Add network-failure injection test (throwaway git remote) | Push/pull over network is untested for partial failures |
| 19 | Add test-data fixture system to `tests/lib/test-framework.sh` | Reduce 20+ lines of boilerplate per test file |
| 20 | Create `tests/test-precommit-run-tests.sh` | Validate `GIT_*` env-var cleanup prevents index corruption |
| 21 | Complete `scripts/lib/progress-monitor.sh` coverage | `parse_progress_file`, `update_status`, main loop |
| 22 | Backend-abstraction E2E for `scripts/backends/k8s.sh` | Dry-run CR YAML fixture; status-polling contract |
