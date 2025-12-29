# Kapsis Security Profiles

This directory contains security profiles and configurations for hardening Kapsis containers.

## Directory Structure

```
security/
├── seccomp/                    # Seccomp syscall filter profiles
│   ├── kapsis-agent-base.json  # Base profile for all agents
│   ├── kapsis-interactive.json # Extended profile for debugging
│   └── kapsis-audit.json       # Audit mode (logs, doesn't block)
├── apparmor/                   # AppArmor MAC profiles (Linux)
│   └── kapsis-agent            # Main AppArmor profile
├── selinux/                    # SELinux policies (RHEL/Fedora)
│   └── (coming soon)
└── README.md                   # This file
```

## Quick Start

### Using Security Profiles

Security is controlled via the `KAPSIS_SECURITY_PROFILE` environment variable or config file:

```bash
# Use strict security profile
KAPSIS_SECURITY_PROFILE=strict ./scripts/launch-agent.sh 1 ~/project --task "..."

# Or in config file (agent-sandbox.yaml)
security:
  profile: strict
```

### Available Profiles

| Profile | Capabilities | Seccomp | PID Limit | NoExec /tmp | Read-only Root |
|---------|-------------|---------|-----------|-------------|----------------|
| `minimal` | Keep all | No | No | No | No |
| `standard` | Drop + minimal | No | 1000 | No | No |
| `strict` | Drop + minimal | Yes | 500 | Yes | No |
| `paranoid` | Drop + minimal | Yes | 300 | Yes | Yes |

## Seccomp Profiles

### Base Profile (`kapsis-agent-base.json`)

The base profile allows syscalls required for:
- Java/Node.js development (JVM, npm, Maven, Gradle)
- Git operations (clone, commit, push)
- Network access (HTTP/HTTPS for AI APIs)
- File operations (read, write, create)

**Blocked syscalls** (security-critical):
- `ptrace` - Process tracing (container escape vector)
- `mount`/`umount` - Filesystem manipulation
- `bpf` - eBPF programs
- `kexec_load` - Kernel replacement
- `init_module`/`delete_module` - Kernel modules
- `keyctl` - Kernel keyring access
- And many more...

### Interactive Profile (`kapsis-interactive.json`)

Extends base profile with limited `ptrace` for debugging:
- Allows `PTRACE_TRACEME` only (strace on self)
- Use only for troubleshooting

### Audit Profile (`kapsis-audit.json`)

Logs all syscalls without blocking - for development use only:

```bash
# Enable syscall auditing
KAPSIS_SECCOMP_AUDIT=true ./scripts/launch-agent.sh ...

# View audit logs (Linux)
sudo dmesg | grep seccomp
```

## AppArmor Profile

### Installation (Ubuntu/Debian)

```bash
# Copy profile
sudo cp security/apparmor/kapsis-agent /etc/apparmor.d/

# Load profile
sudo apparmor_parser -r /etc/apparmor.d/kapsis-agent

# Verify installation
sudo aa-status | grep kapsis
```

### Usage

Once installed, Kapsis automatically detects and uses the AppArmor profile:

```bash
# Automatic detection
./scripts/launch-agent.sh 1 ~/project --task "..."

# Explicit enable
KAPSIS_LSM_MODE=apparmor ./scripts/launch-agent.sh ...
```

### Debugging

```bash
# Put profile in complain mode (log only)
sudo aa-complain kapsis-agent

# View denials
sudo dmesg | grep DENIED

# Re-enable enforcement
sudo aa-enforce kapsis-agent
```

## SELinux Policy

Coming soon. For now, SELinux is disabled via `--security-opt label=disable`.

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KAPSIS_SECURITY_PROFILE` | `standard` | Security profile (minimal/standard/strict/paranoid) |
| `KAPSIS_SECCOMP_ENABLED` | per profile | Enable seccomp filtering |
| `KAPSIS_SECCOMP_PROFILE` | auto | Custom seccomp profile path |
| `KAPSIS_SECCOMP_AUDIT` | `false` | Enable syscall auditing |
| `KAPSIS_CAPS_DROP_ALL` | per profile | Drop all capabilities |
| `KAPSIS_CAPS_ADD` | - | Additional capabilities (comma-separated) |
| `KAPSIS_NO_NEW_PRIVILEGES` | per profile | Prevent privilege escalation |
| `KAPSIS_PIDS_LIMIT` | per profile | Max processes in container |
| `KAPSIS_NOEXEC_TMP` | per profile | Apply noexec to /tmp |
| `KAPSIS_READONLY_ROOT` | per profile | Read-only root filesystem |
| `KAPSIS_LSM_MODE` | `auto` | LSM mode (auto/apparmor/selinux/disabled) |
| `KAPSIS_REQUIRE_LSM` | per profile | Fail if LSM profile not found |

### Config File

```yaml
security:
  profile: strict

  seccomp:
    enabled: true
    profile: kapsis-agent-base

  capabilities:
    drop_all: true
    add: []

  process:
    pids_limit: 500
    no_new_privileges: true

  filesystem:
    readonly_root: false
    noexec_tmp: true

  lsm:
    mode: auto
    require_profile: false
```

## Troubleshooting

### "Operation not permitted" errors

Likely a seccomp filter blocking a required syscall:

1. Enable audit mode: `KAPSIS_SECCOMP_AUDIT=true`
2. Run the failing operation
3. Check `dmesg` for blocked syscalls
4. Add syscall to profile if safe

### "Permission denied" on build operations

Likely a missing capability:

1. Check which capability is needed
2. Add via `KAPSIS_CAPS_ADD=CAP_NAME`
3. Consider if this is safe for your use case

### Scripts fail in /tmp

The `noexec` mount option blocks execution from /tmp:

1. Move scripts to /workspace
2. Or disable noexec: `KAPSIS_NOEXEC_TMP=false`

### Container won't start

Check for seccomp or AppArmor conflicts:

```bash
# Try without seccomp
KAPSIS_SECCOMP_ENABLED=false ./scripts/launch-agent.sh ...

# Try with disabled LSM
KAPSIS_LSM_MODE=disabled ./scripts/launch-agent.sh ...
```

## Security Considerations

### Defense in Depth

Kapsis uses multiple overlapping security layers:

1. **User Namespaces**: Container runs as non-root
2. **Capability Dropping**: Only minimal capabilities retained
3. **Seccomp Filtering**: Block dangerous syscalls
4. **AppArmor/SELinux**: Mandatory access control
5. **Resource Limits**: Prevent DoS attacks
6. **Read-only Root**: Limit filesystem modifications

### Threat Model

Kapsis protects against:
- **Container escape**: Via seccomp, capabilities, LSM
- **Host filesystem access**: Via namespaces, mounts
- **Network attacks from container**: Limited by LSM
- **Resource exhaustion**: Via cgroups limits
- **Privilege escalation**: Via no-new-privileges

Kapsis does NOT protect against:
- **Compromised AI API keys**: Keys are passed to container
- **Malicious model outputs**: Agent behavior is not filtered
- **Supply chain attacks**: Dependencies are not verified

### Contributing Security Fixes

If you discover a security vulnerability:
1. Do NOT open a public issue
2. Email security@kapsis.dev with details
3. We'll respond within 48 hours
