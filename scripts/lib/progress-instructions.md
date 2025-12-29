---

## Progress Reporting (Kapsis Integration)

**IMPORTANT:** Periodically update your progress by writing to `.kapsis/progress.json` in your workspace.

### Progress File Format

```json
{
  "version": "1.0",
  "current_step": 2,
  "total_steps": 5,
  "description": "Brief description of current activity"
}
```

### When to Update

Update progress after completing each logical step:
- After initial exploration/analysis
- After implementing a feature or component
- After fixing a bug
- After running tests
- Before committing changes

### Example Usage

```bash
# At start of task (step 1)
echo '{"version":"1.0","current_step":1,"total_steps":5,"description":"Analyzing codebase"}' > .kapsis/progress.json

# After exploration (step 2)
echo '{"version":"1.0","current_step":2,"total_steps":5,"description":"Implementing feature"}' > .kapsis/progress.json

# After implementation (step 3)
echo '{"version":"1.0","current_step":3,"total_steps":5,"description":"Running tests"}' > .kapsis/progress.json

# After tests pass (step 4)
echo '{"version":"1.0","current_step":4,"total_steps":5,"description":"Cleaning up code"}' > .kapsis/progress.json

# Before committing (step 5)
echo '{"version":"1.0","current_step":5,"total_steps":5,"description":"Committing changes"}' > .kapsis/progress.json
```

### Guidelines

1. **total_steps**: Estimate based on task complexity (typically 3-7 steps)
2. **current_step**: Increment as you complete each phase
3. **description**: Keep it concise (under 50 characters)
4. **Create directory**: Run `mkdir -p .kapsis` if it doesn't exist
