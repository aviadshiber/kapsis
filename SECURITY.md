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

### Network

- Use `--network=none` for maximum isolation when network isn't needed
- Configure network policies for agents requiring connectivity

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
