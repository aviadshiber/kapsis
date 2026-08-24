# Worktree in-container git + hardened host push/PR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the worktree-mode agent working in-container git (commit/diff/verify), and make the host reliably sanitize → validate → commit → push → create a PR, fail-closed.

**Architecture:** Architecture B from `designs/2026-08-09-worktree-in-container-push-design.md`. Three plumbing fixes make the sandboxed git writable for the agent's own use; the host (`post-container-git.sh`) remains the sole pusher and is hardened (case-insensitive kapsis-path exclusion, file-mode validation, fetch-before-push, provider-pluggable post-push PR hook, observability). No credentialed push happens inside the container.

**Tech Stack:** Bash; kapsis test framework (`tests/lib/test-framework.sh`, `assert_*`, `run_test`); `yq` for config; git; podman (not exercised by unit tests).

## Global Constraints

- Target branch `feat/worktree-in-container-push` off `origin/main` (== v3.2.4).
- Bash with `set -euo pipefail` in scripts; guard optional vars with `${var:-}`.
- Tests are functions in `tests/test-*.sh`, registered with `run_test <fn>` in the file's `main`, and must pass under `bash tests/<file>.sh`. Add new tests to `tests/run-all-tests.sh` if a new file is created.
- Provider-agnostic: never hardcode a git host/provider in kapsis scripts.
- No credential material in the container's git config, logs, sentinels, or argv.
- Preserve existing public behavior when the new config key is unset (`git.post_push_hook` absent ⇒ today's "print PR instructions" behavior).

---

### Task 1: Run `setup_worktree_git` in worktree mode (GIT_DIR fix)

**Files:**
- Modify: `scripts/entrypoint.sh` (the sandbox-mode dispatch ~1938; `setup_worktree_git` ~764-793)
- Test: `tests/test-worktree-incontainer-git.sh` (new)

**Interfaces:**
- Consumes: `setup_worktree_git()` (exports `GIT_DIR="$CONTAINER_GIT_PATH"` when `$CONTAINER_GIT_PATH/kapsis-meta` exists).
- Produces: after the dispatch, in worktree mode `GIT_DIR` is exported to the sanitized `.git-safe`.

- [ ] **Step 1: Write the failing test** — create `tests/test-worktree-incontainer-git.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAPSIS_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/test-framework.sh"
source "$KAPSIS_ROOT/scripts/lib/logging.sh"; log_init "test-worktree-incontainer-git"
source "$KAPSIS_ROOT/scripts/lib/constants.sh"
source "$KAPSIS_ROOT/scripts/entrypoint.sh" >/dev/null 2>&1 || true  # source funcs only

test_setup_worktree_git_exports_gitdir() {
    local d; d=$(mktemp -d)
    mkdir -p "$d/gitsafe"
    printf 'BRANCH=feature/x\n' > "$d/gitsafe/kapsis-meta"
    CONTAINER_GIT_PATH="$d/gitsafe" GIT_DIR="" setup_worktree_git
    assert_equals "$d/gitsafe" "${GIT_DIR:-}" "GIT_DIR should point at sanitized .git-safe"
    rm -rf "$d"
}

main() { run_test test_setup_worktree_git_exports_gitdir; print_test_summary; }
main "$@"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-worktree-incontainer-git.sh`
Expected: FAIL — either `setup_worktree_git` not found (sourcing guarded) or `GIT_DIR` empty. (If sourcing `entrypoint.sh` executes `main`, guard it — see Step 3 note.)

- [ ] **Step 3: Make the dispatch call `setup_worktree_git` in worktree mode**

In `scripts/entrypoint.sh`, replace the short-circuit at ~1938:

```bash
    # Worktree mode needs GIT_DIR exported by setup_worktree_git() so the
    # in-container agent has working git; the old `[[ ==worktree ]] || setup…`
    # short-circuited that call away. Run it explicitly in worktree mode.
    local _kapsis_is_worktree=false
    if [[ "$sandbox_mode" == "worktree" ]]; then
        setup_worktree_git || log_warn "worktree git setup incomplete; in-container git may be limited"
        _kapsis_is_worktree=true
    elif setup_worktree_git; then
        _kapsis_is_worktree=true
    fi
    if [[ "$_kapsis_is_worktree" == "true" ]]; then
```

Update the closing comment (was "git is already set up by host") to: `# Worktree mode: GIT_DIR now points at the sanitized .git-safe (setup_worktree_git).` Ensure `entrypoint.sh` only runs `main "$@"` under `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so tests can source functions without executing (add this guard if absent).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-worktree-incontainer-git.sh`
Expected: PASS.

- [ ] **Step 5: Register + commit**

Add `run_test`s file to `tests/run-all-tests.sh` list. Then:
```bash
git add scripts/entrypoint.sh tests/test-worktree-incontainer-git.sh tests/run-all-tests.sh
git commit -m "fix(worktree): export GIT_DIR in worktree mode (in-container git was dead)"
```

---

### Task 2: Mount the sanitized git read-write

**Files:**
- Modify: `scripts/launch-agent.sh` `generate_volume_mounts_worktree()` (~1590-1605)
- Test: `tests/test-worktree-incontainer-git.sh` (extend)

**Interfaces:**
- Consumes: globals `SANITIZED_GIT_PATH`, `CONTAINER_GIT_PATH`, `OBJECTS_PATH`, `CONTAINER_OBJECTS_PATH`; populates `VOLUME_MOUNTS` array.
- Produces: `VOLUME_MOUNTS` contains `-v ${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}` (writable, no `:ro`); objects mount stays `:ro`.

- [ ] **Step 1: Write the failing test** (append to the new test file, register in `main`):

```bash
test_sanitized_git_mounted_rw() {
    source "$KAPSIS_ROOT/scripts/launch-agent.sh" >/dev/null 2>&1 || true
    SANITIZED_GIT_PATH="/tmp/sg"; CONTAINER_GIT_PATH="/workspace/.git-safe"
    OBJECTS_PATH="/tmp/obj"; CONTAINER_OBJECTS_PATH="/workspace/.git-objects"
    WORKTREE_PATH="/tmp/wt"; VOLUME_MOUNTS=()
    generate_volume_mounts_worktree
    local joined="${VOLUME_MOUNTS[*]}"
    assert_contains "$joined" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}" "git-safe mounted"
    assert_not_contains "$joined" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}:ro" "git-safe must be RW"
    assert_contains "$joined" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro" "objects stay RO"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-worktree-incontainer-git.sh`
Expected: FAIL on `assert_not_contains` (`:ro` still present).

- [ ] **Step 3: Drop `:ro` on the git-safe mount** — in `generate_volume_mounts_worktree`:

```bash
    # RW so the in-container agent can stage/commit into the sanitized GIT_DIR.
    # (Objects DB below stays :ro; new objects land in the writable objects dir
    # created by prepare_sanitized_git via objects/info/alternates.)
    VOLUME_MOUNTS+=("-v" "${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}")
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-worktree-incontainer-git.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/launch-agent.sh tests/test-worktree-incontainer-git.sh
git commit -m "fix(worktree): mount sanitized git read-write for in-container commit"
```

---

### Task 3: Objects via git alternate (writable) instead of RO symlink

**Files:**
- Modify: `scripts/worktree-manager.sh` `prepare_sanitized_git()` (~522-527 objects handling)
- Modify: `scripts/launch-agent.sh` `repoint_sanitized_git_objects()` (~3635-3667) — adapt/retire
- Test: `tests/test-sanitized-git-objects.sh` (extend)

**Interfaces:**
- Consumes: `$sanitized_dir`, `$CONTAINER_OBJECTS_PATH`.
- Produces: `$sanitized_dir/objects/` is a real directory containing `info/alternates` (single line = `$CONTAINER_OBJECTS_PATH`) and writable `pack/`; NOT a symlink.

- [ ] **Step 1: Write the failing test** (append to `tests/test-sanitized-git-objects.sh`, register in `main`):

```bash
test_objects_is_writable_dir_with_alternate() {
    local d; d=$(mktemp -d); local sg="$d/sg"; mkdir -p "$sg"
    CONTAINER_OBJECTS_PATH="/workspace/.git-objects"
    _prepare_objects_alternate "$sg"   # helper extracted in Step 3
    assert_dir_exists "$sg/objects" "objects must be a real dir"
    assert_false "[ -L \"$sg/objects\" ]" "objects must NOT be a symlink"
    assert_file_contains "$sg/objects/info/alternates" "$CONTAINER_OBJECTS_PATH" "alternate points at parent DB"
    rm -rf "$d"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-sanitized-git-objects.sh`
Expected: FAIL — `_prepare_objects_alternate` not defined.

- [ ] **Step 3: Extract + implement the alternate** — in `worktree-manager.sh`, replace the `ln -sfn "$CONTAINER_OBJECTS_PATH" "$sanitized_dir/objects"` line with a call to a new helper, and define it:

```bash
# Writable local objects dir + read-only borrow of the parent object DB via
# alternates, so in-container `git commit` can write new objects while existing
# objects are borrowed RO. Replaces the old RO symlink (which made commit fail).
_prepare_objects_alternate() {
    local sanitized_dir="$1"
    rm -f "$sanitized_dir/objects" 2>/dev/null || true   # drop any prior symlink
    mkdir -p "$sanitized_dir/objects/info" "$sanitized_dir/objects/pack"
    printf '%s\n' "$CONTAINER_OBJECTS_PATH" > "$sanitized_dir/objects/info/alternates"
}
```
Call `_prepare_objects_alternate "$sanitized_dir"` where the symlink was created.

- [ ] **Step 4: Adapt the host repoint** — `repoint_sanitized_git_objects()` rewrote the symlink to the host path for host use. The host commit/push operates on the **real worktree gitdir**, not the sanitized dir, so this is no longer load-bearing. Make it idempotently rewrite the alternate's parent path to the host `OBJECTS_PATH` (for any host-side read of the sanitized dir) instead of `ln -sfn`:

```bash
    # sanitized objects now use an alternates file, not a symlink.
    if [[ -f "$sanitized_git/objects/info/alternates" ]]; then
        printf '%s\n' "$host_objects_path" > "$sanitized_git/objects/info/alternates"
    fi
```
(Keep the function's existing signature/callers; only the body's rewrite mechanism changes.)

- [ ] **Step 5: Run tests to verify pass**

Run: `bash tests/test-sanitized-git-objects.sh`
Expected: PASS (new test + existing tests still green).

- [ ] **Step 6: Commit**

```bash
git add scripts/worktree-manager.sh scripts/launch-agent.sh tests/test-sanitized-git-objects.sh
git commit -m "fix(worktree): objects via alternates (writable) so in-container commit works"
```

---

### Task 4: Host exclusion case-insensitive + file-mode validation (fail-closed)

**Files:**
- Modify: `scripts/post-container-git.sh` `validate_staged_files()` (~97-150+)
- Test: `tests/test-post-container-git.sh` (extend)

**Interfaces:**
- Consumes: `worktree_path` on a git repo with a staged index.
- Produces: `validate_staged_files` returns non-zero (security issue) when a staged path matches `.kapsis/` / `.git-safe/` / `.git-objects/` **case-insensitively**, or when a staged entry is a symlink (`120000`), gitlink (`160000`), or an exec-bit flip (`100755`) on a non-script.

- [ ] **Step 1: Write failing tests** (append to `tests/test-post-container-git.sh`, register in `main`):

```bash
_mk_repo() { local r; r=$(mktemp -d); ( cd "$r"; git init -q; git config user.email a@b.c; git config user.name a ); echo "$r"; }

test_reject_uppercase_kapsis_dir() {
    local r; r=$(_mk_repo); mkdir -p "$r/.Kapsis"; echo x > "$r/.Kapsis/f"
    ( cd "$r"; git add -A -f )
    assert_command_fails "validate_staged_files '$r'" ".Kapsis/ must be rejected (case-insensitive)"
    rm -rf "$r"
}
test_reject_symlink_entry() {
    local r; r=$(_mk_repo); ( cd "$r"; ln -s /etc/passwd link; git add -A )
    assert_command_fails "validate_staged_files '$r'" "symlink (120000) must be rejected"
    rm -rf "$r"
}
test_reject_gitlink_entry() {
    local r; r=$(_mk_repo)
    ( cd "$r"; git update-index --add --cacheinfo 160000,0000000000000000000000000000000000000000,sub )
    assert_command_fails "validate_staged_files '$r'" "gitlink (160000) must be rejected"
    rm -rf "$r"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-post-container-git.sh`
Expected: FAIL — uppercase `.Kapsis`, symlink, gitlink currently pass validation.

- [ ] **Step 3: Make exclusion case-insensitive + add mode check** — in `validate_staged_files`, change the three greps to `grep -iE` and add a mode gate before the return:

```bash
    # Case-insensitive: the container FS is case-sensitive, so `.Kapsis/` is a
    # distinct path a case-sensitive filter would miss and commit.
    kapsis_files=$(git diff --cached --name-only 2>/dev/null | grep -iE "^\.kapsis/" || true)
    ...
    kapsis_mount_files=$(git diff --cached --name-only 2>/dev/null | grep -iE "^\.git-(safe|objects)/" || true)
    ...
    # File-mode validation: reject smuggled symlinks/gitlinks. `reset --soft` /
    # `git add` can carry crafted index modes past a content-only sanitizer.
    local bad_modes
    bad_modes=$(git diff --cached --raw 2>/dev/null | awk '{print $2}' | grep -E "^(120000|160000)$" || true)
    if [[ -n "$bad_modes" ]]; then
        log_warn "Rejecting staged symlink/gitlink entries (modes: $(echo "$bad_modes" | tr '\n' ' '))"
        has_security_issues=1
    fi
```
(Keep the existing `has_security_issues` → non-zero return contract so `commit_changes` aborts = fail-closed, no push.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-post-container-git.sh`
Expected: PASS (new + existing).

- [ ] **Step 5: Commit**

```bash
git add scripts/post-container-git.sh tests/test-post-container-git.sh
git commit -m "fix(host): case-insensitive kapsis exclusion + reject symlink/gitlink (fail-closed)"
```

---

### Task 5: Host fetch-before-push / no blind non-fast-forward

**Files:**
- Modify: `scripts/post-container-git.sh` `push_changes()` (~813-875)
- Test: `tests/test-post-container-git.sh` (extend, fake local remote)

**Interfaces:**
- Consumes: `worktree_path`, `remote`, `remote_branch`.
- Produces: before pushing, fetch the remote branch; if the remote advanced beyond the local's known base (divergence), do **not** blind-push — return non-zero with a clear reason (reconcile is out of scope for the automated path; fail-closed and surface the fallback command, which already exists via `status_set_push_fallback`).

- [ ] **Step 1: Write the failing test** — a bare repo as `origin`, advance it, expect push_changes to refuse the non-ff:

```bash
test_push_refuses_non_fast_forward() {
    local up; up=$(mktemp -d); ( cd "$up"; git init -q --bare )
    local a; a=$(_mk_repo); ( cd "$a"; git remote add origin "$up"; echo 1>f; git add -A; git commit -qm base; git push -q -u origin HEAD:refs/heads/main )
    # second clone advances origin/main
    local b; b=$(mktemp -d); git clone -q "$up" "$b"; ( cd "$b"; echo 2>f; git add -A; git commit -qm adv; git push -q origin HEAD:main )
    # 'a' makes a divergent commit on its stale base
    ( cd "$a"; echo 3>g; git add -A; git commit -qm local )
    assert_command_fails "push_changes '$a' origin main" "divergent remote must not be blind-pushed"
    rm -rf "$up" "$a" "$b"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-post-container-git.sh`
Expected: FAIL — current `push_changes` does a bare `git push --set-upstream` and would non-ff-reject via git's own error but with exit 1 (acceptable) OR force nothing; assert it returns non-zero *and* logs the divergence reason. If it already returns non-zero, tighten the assertion to check the divergence log line so the test is meaningful.

- [ ] **Step 3: Add fetch + divergence guard** — near the top of `push_changes`, before the push:

```bash
    # Fetch-before-push: detect divergence so we never emit a confusing bare
    # non-ff push (which stranded work as "committed locally, no PR").
    GIT_TERMINAL_PROMPT=0 timeout "${KAPSIS_FETCH_TIMEOUT:-60}" \
        git fetch "$remote" "$remote_branch" 2>/dev/null || true
    if git rev-parse --verify -q "refs/remotes/${remote}/${remote_branch}" >/dev/null 2>&1 \
       || git rev-parse --verify -q "FETCH_HEAD" >/dev/null 2>&1; then
        local _remote_tip _base
        _remote_tip=$(git rev-parse -q --verify FETCH_HEAD 2>/dev/null || git rev-parse "refs/remotes/${remote}/${remote_branch}")
        _base=$(git merge-base HEAD "$_remote_tip" 2>/dev/null || echo "")
        if [[ -n "$_remote_tip" && "$_base" != "$_remote_tip" ]]; then
            log_error "Remote ${remote}/${remote_branch} has advanced beyond our base — refusing non-fast-forward push"
            status_set_push_fallback "$worktree_path" "$remote" "$branch" "$remote_branch"
            status_set_push_info "diverged" "$(git rev-parse HEAD)" "$_remote_tip"
            return 1
        fi
    fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test-post-container-git.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/post-container-git.sh tests/test-post-container-git.sh
git commit -m "fix(host): fetch-before-push; refuse blind non-fast-forward"
```

---

### Task 6: Provider-pluggable post-push PR hook + observability

**Files:**
- Modify: `scripts/launch-agent.sh` (read `git.post_push_hook` from config ~915-920; pass through the `post_container_git` call ~3727)
- Modify: `scripts/post-container-git.sh` `post_container_git()` signature + after verified push invoke the hook; set `pr_hook_status`
- Modify: `scripts/lib/status.sh` — add `status_set_pr_hook_info` (mirror `status_set_push_info`)
- Test: `tests/test-post-container-git.sh` (extend, fake hook)
- Docs: `CONFIG-REFERENCE.md` — document `git.post_push_hook`

**Interfaces:**
- Consumes: config `git.post_push_hook` (string command); env for the hook: `KAPSIS_REMOTE_BRANCH`, `KAPSIS_BASE_BRANCH`, `KAPSIS_PUSHED_SHA`, `KAPSIS_REMOTE_URL`.
- Produces: `run_post_push_hook(worktree, remote_branch, base_branch, pushed_sha, hook_cmd)` → sets `pr_hook_status` ∈ `skipped|ok|failed:<reason>` and `PR_URL` when the hook prints a URL on stdout.

- [ ] **Step 1: Write the failing test**:

```bash
test_post_push_hook_invoked_with_env() {
    local r; r=$(_mk_repo); ( cd "$r"; git remote add origin /dev/null 2>/dev/null || true )
    local out; out=$(mktemp)
    local hook="printf 'BRANCH=%s SHA=%s\n' \"\$KAPSIS_REMOTE_BRANCH\" \"\$KAPSIS_PUSHED_SHA\" > $out; echo https://pr.example/1"
    run_post_push_hook "$r" "feature/x" "main" "deadbeef" "$hook"
    assert_equals "ok" "${pr_hook_status:-}" "hook ok"
    assert_file_contains "$out" "BRANCH=feature/x SHA=deadbeef" "hook got env"
    assert_equals "https://pr.example/1" "${PR_URL:-}" "PR_URL captured from hook stdout"
    rm -rf "$r" "$out"
}
test_post_push_hook_unset_skips() {
    run_post_push_hook "/tmp" "feature/x" "main" "deadbeef" ""
    assert_equals "skipped" "${pr_hook_status:-}" "unset hook = skipped"
}
test_post_push_hook_failure_surfaced() {
    run_post_push_hook "/tmp" "feature/x" "main" "deadbeef" "exit 3"
    assert_matches "${pr_hook_status:-}" "^failed:" "hook failure surfaced, not swallowed"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-post-container-git.sh`
Expected: FAIL — `run_post_push_hook` not defined.

- [ ] **Step 3: Implement `run_post_push_hook`** in `post-container-git.sh`:

```bash
# Provider-agnostic PR creation seam. Runs a user-configured command on the HOST
# after a verified push. kapsis knows nothing about gh/bkt/glab — the command is
# supplied by config. Env values are agent-influenced: passed via env ONLY (never
# interpolated into a shell string); the hook contract requires it to quote and
# never eval. Failures are surfaced via pr_hook_status, never swallowed.
run_post_push_hook() {
    local worktree_path="$1" remote_branch="$2" base_branch="$3" pushed_sha="$4" hook_cmd="$5"
    if [[ -z "$hook_cmd" ]]; then pr_hook_status="skipped"; return 0; fi
    local remote_url; remote_url=$(cd "$worktree_path" && git remote get-url origin 2>/dev/null || echo "")
    local out rc=0
    out=$(cd "$worktree_path" && \
        KAPSIS_REMOTE_BRANCH="$remote_branch" KAPSIS_BASE_BRANCH="$base_branch" \
        KAPSIS_PUSHED_SHA="$pushed_sha" KAPSIS_REMOTE_URL="$remote_url" \
        bash -c "$hook_cmd" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        pr_hook_status="ok"
        local url; url=$(printf '%s\n' "$out" | grep -oE 'https?://[^[:space:]]+' | tail -1 || true)
        [[ -n "$url" ]] && PR_URL="$url"
        return 0
    fi
    pr_hook_status="failed:exit${rc}"
    log_error "post_push_hook failed (exit $rc): $(printf '%s' "$out" | tail -3)"
    return 0   # push already succeeded; do not fail the whole run, but surface status
}
```
Note: the hook command itself comes from trusted config, so `bash -c "$hook_cmd"` is acceptable; the *agent-influenced* values are passed only as env, never concatenated into `hook_cmd`.

- [ ] **Step 4: Wire it after a verified push** — in `push_changes` success branch, replace the bare `show_pr_instructions` call path so that when a hook is configured it runs the hook, else falls back to printing instructions:

```bash
        if verify_push "$worktree_path" "$remote" "$remote_branch"; then
            local _pushed_sha; _pushed_sha=$(git rev-parse HEAD)
            if [[ -n "${KAPSIS_POST_PUSH_HOOK:-}" ]]; then
                run_post_push_hook "$worktree_path" "$remote_branch" "${KAPSIS_BASE_BRANCH:-}" "$_pushed_sha" "$KAPSIS_POST_PUSH_HOOK"
            else
                pr_hook_status="skipped"
                show_pr_instructions "$worktree_path" "$remote_branch"
            fi
            return 0
        else
```

- [ ] **Step 5: Read config + export** — in `launch-agent.sh` near the other `git.auto_push` reads (~917):

```bash
        KAPSIS_POST_PUSH_HOOK=$(yq -r '.git.post_push_hook // ""' "$CONFIG_FILE")
        export KAPSIS_POST_PUSH_HOOK
```
`post_container_git` is sourced in the host shell, so the exported env is visible; no signature change required. (Also export `KAPSIS_BASE_BRANCH="$BASE_BRANCH"` alongside.)

- [ ] **Step 6: Add `status_set_pr_hook_info`** in `scripts/lib/status.sh` (mirror `status_set_push_info`) to persist `pr_hook_status` + `PR_URL` into the status JSON; call it from `push_changes` after the hook.

- [ ] **Step 7: Run tests to verify pass**

Run: `bash tests/test-post-container-git.sh`
Expected: PASS.

- [ ] **Step 8: Document + commit**

Add a `git.post_push_hook` entry to `CONFIG-REFERENCE.md` (string; runs on host after verified push; env `KAPSIS_REMOTE_BRANCH/BASE_BRANCH/PUSHED_SHA/REMOTE_URL`; must quote, must not eval; print the PR URL on stdout to capture it). Then:
```bash
git add scripts/launch-agent.sh scripts/post-container-git.sh scripts/lib/status.sh tests/test-post-container-git.sh CONFIG-REFERENCE.md
git commit -m "feat(host): provider-pluggable post-push PR hook + pr_hook_status observability"
```

---

### Task 7: Full suite + design/plan cross-check

- [ ] **Step 1:** Run the affected suites: `bash tests/test-worktree-incontainer-git.sh && bash tests/test-sanitized-git-objects.sh && bash tests/test-post-container-git.sh`. Expected: all PASS.
- [ ] **Step 2:** Run `bash tests/run-all-tests.sh` (or the worktree/git-tagged subset) to check for regressions in neighbouring worktree/objects/commit tests.
- [ ] **Step 3:** Re-read `designs/2026-08-09-...-design.md` §A–§D and confirm each mechanism has a task. Note any container-only integration behavior (GIT_DIR actually effective for the agent process; egress) that unit tests can't cover, for manual/sandbox verification.
- [ ] **Step 4:** Open a **draft** PR on the kapsis repo (`gh pr create --draft`) referencing the design doc.

## Self-Review

**Spec coverage:** §A → Tasks 1-3; §B(sanitize/case-insensitive/mode) → Task 4; §B(fetch-before-push/fail-closed) → Task 5; §C(post-push hook)+§D(observability) → Task 6; tests/fake-remote → Tasks 4-6 + Task 7. Objects/repoint (§A4) → Task 3 Step 4.
**Placeholder scan:** none — every code step shows the code; commands have expected results.
**Type consistency:** `run_post_push_hook(worktree, remote_branch, base_branch, pushed_sha, hook_cmd)` and `pr_hook_status` values (`skipped|ok|failed:<n>`) are consistent across Task 6 steps and the status helper; `_prepare_objects_alternate(sanitized_dir)` consistent Task 3.
**Known limitation (documented, not a gap):** whether `GIT_DIR` is effective for the *agent* process and container egress are integration concerns exercised only in a real sandbox run, not by these bash unit tests (Task 7 Step 3).
