# Worktree-mode in-container push (primary) with fail-closed sanitization

Status: proposed (v3 — architecture B, after two ensemble rounds 2026-08-09)
Date: 2026-08-09
Author: aviad.s (with Claude)

> Title retained for continuity. **v3 changes the architecture:** in-container git becomes usable by
> the agent for **commit / diff / verify**, but the credentialed **push + PR + validation happen on
> the host** — see "Architecture decision" below for why the literal in-container push was dropped.

## Problem

In **worktree sandbox mode** (the auto-detected default), in-container git is non-functional: the
agent cannot commit, diff, verify, or open a PR from inside the container. Production symptom (Slack
bot, DEV-230844): the agent reports *"in-container git non-functional … git status/add/commit/push
all fail. I could not commit or open a PR"*; the host safety net pushes the branch but **no PR is
opened**, so the user sees a failed `/dev` run.

### Root cause (verified against v3.2.4 == origin/main)

`scripts/entrypoint.sh:1938`:

```bash
if [[ "$sandbox_mode" == "worktree" ]] || setup_worktree_git; then
```

`setup_worktree_git()` is the only place `export GIT_DIR="$CONTAINER_GIT_PATH"` (the mounted
sanitized `.git-safe`) happens (entrypoint.sh:780). The `[[ … == "worktree" ]] ||` short-circuits, so
it is never called in worktree mode → `GIT_DIR` unset → the agent's git reads `/workspace/.git` (a
worktree pointer to a host path absent in the container) → all git ops fail. Two further blockers:
the sanitized git is mounted `:ro` (launch-agent.sh:1598) and its `objects` is a read-only symlink to
the parent object DB (worktree-manager.sh:526), so commits have nowhere to write.

## Architecture decision (why host-side push, not in-container)

Two ensemble rounds evaluated a pivot that pushed from inside the container via a post-agent-exit
finalize. Two independent, verified findings killed the literal in-container **push**:

1. **It can't fire on the failure modes we're fixing.** A post-exit finalize can't run when the
   liveness monitor **SIGKILLs PID 1** (SIGKILL tears down the PID namespace) or when the
   **virtio-fs mount drops** (the filesystem is gone). DEV-230844 — the motivating incident — *was* a
   liveness SIGKILL. (Also: an EXIT trap never runs because `entrypoint.sh:2053` `exec "$@"` replaces
   the shell; overlay's `post_exit_git` trap has been dead for the same reason, so "overlay pushed
   in-container" was never actually true.)
2. **Consequence:** because the in-container push can't cover those cases, a fully-capable **host**
   push + PR + validate path must exist regardless. An in-container credentialed push would then be
   an unreliable, harder-to-secure **duplicate** of a host path we're forced to build anyway (and
   running a credentialed push inside a container the agent controlled adds credential-exfil surface
   — a defense-in-depth concern beyond our honest-agent threat model).

**Decision (B):** make in-container git **writable so the agent can commit / diff / verify** (this
fixes the reported dead-git symptom), and do the credentialed **push + PR + validation on the host**,
where creds live safely and the code always runs. This does **not** push from inside the container.

## Goals

1. The agent has **working git inside the container** (status/diff/add/commit/log) for its own
   workflow and verification. No dead-git.
2. The host reliably **commits the final worktree state, sanitizes, validates, pushes, and triggers
   PR creation** — every worktree-mode `/dev` run ends with a pushed branch and (if configured) a PR.
3. **Sanitization + validation always precede the push**, fail-closed: unfixable/unexpected content
   → do **not** push, fail the run (nothing lands, so no rollback needed).
4. **Provider-agnostic**: reuse the repo's own `origin` + host credentials; PR creation delegated to
   an optional user-configured post-push hook.

## Non-goals

- Pushing from inside the container (dropped — see Architecture decision).
- PR creation logic in kapsis core (delegated to the post-push hook).
- Defending against a fully adversarial in-container agent (honest-but-content-compromised is the
  threat model; the host is outside the agent's trust domain and is authoritative).

## Design

### A. Writable in-container git (for the agent's commit/diff/verify)

1. `entrypoint.sh:1938` — run `setup_worktree_git` in worktree mode so `GIT_DIR="/workspace/.git-safe"`
   is exported (restructure so the function runs whenever `sandbox_mode == worktree`); fix the false
   "git is already set up by host" comment.
2. `launch-agent.sh` `generate_volume_mounts_worktree` — mount the sanitized git **rw** so the agent
   can stage/commit locally. Objects mount stays `:ro`.
3. `worktree-manager.sh` `prepare_sanitized_git` — writable local `objects/` + `objects/info/alternates`
   → `$CONTAINER_OBJECTS_PATH` (parent DB borrowed read-only; new objects land locally), replacing
   the read-only symlink, so in-container `git commit` works.
4. The sanitized git config has **no credential helper** (unchanged) and kapsis injects no push
   creds into it → the agent's git works locally but cannot push. The agent's commits live in the
   ephemeral sanitized GIT_DIR and are for its own use; the **authoritative** commit is the host's
   (from the final worktree file state), so nothing depends on the agent's commits surviving.

### B. Host: sanitize → validate → commit → push → PR (hardened `post-container-git.sh`)

The host path already commits+pushes from the real worktree gitdir. Harden it:

1. **Mutating sanitize** (existing `strip_kapsis_injections`, `.kapsis/`/`.git-safe/`/`.git-objects/`
   exclusion, `sanitize_staged_files`) — make the exclusion **case-insensitive** (the container runs
   on a case-sensitive Linux FS, so `.Kapsis/` created in-container is a distinct path today's
   case-sensitive `grep '^\.kapsis/'` / `:(exclude).kapsis/` would miss and push).
2. **Clean tree, don't inherit a crafted index** — build the committed tree only from the sanitized
   worktree (rebuild the index rather than trusting whatever index state exists), and **validate file
   modes**: reject unexpected symlinks (`120000`), gitlinks/`.gitmodules` (`160000`), and exec-bit
   flips on non-scripts. (Ensemble: `git add`/index can smuggle mode entries past a content-only
   sanitizer — real on the host path too.)
3. **Fail-closed**: if sanitize/validate finds unfixable/unexpected content → do **not** push; fail
   the run with a clear reason. Because the host is the sole pusher and validates *before* pushing,
   nothing dirty ever lands → no rollback / CAS / force-with-lease required.
4. **Fetch-before-push / reconcile** — replace the bare `git push --set-upstream`
   (post-container-git.sh:845) with fetch + non-fast-forward handling; never blind-push a divergent
   SHA (avoids the "committed locally, push rejected, no PR" failure).
5. **Post-push PR hook** (§C) after a verified push.

### C. PR creation — provider-pluggable host-side post-push hook

kapsis does not create PRs. After a verified push, the host invokes an **optional** user-configured
command, e.g. `git.post_push_hook` in the agent config, with env (`KAPSIS_REMOTE_BRANCH`,
`KAPSIS_BASE_BRANCH`, pushed SHA). Runs **on the host** (creds host-side; not in the agent
container). The Slack bot config supplies its `bkt`/`gh pr create` command; unset = no PR (today's
behavior). **Hook-failure handling:** a failed hook is surfaced (status + non-zero run outcome / a
clear "pushed but PR-creation failed: <reason>" message), never silently swallowed — otherwise the
original "branch pushed, no PR" symptom returns invisibly. Env values are agent-influenced → the hook
contract requires callers to quote and never `eval`; kapsis passes values via env only, never builds
a shell string.

### D. Observability

Status records which path/outcome occurred: `commit_status`, `push_status`, and a new
`pr_hook_status` (skipped / ok / failed:<reason>) + the resulting PR URL when the hook emits one, so
the bot/user can see whether the run truly produced a PR.

## Security / threat model

- **Threat covered:** honest agent, content compromised (prompt-injection writing rogue
  `KAPSIS_GIST` / invisible chars / `.kapsis/` leakage / crafted file modes). The **host** sanitizes
  and validates before pushing; nothing dirty lands. The host is outside the container's trust
  domain and always runs.
- Writable in-container git only affects the throwaway per-agent sanitized dir; parent objects stay
  read-only (alternates). No push credentials are placed in the container. The credentialed push and
  PR hook run on the host, so the in-container-exfil surface of a credentialed push is avoided
  entirely.
- `objects/info/alternates` is validated host-side before the host reads objects (exactly one
  expected entry; reject symlinked/relative/extra entries).

## Testing

Extend `tests/test-post-container-git.sh`, `tests/test-sanitized-git-objects.sh`; add a fake-remote
harness (local bare repo as `origin`) for push/PR-hook coverage:
- worktree in-container git writable: `GIT_DIR` set, `git commit` succeeds, new objects in local
  objects dir; parent objects dir stays read-only; alternates has exactly the expected entry.
- host sanitize removes an injected `KAPSIS_GIST` block; excludes `.kapsis/` incl. `.Kapsis/`
  (case-insensitive); rejects invisible chars (fail-closed → no push).
- host validate rejects a staged symlink / gitlink / exec-bit-flip (fail-closed → no push).
- host fetch-before-push: divergent remote → reconcile / no blind non-ff push.
- post-push hook: invoked with correct env on success; unset = no PR, run still succeeds; hook
  failure → `pr_hook_status=failed` + non-silent surfacing.
- provider-agnostic: push uses the repo's own `origin`; no hardcoded host.

## Rollout

- Land on `main`; cut a patch release. The Slack bot runs the Homebrew build (currently 3.2.4); it
  picks this up via `kapsis --upgrade` + `restart-bot.sh`, and its config gains a `post_push_hook`
  invoking `bkt/gh pr create`.
- Back-compat: in-flight worktrees from the old version still get host commit+push at upgrade.
- Network: the git host must be in the agent's egress allowlist (already true for the bot) — though
  in B only in-container *read/commit* needs it locally; push is host-side.

## Resolved decisions

1. **Architecture B:** writable in-container git for the agent's commit/diff/verify; credentialed
   **push + PR + validation on the host**. (Reverses the earlier in-container-push pivot after two
   ensemble rounds showed it can't fire on SIGKILL/mount-drop and would duplicate a mandatory host
   path.)
2. **Fail-closed = don't push** (host validates before pushing); no rollback/CAS/force-with-lease.
3. **PR creation** delegated to an optional provider-pluggable **host-side** post-push hook; failures
   surfaced, never silent.
4. Host hardening carried over from the review regardless of architecture: clean-index/mode
   validation, case-insensitive `.kapsis` exclusion, fetch-before-push, alternates validation.

## Ensemble review log (2026-08-09, 2 rounds)

Round 1 (v1→v2): C1 unconditional validation, C2 mutating strip, C3 objects, H1 fetch-before-push,
H2 CAS rollback, H3 hooks, H4 PR hook, H5 creds, plus mediums. Round 2 (v2 re-review): confirmed C1/
C2/H1 resolved; found the finalize-EXIT-trap is dead (`exec`), SIGKILL/mount-drop defeat in-container
finalize, and credentialed-push-in-container exfil surface → **architecture pivot to B**. Surviving
hardening folded into §B (clean index + mode validation; fetch-before-push; case-insensitive
exclusion; alternates validation). Rollback/CAS/force-with-lease **removed** as unnecessary under B.
