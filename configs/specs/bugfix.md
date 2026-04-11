# Bug Fix Task

## Bug Description
[Describe the bug and its symptoms]

## JIRA Ticket
DEV-XXXXX

## Reproduction Steps
1. Step 1
2. Step 2
3. Step 3

## Expected Behavior
[What should happen]

## Actual Behavior
[What is happening instead]

## Root Cause Analysis Required
- [ ] Identify the root cause before fixing
- [ ] Document the root cause in commit message

## Testing Requirements
- [ ] Add regression test to prevent recurrence
- [ ] Verify fix doesn't break existing functionality

## Git Workflow

> **SSH Available**: You CAN commit and push from inside this container.
> The container has verified SSH keys and sanitized git (hooks isolated).

```bash
# Commit your changes
git add -A && git commit -m "fix: description"

# Push to remote (if --push was specified at launch, this happens automatically)
git push -u origin <branch>
```

## Definition of Done
- [ ] Root cause identified and documented
- [ ] Bug fixed
- [ ] Regression test added
- [ ] Existing tests pass
- [ ] Changes committed to branch
