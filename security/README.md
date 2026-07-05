# Kapsis Security Profiles

This directory contains security profiles and configurations for hardening Kapsis containers.

## Directory Structure

```
security/
├── seccomp/                          # Seccomp syscall filter profiles
│   ├── kapsis-default-hardened.json  # DEFAULT: upstream default minus userns/mount
│   ├── kapsis-default-userns.json    # Opt-out: verbatim upstream (userns allowed)
│   ├── kapsis-agent-base.json        # Legacy thin allowlist (also hardened)
│   ├── kapsis-interactive.json       # Extended profile for debugging
│   └── kapsis-audit.json             # Audit mode (logs, doesn't block)
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
| `standard` | Drop + minimal | Yes (hardened) | 1000 | No | No |
| `strict` | Drop + minimal | Yes (hardened) | 500 | Yes | No |
| `paranoid` | Drop + minimal | Yes (hardened) | 300 | Yes | Yes |

## Seccomp Profiles

### Default-Hardened Profile (`kapsis-default-hardened.json`) — the default

Used by `standard`/`strict`/`paranoid`. It is the **verbatim upstream
containers/common default seccomp profile** (so it keeps all of upstream's broad
syscall coverage and multi-architecture support) with the **user-namespace +
mount-escalation family denied (EPERM)**: `unshare`, `setns`, `mount`, `umount2`,
`fsopen`, `fsconfig`, `fspick`, `move_mount`, `open_tree`, `pivot_root`,
`mount_setattr`. This closes the `unshare(CLONE_NEWUSER)` → nested-userns →
`mount`/`fsconfig` escalation path (CVE-2022-0185 class) that the stock profile
leaves open even with all capabilities dropped. `clone`/`clone3` remain allowed
(process/thread creation). See `docs/SECURITY-HARDENING.md` §1.3 for the threat
model, residual risk, and the known-breakage list.

**Opt out** (nested containers, bubblewrap/nsjail, Chromium/Playwright sandboxes):
set `KAPSIS_ALLOW_USERNS=true` or `security.seccomp.allow_userns: true` to swap to
`kapsis-default-userns.json` (the verbatim upstream default, userns allowed).

### Userns-Permissive Profile (`kapsis-default-userns.json`) — opt-out

The verbatim upstream containers/common default (userns + mount allowed). Selected
only when `KAPSIS_ALLOW_USERNS=true`.

### Legacy Base Profile (`kapsis-agent-base.json`)

A hand-rolled `defaultAction: SCMP_ACT_ERRNO` allowlist for Java/Node.js
development, Git, network, and file operations. Also hardened: `unshare`/`setns`
are now denied with EPERM (the mount family was already absent from its
allowlist). Retained as a fallback; the default-hardened profile is preferred
because it inherits upstream's full coverage rather than a thin allowlist.

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
| `KAPSIS_SECCOMP_ENABLED` | per profile | Master switch for seccomp filtering (false = no profile) |
| `KAPSIS_SECCOMP_PROFILE` | auto | Custom seccomp profile path (full override) |
| `KAPSIS_ALLOW_USERNS` | `false` | Opt out of userns+mount denial — swaps to the permissive upstream profile (nested containers / bubblewrap / Chromium) |
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
    # allow_userns: true   # opt out of the userns+mount denial (nested
    #                      # containers / bubblewrap / Chromium sandboxes)
    # profile: /custom/seccomp.json   # full override

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

### Nested containers / bubblewrap / Chromium fail with EPERM on `unshare`/`mount`

The default-hardened profile denies the user-namespace + mount-escalation family
(CVE-2022-0185 class). Workloads that legitimately need nested user namespaces or
mounts — running Podman/Docker inside the agent, `bubblewrap`/`nsjail`, or
Chromium/Playwright/Electron sandboxes — will see `EPERM`. Opt out:

```bash
KAPSIS_ALLOW_USERNS=true ./scripts/launch-agent.sh ...
# or in agent-sandbox.yaml: security.seccomp.allow_userns: true
```

This swaps to the verbatim upstream default profile (userns allowed). See
`docs/SECURITY-HARDENING.md` §1.3.

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
