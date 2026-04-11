# Kapsis Activity Gist

Update `/workspace/.kapsis/gist.txt` with your current activity at the START of each significant work phase. This helps users monitor your progress in real-time.

## How to Update

```bash
echo "your current activity" > /workspace/.kapsis/gist.txt
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
echo "Analyzing authentication flow in UserService" > /workspace/.kapsis/gist.txt
```
