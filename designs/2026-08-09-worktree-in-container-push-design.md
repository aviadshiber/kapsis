# Worktree-mode in-container push (primary) with fail-closed sanitization

Status: proposed
Date: 2026-08-09
Author: aviad.s (with Claude)

## Problem

In **worktree sandbox mode** (the auto-detected default), in-container git is non-functional,
so the agent cannot commit, push, or open a PR from inside the container. The push only happens
on the host after the container exits (`post-container-git.sh`). Symptoms observed in production
(Slack bot, ticket DEV-230844): the agent reports *"in-container git non-functional — the
worktree pointer references a host path … git status/add/commit/push all fail. I could not commit
or open a PR"*; the host safety net pushes the branch but no PR is opened.

### Root cause (verified on v3.2.4 == origin/main)

`scripts/entrypoint.sh` line 1938:

```bash
if [[ "$sandbox_mode" == "worktree" ]] || setup_worktree_git; then
    # Worktree mode: git is already set up by host   # <- false
```

`setup_worktree_git()` is the only place `export GIT_DIR="$CONTAINER_GIT_PATH"` (the mounted
sanitized `.git-safe`) happens. Because `[[ … == "worktree" ]] ||` short-circuits, the function
is never called in worktree mode → `GIT_DIR` is never set → the agent's git reads
`/workspace/.git` (a worktree pointer to a host path absent in the container) → all git ops fail.
Two further blockers even if `GIT_DIR` were set: the sanitized git is mounted `:ro`, and its
`objects` is a read-only symlink to the parent object DB, so commits have nowhere to write.

Historically, **overlay mode** (legacy) *did* push in-container via a `post_exit_git` EXIT trap
over a writable CoW git — but that path performs **no sanitization** (`git add -A` with no
`.kapsis/` exclusion, no injection strip, no invisible-char scan; those live only host-side). So
"just revive `post_exit_git`" would restore in-container push while silently dropping every
content guardrail.

## Goals

1. Worktree mode commits **and pushes inside the container** as the primary path.
2. Host commit/push becomes a **fallback** (mount drop, in-container finalize didn't complete).
3. **Sanitization always precedes any push**, on both the in-container and host paths.
4. **Fail-closed**: if pushed/about-to-push content is dirty, the run fails (and the host
   remediates the remote branch); never a silent bad push.
5. **Provider-agnostic**: no Bitbucket/GitHub-specific assumptions in the push or sanitization
   path (kapsis is a general sandbox tool). Reuse the repo's own `origin` + env-provided creds.

## Non-goals

- Cryptographic tamper-proofing against a *fully adversarial* agent inside the container. A single
  container is a single trust domain: the agent holds the push token (needed for PR creation), so
  anything the in-container finalize can do, an adversarial agent can replicate. This is out of
  scope by construction; the host backstop (Layer 2) is the authoritative guarantee.
- Changing overlay mode's behavior beyond routing it through the shared sanitization lib.
- Bot / dev-workflow changes (the agent already runs `git push`; it simply starts working).

## Design

### A. Make worktree-mode in-container git writable (plumbing)

1. `entrypoint.sh:1938` — run `setup_worktree_git` in worktree mode so `GIT_DIR` is exported.
   Restructure so the function always runs when `sandbox_mode == worktree` (evaluate it first, or
   split the branch), and fix the misleading "git is already set up by host" comment.
2. `launch-agent.sh` `generate_volume_mounts_worktree` — mount the sanitized git **rw** (drop the
   `:ro` on `${SANITIZED_GIT_PATH}:${CONTAINER_GIT_PATH}`). Objects mount stays `:ro`.
3. `worktree-manager.sh` `prepare_sanitized_git` — replace the read-only `objects` symlink with a
   git **alternate**: a writable local `objects/` dir plus `objects/info/alternates` pointing at
   `$CONTAINER_OBJECTS_PATH`. New objects land locally (writable); existing objects are borrowed
   read-only. Parent object DB is never written.

### B. Shared, provider-agnostic sanitization library

Extract the content-safety logic currently in `post-container-git.sh` into a lib sourced by both
the host and the container:

- `strip_kapsis_injections` (rogue `KAPSIS_GIST` sentinel removal),
- `.kapsis/` staging exclusion,
- `sanitize_staged_files` (dangerous invisible-character scan),
- `build_coauthor_trailers` (attribution),
- a pure `validate_tree`/`validate_commit_range` predicate (no mutation) for gate/backstop use.

Nothing in this lib references a git provider — it operates on *content*, which is universal.

### C. Two-layer enforcement

**Layer 1 — in-container gate (honest / compromised-content agent).**
- The agent pushes normally in-container. A kapsis-installed `pre-push` hook (fail-closed) runs
  `validate_commit_range`; violations → non-zero → push blocked. A companion `pre-commit` may run
  the mutating strip/exclude so commits are clean before they exist (optional ergonomic layer).
- Hooks come from a **kapsis-owned, read-only-mounted** hooks dir referenced via `core.hooksPath`;
  the repo's own `hooks/` is never consulted, so a hook the agent plants during its run **never
  executes** (preserves today's `core.hooksPath=/dev/null` security intent).
- **Integrity scan at finalize** (before trusting the in-container push): assert no rogue hook
  files were planted in the git dir/worktree, `core.hooksPath` was not overridden at
  local/worktree scope, and the sanitization actually ran (success sentinel with pushed SHA +
  remote ref). Any anomaly → do not trust → fall through to Layer 2.

**Layer 2 — authoritative host backstop (fail-closed).**
- Layer 1 is bypassable from inside the container (`git push --no-verify`,
  `git -c core.hooksPath=…`, or a direct authenticated push), so it is not the guarantee. After
  the run, the host re-validates the landed commit with the same shared lib:
  - clean → accept;
  - **dirty or integrity anomaly → fail-closed: the host declines/rolls back the remote branch**
    (delete the just-pushed branch / revert) and marks the run failed.
- The host is also the fallback **pusher** when the in-container push did not happen (sentinel
  absent): it sanitizes (shared lib) then pushes, exactly as today.

### Fallback/skip decision (host)

```
if sentinel present AND remote HEAD == sentinel SHA:
    host re-validates landed commit
        clean         -> accept (in-container push is authoritative)
        dirty/anomaly -> FAIL-CLOSED: rollback remote branch + fail run
else:                       # in-container push didn't happen
    host sanitizes + pushes (fallback)  # fail-closed on sanitization failure
```

## Security / threat model

- **Real threat covered:** prompt-injection or a bug causing the *honest* agent to write bad
  content (rogue injections, invisible chars, `.kapsis/` leakage). Layer 1 blocks it in-container;
  Layer 2 catches anything that slips (including client-side hook bypass) and fails closed.
- **Explicitly not covered in-container:** a fully adversarial agent with the push token. Only the
  host (outside the container's trust domain) is authoritative — hence Layer 2 is mandatory, not
  optional.
- Writable surface is limited to the throwaway per-agent sanitized git dir; the parent object DB
  stays read-only (alternates). Push credentials and network are unchanged from today.

## Testing

Extend `tests/test-post-container-git.sh` and `tests/test-sanitized-git-objects.sh`; add cases:
- worktree in-container git is writable: `GIT_DIR` set, `git commit` succeeds, new objects land in
  the local objects dir; parent objects dir remains read-only.
- Layer 1 `pre-push` rejects a commit containing `.kapsis/` paths / a rogue `KAPSIS_GIST` block /
  invisible chars; accepts a clean commit.
- agent-planted repo hook does not execute; `core.hooksPath` override at local scope is detected.
- host fallback: sentinel absent → host sanitizes + pushes.
- host backstop fail-closed: dirty landed commit → host rolls back branch + run fails.
- provider-agnostic: push path uses the repo's own `origin`, no hardcoded host.

## Rollout

- Land on `main`; cut a patch release. The Slack bot runs the Homebrew build (currently 3.2.4), so
  it picks this up via `kapsis --upgrade` + `restart-bot.sh` after release.
- The `entrypoint.sh:1938` short-circuit + the false comment are present on `main` too — this fix
  targets both.

## Open questions

1. Layer 1 granularity: `pre-push` validate only, or add the `pre-commit` auto-strip? (Leaning
   pre-push-only first; add auto-strip if reject-and-retry UX is annoying.)
2. Rollback mechanism for Layer 2: delete the remote branch vs push a revert. Delete is simplest
   when the branch was created by this run; revert is safer if the branch pre-existed.
