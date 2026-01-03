# Security Policy

## Supported Versions

We actively maintain security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Security Model

Kapsis provides sandbox isolation for AI coding agents using:

- **Container Isolation**: Podman rootless containers with no privileged access
- **Filesystem Isolation**: Copy-on-Write overlays prevent host modification
- **Network Isolation**: Configurable network policies per agent
- **Credential Isolation**: Secrets accessed via OS keychain, never written to disk
- **User Namespace Mapping**: Non-root execution with UID/GID remapping
- **Filesystem Scope Enforcement**: Validates modifications stay within allowed paths
- **Supply Chain Pinning**: Base images and dependencies pinned to specific digests

### Security Boundaries

The following are **in scope** for Kapsis security guarantees:

- Container escape prevention
- Host filesystem integrity protection
- Credential exposure prevention
- Privilege escalation prevention within containers

The following are **out of scope**:

- Security of the AI agents themselves
- Network security beyond container boundaries
- Security of mounted whitelisted directories (user-configured)

## Reporting a Vulnerability

We take security vulnerabilities seriously. Please report them responsibly.

### How to Report

**DO NOT** open a public GitHub issue for security vulnerabilities.

Instead, please report security issues via one of these methods:

1. **GitHub Security Advisories** (Preferred):
   - Go to the [Security Advisories](https://github.com/aviadshiber/kapsis/security/advisories) page
   - Click "New draft security advisory"
   - Fill in the vulnerability details

2. **Email**:
   - Send details to the repository maintainer
   - Include "SECURITY" in the subject line
   - Encrypt sensitive details if possible (PGP key available on request)

### What to Include

Please provide:

- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if any)
- Your contact information for follow-up

### Response Timeline

| Action | Timeline |
|--------|----------|
| Initial response | Within 48 hours |
| Vulnerability assessment | Within 7 days |
| Fix development | Within 30 days (severity dependent) |
| Public disclosure | After fix is released |

### Recognition

We appreciate responsible disclosure and will:

- Credit reporters in release notes (unless anonymity is requested)
- Work with you on coordinated disclosure timing
- Not take legal action against good-faith security research

## Security Best Practices for Users

### Container Runtime

- Use Podman 5.0+ for latest security features
- Enable rootless mode (default)
- Keep Podman and dependencies updated

### Configuration

- Minimize whitelisted mount paths
- Use read-only mounts where possible
- Review agent configurations before deployment
- Never whitelist sensitive directories (e.g., `~/.ssh`, `~/.gnupg`)

### Credentials

- Use OS keychain integration for secrets
- Rotate API keys regularly
- Use scoped tokens with minimum required permissions

### Network Isolation

Kapsis supports two network modes for container isolation:

```bash
# Maximum security - no network access
./scripts/launch-agent.sh ~/project --network-mode none --task "..."

# Default (backward compatible) - full network access with warning
./scripts/launch-agent.sh ~/project --network-mode open --task "..."
```

| Mode | Description | Use Case |
|------|-------------|----------|
| `none` | No network access (`--network=none`) | Maximum isolation, offline tasks |
| `open` | Full network access (default) | Tasks requiring network (git clone, npm install) |

**Note**: The default is `open` for backward compatibility, but `none` is recommended for security-sensitive tasks.

#### Configuration Precedence

Network mode can be set through multiple methods with the following precedence (highest to lowest):

1. **CLI argument**: `--network-mode none`
2. **Environment variable**: `KAPSIS_NETWORK_MODE=none`
3. **Config file**: `~/.kapsis/config.yaml` with `network_mode: none`
4. **Default**: `open`

Example using environment variable:

```bash
export KAPSIS_NETWORK_MODE=none
./scripts/launch-agent.sh ~/project --task "offline refactoring"
```

Example config file (`~/.kapsis/config.yaml`):

```yaml
# Default network isolation mode
network_mode: none

# Other configuration options...
```

### Filesystem Scope Enforcement

Kapsis validates that container modifications stay within allowed boundaries:

**Allowed Paths** (modifications permitted):
- `/workspace/**` - Project files
- `/tmp/**` - Temporary files
- `/home/developer/.m2/repository/**` - Maven cache
- `/home/developer/.gradle/**` - Gradle cache
- `/kapsis-status/**` - Status files

**Blocked Paths** (modifications blocked, container aborted):
- `~/.ssh/*` - SSH keys
- `~/.claude/*` - Agent configuration
- `~/.bashrc`, `~/.zshrc`, `~/.profile` - Shell startup files
- `~/.gitconfig` - Git credentials
- `/etc/*` - System configuration
- `~/.aws/*`, `~/.kube/*` - Cloud credentials

**Warning Paths** (allowed but logged):
- `.git/hooks/*` - Git hooks (potential for persistence)

Scope violations are logged to `~/.kapsis/audit/scope-violations.jsonl` for forensic analysis.

### Supply Chain Security

Kapsis pins all dependencies to prevent supply chain attacks:

1. **Base Image**: Pinned to specific SHA256 digest
   ```dockerfile
   FROM ubuntu@sha256:955364933d0d91afa6e10fb045948c16d2b191114aa54bed3ab5430d8bbc58cc
   ```

2. **GitHub Actions**: Pinned to commit SHAs
   ```yaml
   uses: actions/checkout@8e8c483db84b4bee98b60c0593521ed34d9990e8  # v6
   ```

3. **Downloaded Tools**: Verified with SHA256 checksums (yq, SDKMAN, NVM)

CI automatically verifies pinning via the `verify-pinning` job

## Security Updates

Security updates are released as:

- **Patch releases** for vulnerabilities (e.g., 1.0.1)
- **Security advisories** on GitHub with CVE assignment when applicable

Subscribe to releases to receive security update notifications:

1. Go to the repository
2. Click "Watch" > "Custom" > Check "Releases"

## Audit History

| Date | Auditor | Scope | Status |
|------|---------|-------|--------|
| - | - | Initial release pending formal audit | - |

## Contact

For security-related questions that aren't vulnerabilities:

- Open a [Discussion](https://github.com/aviadshiber/kapsis/discussions)
- Tag with "security" label
