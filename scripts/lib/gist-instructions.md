# Kapsis Activity Gist

Update `@@KAPSIS_GIST_FILE@@` with your current activity at the START of each significant work phase. This helps users monitor your progress in real-time.

## How to Update

```bash
echo "your current activity" > @@KAPSIS_GIST_FILE@@
```

## When to Update

- Starting exploration/analysis
- Beginning implementation of a feature
- Running tests or builds
- Committing changes

## Guidelines

- Keep messages short (under 100 characters)
- Use present tense, action-oriented language
- Overwrite the file (don't append)

## Example

```bash
echo "Analyzing authentication flow in UserService" > @@KAPSIS_GIST_FILE@@
```
