# Code Quality Improvements: DRY, Separation of Concerns, Simplification, and Security Hardening

> **To create this issue on GitHub:** Copy everything below the line and paste into https://github.com/aviadshiber/kapsis/issues/new
>
> **Labels:** `enhancement`, `tech-debt`, `code-quality`

---

## Summary

Comprehensive code review findings covering four categories of improvements.

---

## 1. DRY Violations

### 1.1 Duplicated PR URL Generation
**Locations:**
- `scripts/post-container-git.sh:483-508`
- `scripts/entrypoint.sh:588-600`

**Issue:** Nearly identical logic for generating PR URLs for GitHub, GitLab, and Bitbucket.

**Fix:** Extract to `lib/git-remote-utils.sh` with functions like `detect_git_provider()` and `generate_pr_url()`.

### 1.2 Duplicated Volume Mount Generation
**Location:** `scripts/launch-agent.sh:934-1014`

**Issue:** `generate_volume_mounts_worktree()` and `generate_volume_mounts_overlay()` share ~70% of their code:
- Status directory mount
- Maven repository volume
- Gradle cache volume
- GE workspace volume
- Spec file mount
- Filesystem includes
- SSH known hosts

**Fix:** Merge into single `generate_volume_mounts()` with mode-specific additions.

### 1.3 Duplicated Git Exclude Patterns
**Locations:**
- `scripts/worktree-manager.sh:127-145` (in `ensure_git_excludes`)
- `scripts/worktree-manager.sh:402-418` (in `prepare_sanitized_git`)

**Issue:** Same protective exclude patterns written in two places.

**Fix:** Define once in `lib/constants.sh` as `KAPSIS_GIT_EXCLUDE_PATTERNS`.

### 1.4 Duplicated Logging Fallbacks
**Locations:**
- `scripts/lib/dns-filter.sh:47-51`
- `scripts/entrypoint.sh:36-42`

**Issue:** Both define fallback logging functions if library isn't loaded.

**Fix:** Standardize via `lib/logging.sh` or create `lib/logging-minimal.sh`.

---

## 2. Separation of Concerns

### 2.1 `launch-agent.sh` Too Large (~1650 lines)

**Issue:** Script handles too many responsibilities:
- Argument parsing
- Secret store queries
- Config parsing/validation
- Branch name generation
- Volume mount generation
- Container command building
- Post-container operations

**Fix:** Extract into focused libraries:

| Current Location | New Library |
|-----------------|-------------|
| Lines 128-208 | `lib/secret-store.sh` |
| Lines 706-822 | `lib/config-parser.sh` |
| Lines 922-1068 | `lib/volume-mounts.sh` |
| Lines 1300-1318 | `lib/branch-generator.sh` |

### 2.2 `entrypoint.sh` Mixes Multiple Domains (~1050 lines)

**Issue:** Handles:
- DNS filtering setup
- Git configuration
- Environment setup (SDKMAN, NVM, Maven)
- Credential injection
- Status tracking setup
- Agent hook installation

**Fix:** Each domain should be a library called by a thin orchestrator.

### 2.3 PR URL Generation in `post-container-git.sh`

**Issue:** Git-operations script contains URL generation logic for web interfaces.

**Fix:** Move to `lib/git-remote-utils.sh` along with `is_github_repo()`, `generate_fork_pr_url()`, and git provider detection.

---

## 3. Simpler Approaches

### 3.1 Redundant Agent Hook Wrappers
**Location:** `scripts/entrypoint.sh:721-723`

```bash
setup_claude_hooks() { install_agent_hooks "claude-cli" "Claude Code"; }
setup_codex_hooks()  { install_agent_hooks "codex-cli" "Codex CLI"; }
setup_gemini_hooks() { install_agent_hooks "gemini-cli" "Gemini CLI"; }
```

**Issue:** One-liner wrappers add indirection without value.

**Fix:** Use `install_agent_hooks` directly with `get_agent_display_name()`.

### 3.2 Complex Regex for Git URL Parsing
**Issue:** Multiple sed patterns parse git URLs throughout the codebase.

**Fix:** Create single `parse_repo_path()` utility in `lib/git-remote-utils.sh`.

### 3.3 Worktree Mode Detection
**Location:** `scripts/entrypoint.sh:985`

```bash
if [[ "$sandbox_mode" == "worktree" ]] || setup_worktree_git; then
```

**Issue:** Uses side-effect in conditional, hard to read.

**Fix:** Explicit check with separate function call.

---

## 4. Security Issues

### 4.1 :warning: `eval` Usage in Timer Functions
**Location:** `scripts/lib/logging.sh:404`

```bash
log_timer_start() {
    local timer_name="${1:-default}"
    eval "_KAPSIS_TIMER_${timer_name}=$(date +%s)"  # eval with user input
}
```

**Issue:** If `timer_name` contains shell metacharacters, could lead to code injection.

**Fix:** Sanitize input - only allow alphanumeric and underscore:
```bash
if [[ ! "$timer_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
    log_warn "Invalid timer name: $timer_name"
    return 1
fi
```

### 4.2 :warning: Log File Permissions Too Permissive
**Location:** `scripts/lib/dns-filter.sh:278-279`

```bash
chmod 644 "$KAPSIS_DNS_LOG_FILE"
```

**Issue:** DNS query logs could reveal sensitive information. Mode 644 allows any user to read.

**Fix:** Use mode 600 (owner read/write only).

### 4.3 Inconsistent Validation in Secret Store Functions
**Location:** `scripts/launch-agent.sh:178-208`

**Issue:** `query_secret_store_with_fallbacks` iterates over accounts without validating format.

**Fix:** Add validation for account format (alphanumeric, dots, @, hyphens).

### 4.4 Missing Input Sanitization in Co-author Email Extraction
**Location:** `scripts/post-container-git.sh:240-241`

**Issue:** Regex allows any characters inside `<>`.

**Fix:** Validate email format before using.

### 4.5 Race Condition Comment Improvement
**Location:** `scripts/entrypoint.sh:97-99`

**Issue:** Umask protection is good, but comment could be clearer about TOCTOU threat.

---

## Priority Matrix

| Priority | Category | Issue | Effort |
|----------|----------|-------|--------|
| **High** | Security | eval in timer functions | Low |
| **High** | Security | Log file permissions | Low |
| **High** | DRY | PR URL generation duplication | Medium |
| Medium | Separation | Extract secret-store.sh | Medium |
| Medium | DRY | Volume mount generation | Medium |
| Medium | Simplify | Git URL parsing utility | Low |
| Low | DRY | Git exclude patterns | Low |
| Low | Simplify | Remove agent hook wrappers | Low |

---

## Notes

The codebase is overall well-structured with good security practices. The main areas for improvement are:
1. Reducing duplication
2. Extracting focused libraries from the larger scripts
3. A few security hardening items

These improvements would enhance maintainability and reduce the risk of bugs when making changes.
