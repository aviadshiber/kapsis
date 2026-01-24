# Bugs Found in Kapsis - Code Review Report

Date: 2026-01-24

## Summary

A comprehensive code review identified 6 bugs in the Kapsis codebase:
- **2 High Priority** - Require immediate attention
- **1 Security Concern** - Weakens supply chain protection
- **3 Medium/Low Priority** - Code quality improvements

---

## High Priority Bugs

### BUG #1: Temporary File Leak

**File:** `scripts/launch-agent.sh:1425-1427`

**Problem:** Inline task spec temp files are never cleaned up.

```bash
INLINE_SPEC_FILE=$(mktemp)
echo "$TASK_INLINE" > "$INLINE_SPEC_FILE"
CONTAINER_CMD+=("-v" "${INLINE_SPEC_FILE}:/task-spec.md:ro")
# ❌ No cleanup of $INLINE_SPEC_FILE
```

**Impact:** Temp files accumulate in `/tmp`, causing disk space issues over time.

**Fix:** Add cleanup trap at the start of `main()`:
```bash
trap 'rm -f "$INLINE_SPEC_FILE" 2>/dev/null' EXIT
```

---

### BUG #2: Architecture-Specific yq Binary Hardcoded

**File:** `Containerfile:65`

**Problem:** yq download is hardcoded to `amd64` architecture.

```dockerfile
RUN wget -qO /tmp/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
```

**Impact:** ARM64 container builds download wrong binary and fail at runtime.

**Fix:** Use `TARGETARCH` build argument:
```dockerfile
ARG TARGETARCH=amd64
ARG YQ_SHA256_AMD64=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
ARG YQ_SHA256_ARM64=<arm64-sha256-here>
RUN wget -qO /tmp/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}" && \
    # Use appropriate checksum based on architecture
```

---

## Security Concern

### BUG #3: Checksum Verification Continues on Failure

**File:** `Containerfile:80, 113`

**Problem:** SDKMAN and NVM checksum failures only produce warnings, not build failures.

```dockerfile
echo "${SDKMAN_INSTALL_SHA256}  /tmp/sdkman-install.sh" | sha256sum -c - || \
    { echo "WARNING: SDKMAN checksum mismatch - script may have been updated. Proceeding with caution."; }
```

**Impact:** Potential supply chain attacks could succeed if installer script is compromised.

**Recommendation:** Consider failing the build on checksum mismatch:
```dockerfile
{ echo "ERROR: SDKMAN checksum mismatch"; exit 1; }
```

---

## Medium Priority Bugs

### BUG #4: Silent Failure in Worktree Creation

**File:** `scripts/worktree-manager.sh:305-306, 311, 316`

**Problem:** The `|| true` pattern silently ignores all worktree creation failures.

```bash
run_git git worktree add "$worktree_path" -b "$branch" "origin/$branch" ||
    run_git git worktree add "$worktree_path" "$branch" || true
```

**Impact:** Difficult to diagnose worktree creation failures; error messages are lost.

**Fix:** Capture and log the error before falling through:
```bash
run_git git worktree add ... || {
    log_debug "First worktree creation method failed, trying fallback..."
    run_git git worktree add ... || {
        log_warn "All worktree creation methods failed"
        return 1
    }
}
```

---

## Low Priority Bugs

### BUG #5: Inefficient Duplicate Check in Array

**File:** `scripts/launch-agent.sh:1103-1110`

**Problem:** Iterates over both `-e` flags and values when checking for duplicates.

```bash
for existing in "${ENV_VARS[@]}"; do
    if [[ "$existing" == "${var_name}="* ]]; then
```

**Note:** Not a functional bug, just inefficient. The `-e` strings will never match `VAR_NAME=*`.

---

### BUG #6: Subshell Path Resolution Edge Case

**File:** `scripts/launch-agent.sh:884`

**Problem:** If directory doesn't exist, `cd` fails silently in subshell.

```bash
SPEC_FILE_ABS="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
```

**Impact:** Could produce incorrect path if dirname doesn't exist.

**Fix:** Validate directory exists first or use `realpath`:
```bash
SPEC_FILE_ABS="$(realpath "$SPEC_FILE")" || {
    log_error "Spec file not found: $SPEC_FILE"
    exit 1
}
```

---

## Items Verified as NOT Bugs

The following were initially flagged but verified as correct:

1. **JSON schema in status.sh:580** - The `sandbox_mode` field IS properly quoted
2. **Network mode logic in launch-agent.sh:693** - Logic is correct; config is only read when CLI hasn't overridden the default

---

## Recommendations

1. **Immediate:** Fix Bug #1 (temp file leak) and Bug #2 (yq architecture)
2. **Short-term:** Address the security concern with checksum verification
3. **Consider:** Improving error logging in worktree-manager.sh
