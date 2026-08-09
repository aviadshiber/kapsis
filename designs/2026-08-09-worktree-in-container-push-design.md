# Worktree-mode in-container push (primary) with fail-closed sanitization

Status: proposed (v2 — revised after ensemble review 2026-08-09)
Date: 2026-08-09
Author: aviad.s (with Claude)

## Problem

In **worktree sandbox mode** (the auto-detected default), in-container git is non-functional, so
the agent cannot commit, push, or open a PR from inside the container. The push only happens on the
host after the container exits (`post-container-git.sh`). Production symptom (Slack bot, DEV-230844):
the agent reports *"in-container git non-functional … git status/add/commit/push all fail. I could
not commit or open a PR"*; the host safety net pushes the branch but **no PR is opened**.

### Root cause (verified against v3.2.4 == origin/main)

`scripts/entrypoint.sh:1938`:

```bash
if [[ "$sandbox_mode" == "worktree" ]] || setup_worktree_git; then
```

`setup_worktree_git()` is the only place `export GIT_DIR="$CONTAINER_GIT_PATH"` (the mounted
sanitized `.git-safe`) happens (entrypoint.sh:780). `[[ … == "worktree" ]] ||` short-circuits, so it
is never called in worktree mode → `GIT_DIR` unset → the agent's git reads `/workspace/.git` (a
worktree pointer to a host path absent in the container) → all git ops fail. Two further blockers:
the sanitized git is mounted `:ro` (launch-agent.sh:1598) and its `objects` is a read-only symlink to
the parent object DB (worktree-manager.sh:526), so commits have nowhere to write.

Historically, **overlay mode** pushed in-container via a `post_exit_git` EXIT trap over a writable
CoW git — but that path does a bare `git add -A` with **no sanitization** (entrypoint.sh:1118); the
guardrails (`strip_kapsis_injections`, `.kapsis/` exclusion, `sanitize_staged_files`,
`build_coauthor_trailers`) live only host-side in `post-container-git.sh`.

**Correction (ensemble claim-verifier):** worktree mode does **not** disable hooks via
`core.hooksPath=/dev/null` today — that is gated behind `KAPSIS_DISABLE_HOOKS=true` in the overlay
path only. What actually prevents hooks in worktree mode today is the **empty, `:ro` hooks dir**
(worktree-manager.sh:484). This matters: making the git dir writable (below) would let an
agent-planted hook execute unless we handle it explicitly.

## Goals

1. Worktree mode commits and **pushes inside the container** as the primary path.
2. Host commit/push becomes a **fallback** (in-container finalize didn't run / push didn't land).
3. **Sanitization (mutating) always precedes any push**, on both paths.
4. **Fail-closed**: any content that lands on the remote is validated by a component the agent
   cannot bypass; dirty content → run fails and the remote is remediated. Never a silent bad push.
5. **Provider-agnostic**: no hardcoded git provider in kapsis core. Reuse the repo's own `origin`
   and the container's configured credentials; PR creation is delegated (see §E).

## Non-goals

- Cryptographic tamper-proofing against a *fully adversarial* agent inside the container. A single
  container is one trust domain; the authoritative guarantee is the **host** re-validation (§D),
  outside the container.
- Hardcoding PR creation for any provider (delegated to a post-push hook, §E).

## Design

### Pivot (post-ensemble): kapsis finalize pushes; the agent never pushes

The agent only **edits files** (and may commit locally). It has **no push credentials during its
run**. After the agent exits, a kapsis-controlled **in-container finalize** step (an EXIT-trap,
registered in worktree mode too) performs the mutating sanitization, the canonical commit, and the
push. This closes the ensemble's three soundness holes at once: the mutating gist-strip runs
in-container before the pushed commit (Goal 3), there is no client-side hook to bypass, and
credentials exist only in the finalize phase.

### A. Make worktree-mode in-container git writable (plumbing)

1. `entrypoint.sh:1938` — run `setup_worktree_git` in worktree mode so `GIT_DIR` is exported
   (restructure so the function always runs when `sandbox_mode == worktree`); fix the false
   "git is already set up by host" comment.
2. `launch-agent.sh` `generate_volume_mounts_worktree` — mount the sanitized git **rw**.
3. `worktree-manager.sh` `prepare_sanitized_git` — writable local `objects/` + `objects/info/alternates`
   → `$CONTAINER_OBJECTS_PATH` (parent DB borrowed read-only; new objects land locally). Push
   negotiates the object delta over the wire, so a missing `refs/remotes/origin/<branch>` does not
   break push (confirmed by review).
   - **Objects/repoint impact (ensemble C3):** the host `repoint_sanitized_git_objects()`
     (launch-agent.sh:3635-3667) currently rewrites the RO symlink to the host path for host use. The
     host **fallback** operates on the **real worktree gitdir** (not the sanitized dir), so it does
     not depend on the sanitized dir's objects; update/retire `repoint_*` accordingly and cover with
     tests (§Testing). The sanitized dir's alternate is validated at finalize (no agent-added
     alternates; §Security).

### B. Shared, provider-agnostic, self-contained sanitization library

Extract into a lib sourced by both host and container. It must be **self-contained in-container** —
no host-only deps (`$TMPDIR`, host provenance):
- `strip_kapsis_injections` (mutating — removes kapsis's own `KAPSIS_GIST` block and rogue variants),
- `.kapsis/` + `.git-safe/` + `.git-objects/` staging exclusion — **case-insensitive** (APFS),
- `sanitize_staged_files` (invisible-char scan; reject on unfixable),
- `build_coauthor_trailers`,
- `validate_range <base>..<tip>` — a pure predicate over an **explicit commit range** (never whole
  history) used by the host backstop.

### C. In-container finalize (primary path)

Registered as an EXIT trap in worktree mode; runs after the agent process exits:
1. `git reset --soft <base>` to drop any agent commits, so the pushed commit is kapsis-authored and
   clean regardless of what the agent staged/committed.
2. Mutating sanitize on the working tree/index: `strip_kapsis_injections`, exclude `.kapsis/` etc.,
   `sanitize_staged_files` (**fail-closed** on unfixable content — abort finalize, leave to host).
3. Canonical commit (kapsis message + co-author trailers), **hooks disabled explicitly**
   (`-c core.hooksPath= --no-verify`), so no agent-planted hook runs.
4. Configure credentials **ephemerally** (§F), then `git push` the refspec.
5. On success: write a sentinel (pushed SHA + remote ref — an *optimization hint*, not proof), then
   invoke the optional **post-push hook** (§E). Finally scrub credentials (§F).

The agent's own `git push` cannot reach the remote during its run (no credentials), so it fails fast
and locally; dev-workflow guidance will note that kapsis finalizes the push.

### D. Host: always-revalidate backstop + reconciling fallback (fail-closed)

The host runs after the container exits. It does **not** trust the sentinel as a gate — it inspects
the **actual remote state**:

```
git fetch origin <remote_branch>
if remote has commits beyond the pre-run tip (i.e. something landed):
    validate_range <pre_run_tip>..<remote_tip>        # FULL range, every commit
        clean   -> accept (in-container push authoritative)
        dirty   -> FAIL-CLOSED remediate (see below) + fail run
    if sentinel present but remote_tip != sentinel SHA -> ANOMALY -> treat as dirty
else:                                                  # nothing landed in-container
    host fallback: sanitize(mutate) worktree + commit + fetch/reconcile + push
        (fetch-before-push; if remote diverged, do NOT blind-push a divergent SHA — reconcile or fail)
```

**Fail-closed remediation, provenance-based, with compare-and-swap (ensemble H2/C1):**
- branch **created by this run** → delete the remote branch **only if** its tip still equals the SHA
  we pushed (`git push --force-with-lease=<ref>:<pushed_sha> origin :<ref>` semantics);
- branch **pre-existed** → restore to the pre-run tip **only if** the current tip equals the SHA we
  pushed (`--force-with-lease`); if it advanced (concurrent legit push), do **not** clobber — fail
  the run and alert.
- Provenance (`created_by_run` bool) and the pre-run remote SHA are captured at worktree setup and
  persisted host-side (status JSON), since `create_worktree` only logs them today.

This makes Layer-2 validation **unconditional** over the full landed range and rollback **safe under
concurrency** — the two holes the ensemble flagged as CRITICAL.

### E. PR creation — provider-pluggable post-push hook (delegated)

kapsis does not create PRs. After a successful push, the finalize (and the host fallback) invoke an
**optional** user-configured command, e.g. `git.post_push_hook` in the agent config, with env
(`KAPSIS_REMOTE_BRANCH`, `KAPSIS_BASE_BRANCH`, pushed SHA). The Slack bot config supplies its
`bkt/gh pr create` command; unset = no PR (today's behavior). Provider logic stays entirely in
user config.

### F. Credential hygiene (ensemble H5)

- Push credentials are present **only** during the finalize push (and host fallback), never during
  the agent's run.
- Never persist an auth-embedded URL into the sanitized/worktree git config; use an ephemeral
  credential helper / `GIT_CONFIG_COUNT` env or `-c credential.helper=…` scoped to the push
  invocation; unset afterward.
- Keep the token out of the sentinel, reflog, and captured logs (push with `--quiet`, no
  `set -x`, redact URLs in logs).

## Security / threat model

- **Covered:** an *honest* agent whose content got compromised (prompt-injection writing rogue
  `KAPSIS_GIST` / invisible chars / `.kapsis/` leakage). The finalize mutating-strip removes it
  before the pushed commit; the host re-validates the full landed range and fails closed on anything
  dirty — including a bypass push, because host validation is unconditional on remote state.
- **Not covered in-container:** a fully adversarial agent with the push token. But the agent has
  **no token during its run** (§F), and the **host** (outside the container) is the authoritative
  validator/remediator — so even a token exfiltrated from the finalize phase cannot land unvalidated
  content without the host catching and rolling it back.
- Writable `$GIT_DIR`: hooks are disabled during finalize (§C); the agent-run keeps the empty hooks
  dir and we do not rely on a client-side hook as a gate. `objects/info/alternates` is validated at
  finalize (exactly one expected alternate; reject others). Parent-history exposure via the RO
  objects mount is inherent to worktree mode today (unchanged).
- Layer-2 is a **validate-and-remediate** backstop; it rejects/rolls back, it does not "repair"
  (wording corrected from v1).

## Testing

Add a **fake-remote harness** (a local bare repo as `origin`) so in-container finalize push and host
backstop are testable without a real provider. Extend `tests/test-post-container-git.sh` and
`tests/test-sanitized-git-objects.sh`:
- worktree in-container git writable: `GIT_DIR` set, commit succeeds, new objects in local objects
  dir; parent objects dir stays read-only; alternates has exactly the expected entry.
- finalize mutating-strip removes an injected `KAPSIS_GIST` block from `CLAUDE.md`; excludes
  `.kapsis/` (incl. `.KAPSIS/` on case-insensitive FS); rejects invisible chars (fail-closed).
- finalize push lands on the fake remote; sentinel written; post-push hook invoked with correct env;
  credentials absent from config/reflog/logs afterward.
- host backstop: dirty landed commit → fail-closed rollback via `--force-with-lease`; concurrent
  advance (tip ≠ pushed SHA) → does NOT clobber, run fails.
- host fallback (in-container push didn't land): fetch-before-push; divergent remote → no blind
  non-ff push.
- validate range bounded to `base..tip` (no whole-history scan) incl. first-push (no remote branch).
- provider-agnostic: push uses the repo's own `origin`; no hardcoded host; post-push hook unset = no
  PR, run still succeeds.

## Rollout

- Land on `main`; cut a patch release. The Slack bot runs the Homebrew build (currently 3.2.4); it
  picks this up via `kapsis --upgrade` + `restart-bot.sh`.
- Back-compat: document behavior for in-flight worktrees created by the old version at upgrade time.
- Network: the git host must be in the agent's egress allowlist for in-container push (already true
  for the bot; note for general users).

## Resolved decisions

1. **Pivot adopted:** kapsis in-container **finalize pushes**; the agent never pushes (no creds in
   its run). Replaces v1's "agent pushes."
2. **Sanitization is mutating, in-container, before the pushed commit** (finalize strip/exclude).
   Replaces v1's "pre-push validate-only" (which would fail every `CLAUDE.md` run due to kapsis's own
   gist injection).
3. **Layer-2 host backstop is unconditional** over the full landed range (sentinel is a hint, not a
   trigger); **rollback uses compare-and-swap** (`--force-with-lease`) and is provenance-based
   (delete if run-created, else restore to pre-run tip; never clobber a concurrent advance).
4. **PR creation** stays out of kapsis core — delegated to an optional provider-pluggable
   **post-push hook** (bot config supplies `bkt/gh`).

## Ensemble review log (2026-08-09)

Addressed: C1 unconditional full-range host re-validation (§D); C2 mutating in-container strip (§C);
C3 objects/repoint handling (§A); H1 fetch-before-push fallback (§D); H2 CAS rollback (§D); H3 hooks
handled via finalize-disable + no client-side gate (§C/Security); H4 post-push PR hook (§E); H5
credential hygiene (§F); plus medium items: fake-remote harness, self-contained shared lib,
case-insensitive exclusion, bounded validate range, egress note, alternates validation, over-claim
wording.
