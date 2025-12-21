# GitHub Repository Setup

This guide explains how to configure GitHub branch protection and CI/CD for the Kapsis repository.

## CI/CD Pipeline

The repository includes a GitHub Actions workflow (`.github/workflows/ci.yml`) that runs automatically on:
- All pull requests to `main`/`master`
- Direct pushes to `main`/`master`

### CI Jobs

| Job | Description | When |
|-----|-------------|------|
| **lint** | Runs ShellCheck on all shell scripts | Always |
| **quick-tests** | Runs fast tests (no container) | After lint passes |
| **container-tests** | Runs full container test suite | Only on merge to main |
| **ci-success** | Summary job for branch protection | Always |

### Container Tests

Container tests only run after merge to main (not on PRs) because they take ~30+ minutes to build the container image and run the full test suite. This keeps PR feedback fast while ensuring thorough testing on main.

## Branch Protection Rules

Branch protection ensures all changes go through pull requests and pass CI before merging.

### Automated Setup (Recommended)

Use the provided script to configure branch protection:

```bash
# Basic setup (require CI, block direct pushes)
./scripts/setup-github-protection.sh

# With required PR reviews
./scripts/setup-github-protection.sh --require-reviews

# Require 2 reviewers
./scripts/setup-github-protection.sh --require-reviews --review-count 2

# Preview changes without applying
./scripts/setup-github-protection.sh --dry-run

# Protect a different branch
./scripts/setup-github-protection.sh --branch develop
```

#### Prerequisites

1. Install [GitHub CLI](https://cli.github.com/):
   ```bash
   # macOS
   brew install gh

   # Ubuntu/Debian
   sudo apt install gh

   # Or download from https://cli.github.com/
   ```

2. Authenticate with GitHub:
   ```bash
   gh auth login
   ```

3. Ensure you have admin access to the repository

### Manual Setup (via GitHub UI)

If you prefer to configure manually:

1. Go to your repository on GitHub
2. Navigate to **Settings** > **Branches**
3. Click **Add branch protection rule**
4. Configure:

   | Setting | Value |
   |---------|-------|
   | Branch name pattern | `main` |
   | Require a pull request before merging | ✅ Enabled |
   | Require status checks to pass | ✅ Enabled |
   | Status checks that are required | `CI Success` |
   | Require branches to be up to date | ✅ Enabled |
   | Do not allow bypassing | Optional |

5. Click **Create** or **Save changes**

## Protection Rules Explained

### What Gets Enforced

1. **No Direct Pushes**: All changes must go through pull requests
2. **CI Must Pass**: The `CI Success` job must complete successfully
3. **Up-to-Date Branch**: PRs must be rebased on the latest target branch
4. **Force Push Blocked**: Prevents history rewriting on protected branches

### What's Optional

- **Required Reviews**: Use `--require-reviews` to require approvals
- **Admin Bypass**: Admins can be exempt (controlled via GitHub UI)
- **CODEOWNERS**: Add a `CODEOWNERS` file for automatic review requests

## CI Workflow Details

### ShellCheck Configuration

The lint job runs ShellCheck with:
- Severity level: `warning` and above
- External sourcing enabled (`-x` flag)
- Shell dialect: `bash`

To check locally before pushing:
```bash
# Install shellcheck
sudo apt install shellcheck  # Ubuntu
brew install shellcheck      # macOS

# Run on all scripts
find . -name "*.sh" -exec shellcheck -x -S warning {} \;
```

### Test Categories

| Category | Command | Duration | Requires |
|----------|---------|----------|----------|
| Quick | `./tests/run-all-tests.sh --quick` | ~10s | Nothing |
| Container | `./tests/run-all-tests.sh --container` | ~30min | Podman |
| All | `./tests/run-all-tests.sh` | ~30min | Podman |

### Local Development Workflow

1. Create a feature branch:
   ```bash
   git checkout -b feature/my-feature
   ```

2. Make changes and run quick tests:
   ```bash
   ./tests/run-all-tests.sh --quick
   ```

3. Run ShellCheck locally:
   ```bash
   shellcheck -x scripts/*.sh tests/*.sh
   ```

4. Push and create PR:
   ```bash
   git push -u origin feature/my-feature
   gh pr create
   ```

5. CI will run automatically. Merge when all checks pass.

## Troubleshooting

### "CI Success" check not appearing

The `CI Success` check only appears after the workflow runs at least once. Push a commit to trigger it.

### ShellCheck failures

Common fixes:
- Quote variables: `"$var"` instead of `$var`
- Use `[[ ]]` instead of `[ ]` for conditionals
- Check for unused variables
- See [ShellCheck wiki](https://github.com/koalaman/shellcheck/wiki) for explanations

### Permission denied when running setup script

```bash
chmod +x ./scripts/setup-github-protection.sh
```

### GitHub CLI authentication issues

```bash
# Re-authenticate
gh auth logout
gh auth login

# Verify authentication
gh auth status
```

## Security Considerations

- The protection script doesn't store credentials; it uses `gh` auth
- CI secrets should be configured in GitHub Settings > Secrets
- Never commit sensitive data (API keys, tokens) to the repository
- Container tests run in isolated environments
