# Kapsis Git Workflow Guide

The git workflow enables AI agents to push changes to branches for PR-based review, supporting iterative feedback loops.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     GIT BRANCH LIFECYCLE WORKFLOW                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 1: LAUNCH WITH --branch feature/DEV-123                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 2: GIT INITIALIZATION (at container start)                    │   │
│  │                                                                     │   │
│  │   git fetch origin                                                  │   │
│  │                                                                     │   │
│  │   if remote branch exists:                                          │   │
│  │       git checkout -b feature/DEV-123 origin/feature/DEV-123        │   │
│  │       "Continuing from existing remote branch"                      │   │
│  │   else:                                                             │   │
│  │       git checkout -b feature/DEV-123                               │   │
│  │       "Created new branch from current HEAD"                        │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 3: AGENT WORKS                                                │   │
│  │                                                                     │   │
│  │   - Reads spec file (/task-spec.md)                                 │   │
│  │   - Makes code changes                                              │   │
│  │   - Can run builds, tests, etc.                                     │   │
│  │   - Changes go to overlay upper layer                               │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 4: AGENT EXITS → POST-EXIT GIT OPERATIONS                     │   │
│  │                                                                     │   │
│  │   if changes exist:                                                 │   │
│  │       git add -A                                                    │   │
│  │       git commit -m "feat: {task_summary}"                          │   │
│  │       if --push specified:                                          │   │
│  │           git push origin feature/DEV-123 --set-upstream            │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 5: USER REVIEWS PR                                            │   │
│  │                                                                     │   │
│  │   - Review on GitHub/GitLab/Bitbucket                               │   │
│  │   - Approve → Merge → Done                                          │   │
│  │   - Request changes → Continue to Phase 6                           │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                         (if changes requested)                              │
│                                │                                            │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ PHASE 6: FEEDBACK LOOP — Update spec and re-run                     │   │
│  │                                                                     │   │
│  │   # Update spec with PR feedback                                    │   │
│  │   vim ./specs/task.md                                               │   │
│  │   # Add: "PR Feedback: Handle null case gracefully"                 │   │
│  │                                                                     │   │
│  │   # Re-launch — agent continues from remote branch state!           │   │
│  │   ./launch-agent.sh ~/project \                                   │   │
│  │       --branch feature/DEV-123 \                                    │   │
│  │       --spec ./specs/task.md                                        │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                │                                            │
│                                ▼                                            │
│                        (repeat until approved)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## SSH Host Key Setup

Kapsis automatically verifies SSH host keys to protect against MITM attacks when pushing to Git remotes.

### Public Git Providers (Automatic)

For these providers, SSH host keys are verified automatically against official APIs:
- **GitHub** (`github.com`)
- **GitLab** (`gitlab.com`)
- **Bitbucket Cloud** (`bitbucket.org`)

No setup required.

### Enterprise Git Servers (One-Time Setup)

For self-hosted or enterprise Git servers (e.g., GitHub Enterprise, GitLab self-hosted, Bitbucket Server), you need to add the host once:

```bash
# Add your enterprise Git server (interactive verification)
./scripts/lib/ssh-keychain.sh add-host git.company.com

# The script will:
# 1. Scan the server's SSH host key
# 2. Display the fingerprint for verification
# 3. Ask you to confirm (verify with your IT admin if unsure)
# 4. Store the fingerprint securely
```

**Example:**
```bash
$ ./scripts/lib/ssh-keychain.sh add-host git.company.com
Enterprise host detected: git.company.com
No official fingerprint source available.

SSH Host Key Fingerprints for git.company.com:
============================================
  ssh-rsa: SHA256:abc123...
============================================

IMPORTANT: Verify these fingerprints with your IT administrator!
Do you trust this host? (yes/no): yes
Added custom host: git.company.com -> SHA256:abc123...
```

**List configured hosts:**
```bash
./scripts/lib/ssh-keychain.sh list-hosts
```

Keys are cached securely in:
- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet (or `~/.kapsis/ssh-cache/` as fallback)

See [docs/NETWORK-ISOLATION.md](NETWORK-ISOLATION.md#ssh-host-key-verification) for technical details.

## Basic Usage

### New Feature Branch

```bash
# Create spec file
cat > specs/add-user-endpoint.md << 'EOF'
# Task: Add User Preferences Endpoint

## Requirements
- Add GET /api/users/{id}/preferences
- Add PUT /api/users/{id}/preferences
- Store in PostgreSQL

## Acceptance Criteria
- [ ] Proper JSON responses
- [ ] Input validation
- [ ] Unit tests with >80% coverage
EOF

# Launch agent with new branch
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-123-user-preferences \
    --spec ./specs/add-user-endpoint.md
```

### Branch from Specific Base (Fix #116)

When your repository uses a specific tag or branch as the stable base (e.g., `stable/trunk`), use `--base-branch` to ensure new branches start from the correct point:

```bash
# Create branch from a specific tag
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-123-user-preferences \
    --base-branch stable/trunk \
    --spec ./specs/add-user-endpoint.md

# Create branch from a release tag
./scripts/launch-agent.sh ~/project \
    --branch hotfix/PROD-456 \
    --base-branch v2.5.0 \
    --spec ./specs/hotfix.md

# Create branch from another branch
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-789 \
    --base-branch develop \
    --spec ./specs/feature.md
```

Without `--base-branch`, new branches are created from the current HEAD of the main repository, which may not be the intended base. This can cause PRs to show incorrect diffs.

### Different Local and Remote Branch Names

When the remote branch has a different name than your local branch (e.g., CI systems or naming conventions that differ), use `--remote-branch`:

```bash
# Local branch "my-feature" pushes to remote branch "claude/my-feature-abc123"
./scripts/launch-agent.sh ~/project \
    --branch my-feature \
    --remote-branch claude/my-feature-abc123 \
    --spec ./specs/task.md

# Continue working on an existing remote branch with a different local name
./scripts/launch-agent.sh ~/project \
    --branch dev-work \
    --remote-branch feature/DEV-456-api-refactor \
    --push \
    --spec ./specs/refactor.md
```

Without `--remote-branch`, the local branch name is used for both local and remote operations (default behavior).

### Continue Existing Branch

```bash
# After PR review feedback, update spec
cat >> specs/add-user-endpoint.md << 'EOF'

## PR Feedback (Review 1)
- Handle null preferences gracefully
- Add rate limiting to PUT endpoint
EOF

# Re-launch with same branch — continues from remote state
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-123-user-preferences \
    --spec ./specs/add-user-endpoint.md
```

### Auto-Generated Branch

```bash
# Let Kapsis generate branch name
./scripts/launch-agent.sh ~/project \
    --auto-branch \
    --spec ./specs/fix-tests.md

# Creates: ai-agent/fix-tests-20241214-153052
```

### Local-Only Commits

```bash
# Default: commit but don't push (for review before push)
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-123 \
    --spec ./specs/task.md

# With auto-push enabled
./scripts/launch-agent.sh ~/project \
    --branch feature/DEV-123 \
    --push \
    --spec ./specs/task.md

# Push manually after review
cd ~/project
git push origin feature/DEV-123
```

## Spec File Best Practices

### Structure

```markdown
# specs/feature-DEV-1234.md

## Task Summary
One-line description (used for commit message)

## Context
- What problem are we solving?
- Link to ticket: https://jira.company.com/DEV-1234
- Related PRs or documentation

## Requirements
- Detailed requirement 1
- Detailed requirement 2

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Technical Guidance
- Use existing patterns in X
- Don't modify Y
- Performance requirement: Z

## PR Review Feedback
### Review 1 (2024-12-14)
- Handle null case
- Add validation

### Review 2 (2024-12-15)
- Fix typo in error message
```

### Tips

1. **Be Specific**: Vague specs lead to vague implementations
2. **Reference Existing Code**: Point to patterns to follow
3. **Include Constraints**: What NOT to do is as important as what to do
4. **Append Feedback**: Don't remove previous spec content, append review feedback

## Parallel Agents with Branches

### Different Components

```bash
# Run multiple agents on same project, different branches
./scripts/launch-agent.sh ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-backend \
    --spec ./specs/backend.md &

./scripts/launch-agent.sh ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-frontend \
    --spec ./specs/frontend.md &

./scripts/launch-agent.sh ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-tests \
    --spec ./specs/tests.md &

wait

echo "All agents complete. PRs ready for review."
```

### Same Task, Different Agents

```bash
# Compare different AI agents on same task
./scripts/launch-agent.sh claude ~/project \
    --config configs/claude.yaml \
    --branch experiment/refactor-claude \
    --spec ./specs/refactor.md &

./scripts/launch-agent.sh codex ~/project \
    --config configs/codex.yaml \
    --branch experiment/refactor-codex \
    --spec ./specs/refactor.md &

wait

# Compare the two approaches via PR review
```

## Commit Message Format

Default commit message template:

```
feat: {task_summary}

Generated by Kapsis AI Agent Sandbox v{version}
https://github.com/aviadshiber/kapsis
Agent ID: {agent_id}
Worktree: {worktree_name}

Co-authored-by: Aviad Shiber <aviadshiber@gmail.com>
```

Customize in config:

```yaml
git:
  auto_push:
    commit_message: |
      feat: {task}

      Generated by {agent} via Kapsis
      Ticket: DEV-{branch_number}

  # Co-authors added to every commit (Git trailer format)
  # Automatically deduplicated against git config user.email
  co_authors:
    - "Aviad Shiber <aviadshiber@gmail.com>"
    - "Another Author <another@example.com>"
```

## Fork Workflow for Open Source Contributions

When contributing to repositories where you don't have push access, Kapsis provides a fork-first workflow fallback.

### Configuration

```yaml
git:
  fork_workflow:
    enabled: true    # Enable fork fallback
    fallback: fork   # "fork" or "manual"
```

### How It Works

1. **Agent makes changes** and commits locally
2. **Push to origin fails** (no access to upstream repo)
3. **Kapsis detects GitHub repo** and generates fork fallback:

```
┌────────────────────────────────────────────────────────────────────┐
│ FORK WORKFLOW FALLBACK                                             │
└────────────────────────────────────────────────────────────────────┘
KAPSIS_FORK_FALLBACK: cd /path/to/worktree && gh repo fork owner/repo --remote --remote-name fork && git push -u fork feature/branch

This command will:
  1. Fork the repository to your GitHub account
  2. Add the fork as a remote named 'fork'
  3. Push your branch to the fork

Then create a PR at:
  https://github.com/owner/repo/compare/main...YOUR_USERNAME:feature/branch?expand=1
```

### Orchestrating Agent Integration

Orchestrating agents can grep for `KAPSIS_FORK_FALLBACK:` in output and execute the command from the host where GitHub CLI (`gh`) is authenticated:

```bash
# Extract and run the fork fallback
fork_cmd=$(grep "KAPSIS_FORK_FALLBACK:" output.log | sed 's/KAPSIS_FORK_FALLBACK: //')
eval "$fork_cmd"
```

## PR URL Generation

Kapsis automatically generates PR/MR URLs for:

| Platform | URL Format |
|----------|------------|
| GitHub | `https://github.com/{org}/{repo}/compare/{branch}?expand=1` |
| GitLab | `https://gitlab.com/{org}/{repo}/-/merge_requests/new?merge_request[source_branch]={branch}` |
| Bitbucket | `https://bitbucket.org/{org}/{repo}/pull-requests/new?source={branch}` |

## Troubleshooting

### Push Fails with Permission Denied

```bash
# Check SSH key is mounted
./scripts/launch-agent.sh ~/project --interactive
# Inside container:
ssh -T git@github.com
```

Ensure `~/.ssh` is in `filesystem.include`.

### Branch Already Exists Locally

If container has stale local branch:

```bash
# Force fresh checkout from remote
git fetch origin
git checkout -B feature/DEV-123 origin/feature/DEV-123
```

### Merge Conflicts

If remote branch was updated by someone else:

```bash
# Pull latest before agent starts
cd ~/project
git fetch origin
git checkout feature/DEV-123
git pull origin feature/DEV-123

# Then launch agent
./scripts/launch-agent.sh ~/project --branch feature/DEV-123 --spec task.md
```

### No Changes Detected

If agent made no file changes:
- Check spec file was mounted correctly
- Verify agent command is correct
- Check upper directory: `ls ~/.ai-sandboxes/project-1/upper/`

## Cleanup

After completing work on a branch or PR:

```bash
./scripts/kapsis-cleanup.sh --project products    # Clean project artifacts
cd ~/project && git worktree prune                # Prune git worktree refs
```

See [CLEANUP.md](CLEANUP.md) for full cleanup documentation.
