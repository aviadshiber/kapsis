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
│  │       if not --no-push:                                             │   │
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
│  │   ./launch-agent.sh 1 ~/project \                                   │   │
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
./scripts/launch-agent.sh 1 ~/project \
    --branch feature/DEV-123-user-preferences \
    --spec ./specs/add-user-endpoint.md
```

### Continue Existing Branch

```bash
# After PR review feedback, update spec
cat >> specs/add-user-endpoint.md << 'EOF'

## PR Feedback (Review 1)
- Handle null preferences gracefully
- Add rate limiting to PUT endpoint
EOF

# Re-launch with same branch — continues from remote state
./scripts/launch-agent.sh 1 ~/project \
    --branch feature/DEV-123-user-preferences \
    --spec ./specs/add-user-endpoint.md
```

### Auto-Generated Branch

```bash
# Let Kapsis generate branch name
./scripts/launch-agent.sh 1 ~/project \
    --auto-branch \
    --spec ./specs/fix-tests.md

# Creates: ai-agent/fix-tests-20241214-153052
```

### Local-Only Commits

```bash
# Commit but don't push (for review before push)
./scripts/launch-agent.sh 1 ~/project \
    --branch feature/DEV-123 \
    --no-push \
    --spec ./specs/task.md

# Later, push manually
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
./scripts/launch-agent.sh 1 ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-backend \
    --spec ./specs/backend.md &

./scripts/launch-agent.sh 2 ~/project \
    --config configs/claude.yaml \
    --branch feature/DEV-123-frontend \
    --spec ./specs/frontend.md &

./scripts/launch-agent.sh 3 ~/project \
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

Generated by Kapsis AI Agent Sandbox
Agent ID: {agent_id}
Branch: {branch}
```

Customize in config:

```yaml
git:
  auto_push:
    commit_message: |
      feat: {task}

      Generated by {agent} via Kapsis
      Ticket: DEV-{branch_number}

      Co-Authored-By: AI Agent <ai@kapsis.local>
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
./scripts/launch-agent.sh 1 ~/project --interactive
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
./scripts/launch-agent.sh 1 ~/project --branch feature/DEV-123 --spec task.md
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
