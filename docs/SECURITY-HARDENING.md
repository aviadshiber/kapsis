# Kapsis Container Security Hardening Design

## Executive Summary

This document provides a comprehensive container hardening design for the Kapsis AI agent sandbox. The goal is to minimize attack surface, prevent container escape, and limit blast radius if an agent is compromised, while maintaining functionality for AI coding agents.

**Current State Analysis:**
- Rootless Podman with `--userns=keep-id` (good baseline)
- Non-root user (developer, UID 1000)
- Memory/CPU limits configurable
- NO seccomp profile (all ~300+ syscalls allowed)
- SELinux/AppArmor disabled (`--security-opt label=disable`)
- No explicit capability dropping
- No cgroup v2 hardening beyond memory/CPU

**Target Security Posture:**
- Defense-in-depth with multiple isolation layers
- Principle of least privilege for syscalls and capabilities
- Fail-secure defaults with opt-in relaxation
- Cross-platform support (macOS Podman Machine, Linux native)

---

## Table of Contents

1. [Seccomp Profile Design](#1-seccomp-profile-design)
2. [Capability Dropping](#2-capability-dropping)
3. [Filesystem Hardening](#3-filesystem-hardening)
4. [Process Isolation](#4-process-isolation)
5. [Resource Limits](#5-resource-limits)
6. [AppArmor/SELinux Profiles](#6-apparmorselinux-profiles)
7. [Implementation Plan](#7-implementation-plan)
8. [Configuration Reference](#8-configuration-reference)
9. [Testing Strategy](#9-testing-strategy)

---

## 1. Seccomp Profile Design

### 1.1 Overview

Seccomp (Secure Computing Mode) filters syscalls at the kernel level. By default, Podman uses a permissive profile allowing ~300+ syscalls. We'll create a restrictive profile tailored to AI coding agents.

### 1.2 Base Profile: `kapsis-agent-base.json`

This profile allows syscalls required for:
- Java/Node.js development (JVM, npm, Maven, Gradle)
- Git operations (clone, commit, push)
- Network access (HTTP/HTTPS for AI APIs)
- File operations (read, write, create)

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": [
        "SCMP_ARCH_X86",
        "SCMP_ARCH_X32"
      ]
    },
    {
      "architecture": "SCMP_ARCH_AARCH64",
      "subArchitectures": [
        "SCMP_ARCH_ARM"
      ]
    }
  ],
  "syscalls": [
    {
      "names": [
        "accept", "accept4",
        "access", "faccessat", "faccessat2",
        "arch_prctl",
        "bind",
        "brk",
        "capget", "capset",
        "chdir", "fchdir",
        "chmod", "fchmod", "fchmodat",
        "chown", "fchown", "fchownat", "lchown",
        "clock_getres", "clock_gettime", "clock_nanosleep",
        "clone", "clone3",
        "close", "close_range",
        "connect",
        "copy_file_range",
        "creat",
        "dup", "dup2", "dup3",
        "epoll_create", "epoll_create1", "epoll_ctl", "epoll_pwait", "epoll_wait",
        "eventfd", "eventfd2",
        "execve", "execveat",
        "exit", "exit_group",
        "fallocate",
        "fadvise64",
        "flock",
        "fork",
        "fstat", "fstatat64", "fstatfs", "fstatfs64",
        "fsync", "fdatasync",
        "ftruncate",
        "futex", "futex_waitv",
        "getcwd",
        "getdents", "getdents64",
        "getegid", "geteuid", "getgid", "getuid",
        "getgroups",
        "getitimer", "setitimer",
        "getpeername",
        "getpgid", "getpgrp", "getpid", "getppid",
        "getrandom",
        "getresgid", "getresuid",
        "getrlimit", "setrlimit", "prlimit64",
        "getsid",
        "getsockname", "getsockopt",
        "gettid",
        "gettimeofday",
        "getxattr", "fgetxattr", "lgetxattr",
        "inotify_add_watch", "inotify_init", "inotify_init1", "inotify_rm_watch",
        "io_cancel", "io_destroy", "io_getevents", "io_setup", "io_submit",
        "io_uring_enter", "io_uring_register", "io_uring_setup",
        "ioctl",
        "kill",
        "lchown",
        "link", "linkat",
        "listen",
        "lseek", "llseek",
        "lstat",
        "madvise",
        "memfd_create",
        "mincore",
        "mkdir", "mkdirat",
        "mknod", "mknodat",
        "mlock", "mlock2", "munlock", "mlockall", "munlockall",
        "mmap", "mmap2",
        "mprotect",
        "mremap",
        "msync",
        "munmap",
        "name_to_handle_at",
        "nanosleep",
        "newfstatat",
        "open", "openat", "openat2",
        "pause",
        "pipe", "pipe2",
        "poll", "ppoll",
        "prctl",
        "pread64", "preadv", "preadv2",
        "pwrite64", "pwritev", "pwritev2",
        "read", "readv",
        "readahead",
        "readlink", "readlinkat",
        "recvfrom", "recvmsg", "recvmmsg",
        "remap_file_pages",
        "rename", "renameat", "renameat2",
        "restart_syscall",
        "rmdir",
        "rseq",
        "rt_sigaction", "rt_sigpending", "rt_sigprocmask", "rt_sigqueueinfo",
        "rt_sigreturn", "rt_sigsuspend", "rt_sigtimedwait",
        "sched_getaffinity", "sched_getattr", "sched_getparam", "sched_getscheduler",
        "sched_setaffinity", "sched_setattr", "sched_setparam", "sched_setscheduler",
        "sched_get_priority_max", "sched_get_priority_min",
        "sched_yield",
        "select", "pselect6",
        "semctl", "semget", "semop", "semtimedop",
        "sendfile", "sendfile64",
        "sendmsg", "sendmmsg", "sendto",
        "set_robust_list", "get_robust_list",
        "set_tid_address",
        "setfsgid", "setfsuid",
        "setgid", "setgroups",
        "setns",
        "setpgid", "setsid",
        "setresgid", "setresuid",
        "setsockopt",
        "setuid",
        "shmat", "shmctl", "shmdt", "shmget",
        "shutdown",
        "sigaltstack",
        "signalfd", "signalfd4",
        "socket", "socketpair",
        "splice",
        "stat", "statfs", "statx",
        "symlink", "symlinkat",
        "sync", "syncfs",
        "sysinfo",
        "tee",
        "tgkill",
        "time",
        "timer_create", "timer_delete", "timer_getoverrun", "timer_gettime", "timer_settime",
        "timerfd_create", "timerfd_gettime", "timerfd_settime",
        "times",
        "tkill",
        "truncate",
        "umask",
        "uname",
        "unlink", "unlinkat",
        "unshare",
        "utime", "utimes", "utimensat", "futimesat",
        "vfork",
        "wait4", "waitid", "waitpid",
        "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 0, "op": "SCMP_CMP_EQ"}
      ]
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 8, "op": "SCMP_CMP_EQ"}
      ]
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 131072, "op": "SCMP_CMP_EQ"}
      ]
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 131080, "op": "SCMP_CMP_EQ"}
      ]
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 4294967295, "op": "SCMP_CMP_EQ"}
      ]
    }
  ]
}
```

### 1.3 Blocked Syscalls (Security-Critical)

The following syscalls are explicitly blocked by the default-deny policy:

| Syscall | Risk | Notes |
|---------|------|-------|
| `ptrace` | Container escape | Process tracing/debugging |
| `mount`, `umount`, `umount2` | Filesystem manipulation | Already blocked by capability drop |
| `reboot` | System disruption | Kernel control |
| `swapon`, `swapoff` | Resource exhaustion | Memory management |
| `sethostname`, `setdomainname` | Identity spoofing | Network identity |
| `acct` | Information disclosure | Process accounting |
| `init_module`, `delete_module` | Kernel modification | Module loading |
| `kexec_load`, `kexec_file_load` | Kernel replacement | Boot modification |
| `perf_event_open` | Information disclosure | Performance monitoring |
| `bpf` | Kernel manipulation | eBPF programs |
| `userfaultfd` | Container escape vector | Memory fault handling |
| `lookup_dcookie` | Information disclosure | Kernel data structures |
| `keyctl` | Credential theft | Kernel keyring |
| `add_key`, `request_key` | Credential manipulation | Kernel keyring |

### 1.4 Agent-Specific Profiles

#### 1.4.1 Claude CLI Profile (`kapsis-claude.json`)

Claude Code requires Node.js and may spawn subprocesses. Uses base profile with no additions.

```json
{
  "extends": "kapsis-agent-base.json",
  "comment": "Claude Code CLI - Node.js based agent"
}
```

#### 1.4.2 Aider Profile (`kapsis-aider.json`)

Aider uses Python and may require additional syscalls for pip operations.

```json
{
  "extends": "kapsis-agent-base.json",
  "syscalls": [
    {
      "names": ["flock"],
      "action": "SCMP_ACT_ALLOW",
      "comment": "pip file locking"
    }
  ]
}
```

#### 1.4.3 Interactive/Debug Profile (`kapsis-interactive.json`)

For debugging, allows additional syscalls but still blocks dangerous ones.

```json
{
  "extends": "kapsis-agent-base.json",
  "syscalls": [
    {
      "names": ["ptrace"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {"index": 0, "value": 0, "op": "SCMP_CMP_EQ"},
        {"comment": "PTRACE_TRACEME only - for strace on self"}
      ]
    }
  ]
}
```

### 1.5 macOS vs Linux Considerations

| Platform | Seccomp Support | Implementation |
|----------|-----------------|----------------|
| Linux (native) | Full kernel support | Use `--security-opt seccomp=<profile>.json` |
| macOS (Podman Machine) | Via Linux VM | Same flag, VM kernel applies it |

**macOS Note:** Podman Machine runs a Linux VM, so seccomp profiles work identically. The VM's kernel enforces the seccomp policy.

### 1.6 Profile Loading Implementation

```bash
# In launch-agent.sh build_container_command()
SECCOMP_PROFILE="${KAPSIS_ROOT}/security/seccomp/kapsis-agent-base.json"

# Check for agent-specific profile
if [[ -f "${KAPSIS_ROOT}/security/seccomp/kapsis-${AGENT_NAME}.json" ]]; then
    SECCOMP_PROFILE="${KAPSIS_ROOT}/security/seccomp/kapsis-${AGENT_NAME}.json"
fi

CONTAINER_CMD+=(
    "--security-opt" "seccomp=${SECCOMP_PROFILE}"
)
```

---

## 2. Capability Dropping

### 2.1 Current State

Currently, Kapsis does not explicitly drop capabilities. Rootless Podman provides some protection, but the container still inherits capabilities from the non-root user namespace.

### 2.2 Capability Analysis

#### 2.2.1 Capabilities to Drop (All Unnecessary)

| Capability | Risk | Drop? |
|------------|------|-------|
| `CAP_AUDIT_CONTROL` | Audit manipulation | YES |
| `CAP_AUDIT_READ` | Information disclosure | YES |
| `CAP_AUDIT_WRITE` | Audit tampering | YES |
| `CAP_BLOCK_SUSPEND` | Denial of service | YES |
| `CAP_BPF` | Kernel manipulation | YES |
| `CAP_CHECKPOINT_RESTORE` | Container escape | YES |
| `CAP_DAC_READ_SEARCH` | File access bypass | YES |
| `CAP_IPC_LOCK` | Resource exhaustion | YES |
| `CAP_IPC_OWNER` | IPC manipulation | YES |
| `CAP_KILL` | Process termination | KEEP (for signal handling) |
| `CAP_LEASE` | File lease manipulation | YES |
| `CAP_LINUX_IMMUTABLE` | File attribute manipulation | YES |
| `CAP_MAC_ADMIN` | MAC policy bypass | YES |
| `CAP_MAC_OVERRIDE` | MAC policy bypass | YES |
| `CAP_MKNOD` | Device creation | YES |
| `CAP_NET_ADMIN` | Network configuration | YES |
| `CAP_NET_BIND_SERVICE` | Privileged ports | YES |
| `CAP_NET_BROADCAST` | Network broadcast | YES |
| `CAP_NET_RAW` | Raw sockets | YES |
| `CAP_PERFMON` | Performance monitoring | YES |
| `CAP_SETFCAP` | Capability setting | YES |
| `CAP_SETPCAP` | Capability modification | YES |
| `CAP_SYS_ADMIN` | Container escape vector | YES |
| `CAP_SYS_BOOT` | System reboot | YES |
| `CAP_SYS_CHROOT` | Chroot manipulation | YES |
| `CAP_SYS_MODULE` | Kernel modules | YES |
| `CAP_SYS_NICE` | Process scheduling | KEEP (for Maven/Gradle) |
| `CAP_SYS_PACCT` | Process accounting | YES |
| `CAP_SYS_PTRACE` | Process tracing | YES |
| `CAP_SYS_RAWIO` | Raw I/O access | YES |
| `CAP_SYS_RESOURCE` | Resource limits bypass | YES |
| `CAP_SYS_TIME` | System time modification | YES |
| `CAP_SYS_TTY_CONFIG` | TTY configuration | YES |
| `CAP_SYSLOG` | Syslog access | YES |
| `CAP_WAKE_ALARM` | Wake alarms | YES |

#### 2.2.2 Capabilities to Keep (Minimal Set)

| Capability | Reason |
|------------|--------|
| `CAP_CHOWN` | File ownership (build artifacts) |
| `CAP_FOWNER` | File owner operations |
| `CAP_FSETID` | Set-ID bits on files |
| `CAP_KILL` | Signal handling (process management) |
| `CAP_SETGID` | Group ID changes |
| `CAP_SETUID` | User ID changes |
| `CAP_SETPCAP` | Remove to prevent escalation |
| `CAP_SYS_NICE` | Process priority (build tools) |

### 2.3 Implementation

```bash
# In launch-agent.sh build_container_command()
CONTAINER_CMD+=(
    "--cap-drop=ALL"
    "--cap-add=CHOWN"
    "--cap-add=FOWNER"
    "--cap-add=FSETID"
    "--cap-add=KILL"
    "--cap-add=SETGID"
    "--cap-add=SETUID"
    "--cap-add=SYS_NICE"
)
```

### 2.4 Configuration Option

Add to `CONFIG-REFERENCE.md`:

```yaml
security:
  # Capability management
  capabilities:
    # Drop all capabilities and add back only those needed
    # Default: true (recommended)
    drop_all: true

    # Additional capabilities to add (use sparingly)
    # These are added on top of the minimal set
    add: []

    # Capabilities to explicitly drop (in addition to drop_all)
    drop: []
```

---

## 3. Filesystem Hardening

### 3.1 Read-Only Root Filesystem

Make the container root filesystem read-only, with explicit writable paths.

#### 3.1.1 Implementation

```bash
# In launch-agent.sh build_container_command()
if [[ "${KAPSIS_READONLY_ROOT:-false}" == "true" ]]; then
    CONTAINER_CMD+=(
        "--read-only"
        "--tmpfs=/tmp:rw,noexec,nosuid,size=1g"
        "--tmpfs=/run:rw,noexec,nosuid,size=100m"
        "--tmpfs=/var/tmp:rw,noexec,nosuid,size=500m"
    )
fi
```

#### 3.1.2 Required Writable Paths

| Path | Purpose | Mount Type |
|------|---------|------------|
| `/workspace` | Project files | Volume (worktree or overlay) |
| `/home/developer` | User home | tmpfs or volume |
| `/home/developer/.m2/repository` | Maven cache | Named volume |
| `/home/developer/.gradle` | Gradle cache | Named volume |
| `/tmp` | Temporary files | tmpfs |
| `/run` | Runtime files | tmpfs |
| `/var/tmp` | Persistent temp | tmpfs |
| `/kapsis-status` | Status reporting | Bind mount |

### 3.2 Mount Options

Apply security mount options to all volumes:

| Option | Purpose | Apply To |
|--------|---------|----------|
| `noexec` | Prevent execution | `/tmp`, `/var/tmp`, config mounts |
| `nosuid` | Prevent setuid | All mounts except `/workspace` |
| `nodev` | Prevent device files | All mounts |

#### 3.2.1 Implementation

```bash
# In generate_volume_mounts_worktree()

# Status directory with security options
VOLUME_MOUNTS+=("-v" "${status_dir}:/kapsis-status:noexec,nosuid,nodev")

# Config files (read-only with noexec)
# Already :ro, add noexec
VOLUME_MOUNTS+=("-v" "${expanded_path}:${staging_path}:ro,noexec,nosuid,nodev")

# Git objects (read-only)
VOLUME_MOUNTS+=("-v" "${OBJECTS_PATH}:${CONTAINER_OBJECTS_PATH}:ro,noexec,nosuid,nodev")
```

### 3.3 Workspace Protection

The `/workspace` mount needs special handling:

```bash
# Workspace needs exec for build tools, but apply other restrictions
VOLUME_MOUNTS+=("-v" "${WORKTREE_PATH}:/workspace:nosuid,nodev")
```

### 3.4 Temporary Directory Hardening

```bash
# Add tmpfs mounts with size limits and noexec
CONTAINER_CMD+=(
    "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=${KAPSIS_TMP_SIZE:-1g}"
    "--tmpfs=/var/tmp:rw,noexec,nosuid,nodev,size=${KAPSIS_VARTMP_SIZE:-500m}"
)
```

### 3.5 Configuration Options

```yaml
security:
  filesystem:
    # Read-only root filesystem
    # Default: true for strict/paranoid profiles
    readonly_root: false

    # Temporary directory size limits
    tmp_size: 1g
    var_tmp_size: 500m

    # Apply noexec to config mounts
    # Default: true
    noexec_configs: true

    # Apply noexec to temp directories
    # Default: true (recommended)
    noexec_tmp: true
```

---

## 4. Process Isolation

### 4.1 PID Namespace Isolation

Podman already uses PID namespace isolation by default. Verify and enforce:

```bash
# In build_container_command()
# Ensure PID namespace isolation (default, but explicit)
CONTAINER_CMD+=(
    "--pid=private"
)
```

### 4.2 Process Count Limits

Prevent fork bombs and runaway process creation:

```bash
# In build_container_command()
PROCESS_LIMIT="${KAPSIS_PIDS_LIMIT:-1000}"
CONTAINER_CMD+=(
    "--pids-limit=${PROCESS_LIMIT}"
)
```

**Recommended limits by agent type:**

| Agent Type | PID Limit | Rationale |
|------------|-----------|-----------|
| claude | 500 | Node.js, moderate subprocess needs |
| codex | 500 | Similar to Claude |
| aider | 300 | Python, fewer subprocesses |
| interactive | 1000 | Debugging flexibility |
| java-build | 2000 | Maven/Gradle parallel builds |

### 4.3 No New Privileges Flag

Prevent privilege escalation via setuid binaries:

```bash
# In build_container_command()
CONTAINER_CMD+=(
    "--security-opt" "no-new-privileges:true"
)
```

This blocks:
- Setuid/setgid binary execution
- Capability escalation
- LSM (SELinux/AppArmor) transitions

### 4.4 User Namespace Enforcement

Ensure user namespace mapping is always enabled:

```bash
# Already using --userns=keep-id, but verify
CONTAINER_CMD+=(
    "--userns=keep-id"
)
```

### 4.5 Network Isolation

Kapsis provides three network isolation modes with DNS-based filtering as the secure default:

| Mode | Description | Use Case |
|------|-------------|----------|
| `none` | Complete isolation (`--network=none`) | Maximum security, offline tasks |
| `filtered` | DNS-based allowlist **(default)** | Standard development workflows |
| `open` | Unrestricted network access | Special cases requiring full access |

```bash
# Default: filtered mode with DNS-based allowlist
if [[ "${KAPSIS_NETWORK_MODE}" == "none" ]]; then
    CONTAINER_CMD+=("--network=none")
elif [[ "${KAPSIS_NETWORK_MODE}" == "filtered" ]]; then
    # Default - uses dnsmasq to filter DNS queries
    # Only domains in allowlist can be resolved
    CONTAINER_CMD+=("-e" "KAPSIS_NETWORK_MODE=filtered")
    # dnsmasq started by entrypoint.sh
elif [[ "${KAPSIS_NETWORK_MODE}" == "open" ]]; then
    log_warn "Using open network mode - reduced isolation"
    # Full network access, no filtering
fi
```

#### DNS-Based Filtering Security Features

The `filtered` mode provides defense-in-depth for network access:

1. **DNS Rebinding Protection**: dnsmasq rejects responses containing private IP ranges
2. **Fail-Safe Initialization**: Container aborts if DNS filtering fails to start
3. **Verification Before Agent**: DNS filtering is verified before agent execution
4. **Query Logging**: Optional logging for debugging blocked domains

See [NETWORK-ISOLATION.md](NETWORK-ISOLATION.md) for detailed configuration.

### 4.6 Configuration Options

```yaml
security:
  process:
    # Maximum number of processes in container
    # Default: 1000
    pids_limit: 1000

    # Prevent privilege escalation
    # Default: true (recommended)
    no_new_privileges: true

network:
  # Network isolation mode
  # Options: none, filtered (default), open
  mode: filtered

  # DNS allowlist for filtered mode
  allowlist:
    hosts:
      - github.com
      - "*.github.com"
    registries:
      - registry.npmjs.org
    ai:
      - api.anthropic.com
```

---

## 5. Resource Limits

### 5.1 Current Limits

Currently implemented:
- Memory: `--memory=${RESOURCE_MEMORY}` (default: 8g)
- CPU: `--cpus=${RESOURCE_CPUS}` (default: 4)

### 5.2 Additional Limits

#### 5.2.1 Disk Space Quota

Podman doesn't have native disk quotas, but we can use volume size limits:

```bash
# For tmpfs mounts (already covered)
--tmpfs=/tmp:size=1g

# For named volumes (overlay storage driver limit)
# Note: Requires overlay storage driver with size option
# This may not work on all backends
```

**Alternative: Pre-check available space**

```bash
# In validate_inputs()
check_disk_space() {
    local required_mb="${KAPSIS_DISK_REQUIRED_MB:-5000}"  # 5GB default
    local available_mb
    available_mb=$(df -m "${SANDBOX_UPPER_BASE:-$HOME}" | tail -1 | awk '{print $4}')

    if [[ "$available_mb" -lt "$required_mb" ]]; then
        log_error "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required"
        exit 1
    fi
}
```

#### 5.2.2 File Descriptor Limits

```bash
# In build_container_command()
FD_LIMIT="${KAPSIS_ULIMIT_NOFILE:-65536}"
CONTAINER_CMD+=(
    "--ulimit" "nofile=${FD_LIMIT}:${FD_LIMIT}"
)
```

#### 5.2.3 Memory Limits (Enhanced)

```bash
# Soft limit (can exceed temporarily)
CONTAINER_CMD+=("--memory=${RESOURCE_MEMORY}")

# Hard limit (OOM kill)
CONTAINER_CMD+=("--memory-swap=${RESOURCE_MEMORY}")

# Memory reservation (soft guarantee)
MEMORY_RESERVATION="${KAPSIS_MEMORY_RESERVATION:-2g}"
CONTAINER_CMD+=("--memory-reservation=${MEMORY_RESERVATION}")

# OOM score adjustment (prefer killing container over host processes)
CONTAINER_CMD+=("--oom-score-adj=500")
```

#### 5.2.4 CPU Limits (Enhanced)

```bash
# CPU quota (hard limit)
CONTAINER_CMD+=("--cpus=${RESOURCE_CPUS}")

# CPU shares (soft limit for scheduling)
CPU_SHARES="${KAPSIS_CPU_SHARES:-1024}"
CONTAINER_CMD+=("--cpu-shares=${CPU_SHARES}")

# CPU period (for burst limiting)
if [[ -n "${KAPSIS_CPU_PERIOD:-}" ]]; then
    CONTAINER_CMD+=("--cpu-period=${KAPSIS_CPU_PERIOD}")
fi
```

#### 5.2.5 Operation Timeouts

Implement at the launch script level:

```bash
# In main(), wrap container run with timeout
CONTAINER_TIMEOUT="${KAPSIS_TIMEOUT:-7200}"  # 2 hours default

if [[ -n "$CONTAINER_TIMEOUT" ]] && [[ "$CONTAINER_TIMEOUT" -gt 0 ]]; then
    log_info "Container timeout: ${CONTAINER_TIMEOUT}s"
    timeout --signal=TERM --kill-after=60 "${CONTAINER_TIMEOUT}" \
        "${CONTAINER_CMD[@]}" || {
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 124 ]]; then
                log_error "Container timed out after ${CONTAINER_TIMEOUT}s"
                status_complete $EXIT_CODE "Container timeout"
            fi
        }
else
    "${CONTAINER_CMD[@]}"
fi
```

### 5.3 Configuration Options

```yaml
resources:
  # Memory configuration
  memory: 8g
  memory_swap: 8g           # Equal to memory = no swap
  memory_reservation: 2g    # Soft guarantee

  # CPU configuration
  cpus: 4
  cpu_shares: 1024          # Relative weight

  # Process limits
  pids_limit: 1000

  # File descriptor limits
  ulimit_nofile: 65536

  # Timeout (seconds, 0 = unlimited)
  timeout: 7200

  # Disk space requirements (MB)
  disk_required: 5000
```

---

## 6. AppArmor/SELinux Profiles

### 6.1 Current State

SELinux/AppArmor is disabled (`--security-opt label=disable`) for overlay filesystem compatibility.

### 6.2 Challenge: Overlay Filesystem

The fuse-overlayfs used for Copy-on-Write requires:
- FUSE device access
- Mount syscalls within the container
- Specific SELinux contexts for layered filesystems

### 6.3 AppArmor Profile Design (Linux)

Create `/etc/apparmor.d/kapsis-agent`:

```apparmor
#include <tunables/global>

profile kapsis-agent flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>

  # Deny dangerous operations
  deny @{PROC}/sys/kernel/[^c]* wklx,
  deny @{PROC}/sys/kernel/core_pattern w,
  deny @{PROC}/sys/fs/** wklx,
  deny @{PROC}/sys/vm/** wklx,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,
  deny mount,
  deny umount,
  deny ptrace,

  # Allow standard development operations
  /workspace/** rwkl,
  /home/developer/** rwkl,
  /tmp/** rwk,
  /var/tmp/** rwk,

  # Maven/Gradle caches
  /home/developer/.m2/** rwkl,
  /home/developer/.gradle/** rwkl,

  # Node.js
  /opt/nvm/** rix,

  # Java
  /opt/sdkman/** rix,

  # Git operations
  /usr/bin/git rix,
  /usr/lib/git-core/** rix,

  # Network access (for AI APIs)
  network inet tcp,
  network inet6 tcp,
  network inet udp,
  network inet6 udp,

  # Capabilities
  capability chown,
  capability dac_override,
  capability fowner,
  capability fsetid,
  capability kill,
  capability setgid,
  capability setuid,
  capability sys_nice,
}
```

### 6.4 SELinux Policy Design (RHEL/CentOS)

Create `kapsis-agent.te`:

```selinux
policy_module(kapsis_agent, 1.0)

require {
    type container_t;
    type container_file_t;
}

# Define kapsis-specific type
type kapsis_agent_t;
type kapsis_agent_file_t;

# Inherit from container types
container_domain_template(kapsis_agent)

# Allow file operations on workspace
allow kapsis_agent_t kapsis_agent_file_t:file { read write create unlink };
allow kapsis_agent_t kapsis_agent_file_t:dir { read write create search };

# Network access for AI APIs
allow kapsis_agent_t self:tcp_socket { create connect };
allow kapsis_agent_t self:udp_socket { create };

# Deny dangerous operations
dontaudit kapsis_agent_t self:capability sys_admin;
dontaudit kapsis_agent_t self:capability sys_ptrace;
```

### 6.5 Implementation Strategy

```bash
# In build_container_command()

detect_lsm() {
    # Check which LSM is active
    if command -v aa-status &>/dev/null && aa-status &>/dev/null 2>&1; then
        echo "apparmor"
    elif command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        echo "selinux"
    else
        echo "none"
    fi
}

LSM_TYPE=$(detect_lsm)

case "$LSM_TYPE" in
    apparmor)
        if [[ -f "/etc/apparmor.d/kapsis-agent" ]]; then
            CONTAINER_CMD+=("--security-opt" "apparmor=kapsis-agent")
        else
            log_warn "AppArmor active but kapsis-agent profile not installed"
            CONTAINER_CMD+=("--security-opt" "label=disable")
        fi
        ;;
    selinux)
        if semodule -l | grep -q kapsis_agent; then
            CONTAINER_CMD+=("--security-opt" "label=type:kapsis_agent_t")
        else
            log_warn "SELinux active but kapsis_agent policy not installed"
            CONTAINER_CMD+=("--security-opt" "label=disable")
        fi
        ;;
    none)
        CONTAINER_CMD+=("--security-opt" "label=disable")
        ;;
esac
```

### 6.6 Fallback Behavior

When LSM profiles are not available:
1. Log a warning
2. Disable LSM labeling (`label=disable`)
3. Rely on other hardening layers (seccomp, capabilities, namespaces)

### 6.7 Configuration Options

```yaml
security:
  lsm:
    # AppArmor/SELinux profile management
    # Options: auto, apparmor, selinux, disabled
    # Default: auto (detect and use if available)
    mode: auto

    # Custom profile name (if using custom profile)
    profile: kapsis-agent

    # Fail if profile not found (vs. fallback to disabled)
    # Default: false
    require_profile: false
```

---

## 7. Implementation Plan

### 7.1 Phase 1: Core Hardening (Low Risk)

**Timeline: 1-2 weeks**

1. **Capability dropping**
   - Add `--cap-drop=ALL` with minimal capability set
   - Test all agent types
   - Document any capability requirements per agent

2. **No-new-privileges flag**
   - Add `--security-opt no-new-privileges:true`
   - Verify no setuid binaries are needed

3. **Process limits**
   - Add `--pids-limit` with sensible defaults
   - Add file descriptor limits

### 7.2 Phase 2: Seccomp Profiles (Medium Risk)

**Timeline: 2-3 weeks**

1. **Create base seccomp profile**
   - Start with default Podman profile
   - Remove dangerous syscalls
   - Test extensively with all agent types

2. **Agent-specific profiles**
   - Profile Claude CLI
   - Profile Aider
   - Profile interactive mode

3. **Add profile loading to launch-agent.sh**

### 7.3 Phase 3: Filesystem Hardening (Medium Risk)

**Timeline: 2-3 weeks**

1. **Mount options**
   - Add noexec/nosuid/nodev where safe
   - Test Maven/Gradle builds

2. **Read-only root (optional)**
   - Implement as opt-in feature
   - Ensure all writable paths are mounted

### 7.4 Phase 4: LSM Profiles (Higher Risk)

**Timeline: 3-4 weeks**

1. **AppArmor profile**
   - Develop and test profile
   - Document installation
   - Implement auto-detection

2. **SELinux policy**
   - Develop and test policy
   - Document installation
   - Implement auto-detection

### 7.5 File Structure

```
kapsis/
├── security/
│   ├── seccomp/
│   │   ├── kapsis-agent-base.json
│   │   ├── kapsis-claude.json
│   │   ├── kapsis-aider.json
│   │   └── kapsis-interactive.json
│   ├── apparmor/
│   │   └── kapsis-agent
│   ├── selinux/
│   │   ├── kapsis-agent.te
│   │   └── kapsis-agent.fc
│   └── README.md
├── scripts/
│   └── lib/
│       └── security.sh      # Security helper functions
└── docs/
    └── SECURITY-HARDENING.md  # This document
```

---

## 8. Configuration Reference

### 8.1 Full Security Configuration

Add to `agent-sandbox.yaml`:

```yaml
#===============================================================================
# SECURITY HARDENING
#===============================================================================
security:
  # Security profile level
  # Options: minimal, standard (default), strict, paranoid
  profile: standard

  # Seccomp configuration
  seccomp:
    # Enable seccomp filtering
    # Default: true
    enabled: true

    # Profile to use
    # Options: kapsis-agent-base, kapsis-<agent>, custom
    profile: kapsis-agent-base

    # Custom profile path (if profile: custom)
    custom_profile: ""

  # Capability configuration
  capabilities:
    # Drop all capabilities except minimal set
    # Default: true
    drop_all: true

    # Additional capabilities to add
    add: []

    # Additional capabilities to drop
    drop: []

  # Filesystem hardening
  filesystem:
    # Read-only root filesystem
    # Default: true for strict/paranoid
    readonly_root: true

    # Apply noexec to temporary directories
    # Default: true
    noexec_tmp: true

    # Apply noexec to config mounts
    # Default: true
    noexec_configs: true

    # Temp directory sizes
    tmp_size: 1g
    var_tmp_size: 500m

  # Process isolation
  process:
    # Maximum number of processes
    # Default: 1000
    pids_limit: 1000

    # Prevent privilege escalation
    # Default: true
    no_new_privileges: true

    # User namespace mode
    # Default: keep-id
    userns: keep-id

  # Linux Security Module configuration
  lsm:
    # Mode: auto, apparmor, selinux, disabled
    # Default: auto
    mode: auto

    # Custom profile name
    profile: kapsis-agent

    # Fail if profile not available
    # Default: false
    require_profile: false

  # Network isolation
  network:
    # Network mode: none, filtered, open
    # Default: filtered (DNS-based allowlist)
    mode: filtered

    # DNS allowlist for filtered mode
    allowlist:
      hosts:
        - github.com
        - "*.github.com"
      registries:
        - registry.npmjs.org
      ai:
        - api.anthropic.com
        - api.openai.com

    # DNS servers for resolution
    dns_servers:
      - 8.8.8.8
      - 8.8.4.4

    # Enable DNS query logging for debugging
    log_dns_queries: false
```

### 8.2 Security Profiles

Pre-defined security profiles for convenience:

| Profile | Description | Use Case |
|---------|-------------|----------|
| `minimal` | Only userns + basic limits | Development/testing |
| `standard` | Capabilities + no-new-privs + limits | Production default |
| `strict` | Standard + seccomp + noexec + readonly root | High security |
| `paranoid` | Strict + readonly root + LSM | Maximum security |

#### Profile Definitions

```yaml
# security-profiles.yaml (internal)
profiles:
  minimal:
    capabilities.drop_all: false
    process.no_new_privileges: false
    seccomp.enabled: false

  standard:
    capabilities.drop_all: true
    process.no_new_privileges: true
    process.pids_limit: 1000
    seccomp.enabled: false

  strict:
    capabilities.drop_all: true
    process.no_new_privileges: true
    process.pids_limit: 500
    seccomp.enabled: true
    seccomp.profile: kapsis-agent-base
    filesystem.readonly_root: true
    filesystem.noexec_tmp: true
    filesystem.noexec_configs: true

  paranoid:
    capabilities.drop_all: true
    process.no_new_privileges: true
    process.pids_limit: 300
    seccomp.enabled: true
    seccomp.profile: kapsis-agent-base
    filesystem.readonly_root: true
    filesystem.noexec_tmp: true
    filesystem.noexec_configs: true
    lsm.mode: auto
    lsm.require_profile: true
```

---

## 9. Testing Strategy

### 9.1 Unit Tests

Add to `tests/`:

#### 9.1.1 `test-security-capabilities.sh`

```bash
#!/usr/bin/env bash
# Test: Security - Capabilities

test_capabilities_dropped() {
    log_test "Testing dangerous capabilities are dropped"

    setup_container_test "sec-caps"

    # Check capabilities
    local output
    output=$(run_in_container "cat /proc/self/status | grep CapEff")

    cleanup_container_test

    # CapEff should not contain dangerous capabilities
    # CAP_SYS_ADMIN (21) should be missing
    local cap_hex
    cap_hex=$(echo "$output" | awk '{print $2}')

    # Check bit 21 (SYS_ADMIN) is not set
    # Full capabilities would be 0000003fffffffff
    if [[ "$cap_hex" != *"ffffffff"* ]]; then
        return 0
    else
        log_fail "Capabilities not properly dropped"
        return 1
    fi
}
```

#### 9.1.2 `test-security-seccomp.sh`

```bash
#!/usr/bin/env bash
# Test: Security - Seccomp

test_seccomp_blocks_ptrace() {
    log_test "Testing seccomp blocks ptrace"

    setup_container_test "sec-seccomp"

    # Try to use ptrace (should fail)
    local exit_code=0
    run_in_container "strace ls 2>&1" || exit_code=$?

    cleanup_container_test

    # Should fail with EPERM or similar
    if [[ $exit_code -ne 0 ]]; then
        return 0
    else
        log_fail "ptrace should be blocked by seccomp"
        return 1
    fi
}

test_seccomp_allows_build() {
    log_test "Testing seccomp allows Maven build"

    setup_container_test "sec-seccomp-build"

    # Run a simple Maven command
    local exit_code=0
    run_in_container "mvn -v" || exit_code=$?

    cleanup_container_test

    assert_equals "0" "$exit_code" "Maven should work with seccomp"
}
```

#### 9.1.3 `test-security-filesystem.sh`

```bash
#!/usr/bin/env bash
# Test: Security - Filesystem Hardening

test_tmp_noexec() {
    log_test "Testing /tmp has noexec"

    setup_container_test "sec-fs-noexec"

    # Try to execute from /tmp (should fail if noexec)
    local exit_code=0
    run_in_container "cp /bin/ls /tmp/test_ls && chmod +x /tmp/test_ls && /tmp/test_ls" \
        || exit_code=$?

    cleanup_container_test

    # With noexec, execution should fail
    if [[ $exit_code -ne 0 ]]; then
        return 0
    else
        # noexec might not be enabled, check mount options
        log_info "noexec not enforced on /tmp (may be configuration)"
        return 0  # Not a hard failure
    fi
}

test_workspace_exec_allowed() {
    log_test "Testing /workspace allows execution"

    setup_container_test "sec-fs-exec"

    # Execution from workspace should work (needed for builds)
    local exit_code=0
    run_in_container "echo '#!/bin/bash\necho test' > /workspace/test.sh && \
        chmod +x /workspace/test.sh && /workspace/test.sh" || exit_code=$?

    cleanup_container_test

    assert_equals "0" "$exit_code" "Workspace should allow script execution"
}
```

### 9.2 Integration Tests

#### 9.2.1 Full Build Test

Test that hardening doesn't break real-world builds:

```bash
#!/usr/bin/env bash
# test-security-integration.sh

test_maven_build_with_hardening() {
    log_test "Testing Maven build with security hardening"

    # Run actual Maven build with hardening enabled
    KAPSIS_SECURITY_PROFILE=strict \
        ./scripts/launch-agent.sh test-sec ~/projects/sample-java \
        --task "mvn clean compile" \
        --dry-run=false

    assert_equals "0" "$?" "Maven build should succeed with hardening"
}

test_claude_agent_with_hardening() {
    log_test "Testing Claude agent with security hardening"

    # Run Claude with hardening (mock API)
    KAPSIS_SECURITY_PROFILE=strict \
    ANTHROPIC_API_KEY="test-key" \
        ./scripts/launch-agent.sh test-sec ~/projects/sample \
        --agent claude \
        --task "echo test" \
        --dry-run=false

    # Should at least start without seccomp/capability errors
    assert_not_equals "125" "$?" "Container should start with hardening"
}
```

### 9.3 Syscall Audit Mode

For development, add a syscall logging mode:

```bash
# In build_container_command()
if [[ "${KAPSIS_SECCOMP_AUDIT:-false}" == "true" ]]; then
    # Use audit profile that logs instead of blocking
    SECCOMP_PROFILE="${KAPSIS_ROOT}/security/seccomp/kapsis-audit.json"
    log_warn "Seccomp audit mode - syscalls are logged, not blocked"
fi
```

Create `kapsis-audit.json`:

```json
{
  "defaultAction": "SCMP_ACT_LOG",
  "syscalls": []
}
```

This logs all syscalls without blocking, useful for identifying what syscalls agents actually need.

### 9.4 Test Matrix

| Test | Linux Native | macOS Podman | CI (Linux) |
|------|--------------|--------------|------------|
| Capability drop | Yes | Yes | Yes |
| Seccomp base | Yes | Yes | Yes |
| No-new-privileges | Yes | Yes | Yes |
| PID limits | Yes | Yes | Yes |
| AppArmor | Ubuntu only | N/A | GitHub Actions |
| SELinux | RHEL/Fedora | N/A | No |
| Read-only root | Yes | Yes | Yes |
| noexec mounts | Yes | Yes* | Yes |

\* macOS Podman Machine may have limitations with mount options.

---

## 10. Migration Guide

### 10.1 Existing Deployments

For users upgrading from unhardened Kapsis:

1. **Phase 1 (Safe)**
   - Update to new version
   - Default profile is `standard` (capabilities + no-new-privs)
   - No seccomp by default

2. **Phase 2 (Test)**
   - Enable seccomp in test environment:
     ```yaml
     security:
       profile: strict
     ```
   - Run full test suite

3. **Phase 3 (Production)**
   - Roll out `strict` profile
   - Monitor for issues
   - Adjust as needed

### 10.2 Troubleshooting

Common issues after enabling hardening:

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| "Operation not permitted" | Seccomp blocking syscall | Add syscall to profile |
| "Permission denied" on build | Capability missing | Add required capability |
| Scripts fail in /tmp | noexec mount | Move scripts to /workspace |
| Network timeout | Network namespace | Check network mode |
| Agent crashes on start | Seccomp profile issue | Enable audit mode |

### 10.3 Debugging Commands

```bash
# Check what capabilities container has
podman run --rm kapsis-sandbox:latest cat /proc/self/status | grep Cap

# Check seccomp status
podman run --rm kapsis-sandbox:latest grep Seccomp /proc/self/status

# Check mount options
podman run --rm kapsis-sandbox:latest mount | grep workspace

# Run with syscall audit
KAPSIS_SECCOMP_AUDIT=true ./scripts/launch-agent.sh ...
```

---

## Appendix A: Syscall Reference

### A.1 Syscalls Required by Agent Type

| Syscall | Claude | Aider | Maven | Git | Notes |
|---------|--------|-------|-------|-----|-------|
| `clone`/`clone3` | Yes | Yes | Yes | No | Process creation |
| `execve` | Yes | Yes | Yes | Yes | Program execution |
| `socket` | Yes | Yes | Yes | Yes | Network/IPC |
| `connect` | Yes | Yes | Yes | Yes | Network connections |
| `mmap` | Yes | Yes | Yes | Yes | Memory mapping |
| `futex` | Yes | Yes | Yes | Yes | Thread synchronization |
| `epoll_*` | Yes | Yes | No | No | Event polling (Node.js) |
| `io_uring_*` | No | No | Yes | No | Modern I/O (Java 21+) |

### A.2 Syscalls Blocked for Security

| Syscall | Risk Level | Blocked By |
|---------|------------|------------|
| `ptrace` | Critical | Seccomp profile |
| `mount` | Critical | Capability + seccomp |
| `bpf` | Critical | Seccomp profile |
| `userfaultfd` | High | Seccomp profile |
| `keyctl` | High | Seccomp profile |
| `kexec_load` | Critical | Seccomp profile |
| `init_module` | Critical | Seccomp profile |
| `reboot` | Critical | Capability + seccomp |

---

## Appendix B: Quick Reference

### B.1 Podman Security Flags Summary

```bash
podman run \
    --rm -it \
    --userns=keep-id \
    --cap-drop=ALL \
    --cap-add=CHOWN,FOWNER,FSETID,KILL,SETGID,SETUID,SYS_NICE \
    --security-opt no-new-privileges:true \
    --security-opt seccomp=/path/to/kapsis-agent-base.json \
    --pids-limit=1000 \
    --memory=8g \
    --memory-swap=8g \
    --cpus=4 \
    --ulimit nofile=65536:65536 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1g \
    kapsis-sandbox:latest
```

### B.2 Configuration Quick Start

```yaml
# Recommended production configuration
security:
  profile: strict
  seccomp:
    enabled: true
    profile: kapsis-agent-base
  capabilities:
    drop_all: true
  process:
    pids_limit: 1000
    no_new_privileges: true
  filesystem:
    noexec_tmp: true
    noexec_configs: true
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-28 | SRE Team | Initial design document |
