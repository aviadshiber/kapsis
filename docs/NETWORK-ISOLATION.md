# Network Isolation for Kapsis

This document describes the smart network isolation solution for Kapsis that enables secure, configurable network access for AI coding agents.

## Implementation Status

| Mode | Status | Description |
|------|--------|-------------|
| `none` | **Implemented** | Complete network isolation |
| `filtered` | **Implemented** (v1.1.0) | DNS-based allowlist filtering |
| `open` | **Implemented** | Unrestricted (default) |

## Problem Statement

By default, Kapsis containers have unrestricted network access, which creates security risks:
- Agents can contact arbitrary servers (data exfiltration risk)
- Agents can download malicious code from unknown sources
- No audit trail of network activity

However, agents **need** network access for legitimate purposes:
- Git operations (clone, push, fetch) to GitHub/GitLab/Bitbucket
- Package downloads (npm, pip, Maven, Gradle)
- Corporate artifact repositories

## Solution: DNS-Based Filtering

We use DNS-based filtering via dnsmasq inside the container:
- **Allowed hosts** resolve normally
- **Unknown hosts** return NXDOMAIN (DNS failure)
- Works with rootless Podman (no kernel modules needed)

```
┌─────────────────────────────────────────────────────────────┐
│ Container                                                   │
├─────────────────────────────────────────────────────────────┤
│  Agent Process                                              │
│       │                                                     │
│       ├─→ git clone github.com ────→ ✓ Allowed             │
│       ├─→ npm install ───────────────→ ✓ Allowed           │
│       └─→ curl malicious.com ──────→ ✗ NXDOMAIN            │
│                                                             │
│  dnsmasq (DNS Resolver with allowlist)                     │
└─────────────────────────────────────────────────────────────┘
```

## Configuration Schema

Add to your `agent-sandbox.yaml`:

```yaml
#===============================================================================
# NETWORK ISOLATION
#===============================================================================
network:
  # Isolation mode
  # Options:
  #   none     - No network access (--network=none)
  #   filtered - DNS-based allowlist (recommended)
  #   open     - Unrestricted access (not recommended)
  mode: filtered

  # DNS allowlist (only used in 'filtered' mode)
  allowlist:
    # Git hosting providers
    hosts:
      - github.com
      - "*.github.com"
      - gitlab.com
      - "*.gitlab.com"
      - bitbucket.org
      - "*.bitbucket.org"
      - dev.azure.com
      - ssh.dev.azure.com

    # Package registries
    registries:
      - npmjs.org
      - registry.npmjs.org
      - registry.yarnpkg.com
      - pypi.org
      - files.pythonhosted.org
      - repo1.maven.org
      - plugins.gradle.org

    # Corporate/custom hosts (user-configured)
    custom:
      - "artifactory.company.com"
      - "nexus.company.com"

  # DNS servers (defaults to host resolvers)
  dns_servers:
    - 8.8.8.8
    - 8.8.4.4

  # Optional: HTTP/HTTPS proxy for corporate networks
  proxy:
    enabled: false
    http_proxy: "http://proxy.company.com:3128"
    https_proxy: "http://proxy.company.com:3128"
    no_proxy: "localhost,127.0.0.1,.company.com"

  # Allowed outbound ports
  allowed_ports:
    - 22    # SSH (git)
    - 80    # HTTP
    - 443   # HTTPS
    - 9418  # Git protocol

  # Enable DNS query logging for debugging
  log_dns_queries: false
```

## Usage Examples

### Example 1: Standard Development (Recommended)

```yaml
network:
  mode: filtered
  allowlist:
    hosts:
      - github.com
      - "*.github.com"
    registries:
      - npmjs.org
      - pypi.org
      - repo1.maven.org
```

### Example 2: Enterprise with Private Registries

```yaml
network:
  mode: filtered
  allowlist:
    hosts:
      - github.com
      - "*.github.company.com"
    registries:
      - npmjs.org
      - pypi.org
    custom:
      - "artifactory.company.com"
      - "npm.company.com"
  proxy:
    enabled: true
    http_proxy: "http://proxy.company.com:3128"
    https_proxy: "http://proxy.company.com:3128"
```

### Example 3: Maximum Security (No Network)

```yaml
network:
  mode: none
```

Use when:
- Analyzing untrusted code
- Compliance requirements demand air-gapped operation
- All dependencies are pre-cached

## Implementation Details

### How It Works

1. **Container startup**: `entrypoint.sh` detects `KAPSIS_NETWORK_MODE=filtered`
2. **DNS filter init**: Sources `dns-filter.sh` and calls `dns_filter_init()`
3. **Config generation**: Generates dnsmasq config from `KAPSIS_DNS_ALLOWLIST` env var
4. **dnsmasq start**: Starts dnsmasq listening on 127.0.0.1:53
5. **resolv.conf update**: Points to local dnsmasq for all DNS queries
6. **Runtime**: Allowed hosts forward to upstream DNS, blocked hosts return 0.0.0.0

### Key Files

| File | Purpose |
|------|---------|
| `scripts/lib/dns-filter.sh` | DNS filtering library |
| `configs/network-allowlist.yaml` | Default allowlist configuration |
| `scripts/entrypoint.sh` | Starts DNS filter on container boot |
| `scripts/launch-agent.sh` | Parses config and passes env vars |

### Podman Integration

```bash
# Filtered mode passes environment variables:
podman run \
  -e KAPSIS_NETWORK_MODE=filtered \
  -e KAPSIS_DNS_ALLOWLIST="github.com,*.github.com,npmjs.org" \
  -e KAPSIS_DNS_SERVERS="8.8.8.8,8.8.4.4" \
  ...

# None mode adds network isolation:
podman run --network=none ...
```

### dnsmasq Configuration (Generated)

The `dns-filter.sh` library generates this configuration:

```
# Kapsis DNS Filter Configuration
domain-needed
bogus-priv
no-resolv
no-poll
no-hosts
listen-address=127.0.0.1
bind-interfaces
port=53
cache-size=1000

# Allowed domains (forward to upstream DNS)
server=/github.com/8.8.8.8
server=/.github.com/8.8.8.8    # Wildcard: *.github.com
server=/gitlab.com/8.8.8.8
server=/npmjs.org/8.8.8.8

# Default: block everything else (return 0.0.0.0)
address=/#/0.0.0.0
address=/::/::
```

## Trade-offs

| Aspect | Benefit | Limitation |
|--------|---------|------------|
| Security | Blocks unknown hosts | DNS-only (IP addresses bypass) |
| Performance | ~2ms per query | Negligible for most workloads |
| Compatibility | Works with rootless | Requires dnsmasq in image |
| Flexibility | Per-agent config | Static allowlist (no dynamic) |

## Security Considerations

### What This Protects Against
- Data exfiltration to unknown hosts
- Drive-by downloads from malicious URLs
- Command & Control communication
- Cryptocurrency mining pools

### What This Does NOT Protect Against
- Direct IP connections (rare for legitimate tools)
- Allowed host compromise (GitHub itself is malicious)
- DNS tunneling through allowed domains
- Local network attacks

### Defense in Depth

Network isolation is one layer. Combine with:
- Container isolation (rootless Podman)
- Filesystem isolation (CoW overlays)
- Credential isolation (keychain integration)
- Code review (PR workflow)

## Troubleshooting

### Agent Can't Reach GitHub

1. Check allowlist includes `github.com` and `*.github.com`
2. Enable `log_dns_queries: true` to see what's being blocked
3. Verify dnsmasq is running: `ps aux | grep dnsmasq`

### Package Install Fails

Common missing domains:
- npm: `registry.npmjs.org`, `npmjs.org`
- pip: `pypi.org`, `files.pythonhosted.org`
- Maven: `repo1.maven.org`, `plugins.gradle.org`

### Corporate Proxy Issues

Ensure `no_proxy` includes your internal domains:
```yaml
no_proxy: "localhost,127.0.0.1,.company.com,.internal"
```

## Migration from Open Network

1. Start with `mode: open` (existing behavior)
2. Enable `log_dns_queries: true`
3. Run your typical workflows
4. Review logs to identify needed hosts
5. Build allowlist from observed traffic
6. Switch to `mode: filtered`
7. Test workflows and add missing hosts

## SSH Host Key Verification

DNS filtering alone doesn't fully protect SSH connections. After DNS resolves, SSH connects
directly to IP addresses. A compromised DNS could redirect to a malicious server.

### Solution: Automatic Key Verification with Keychain

Kapsis automatically verifies SSH host keys against official sources and caches them in Keychain:

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    SSH Host Key Verification Flow                          │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  Container Startup                                                         │
│       │                                                                    │
│       ▼                                                                    │
│  ┌──────────────────────────────────┐                                      │
│  │ Check Keychain for cached keys   │◄── kapsis-ssh-known-hosts service   │
│  └──────────────────────────────────┘                                      │
│       │                                                                    │
│       ├── Found & not expired ──────────► Use cached keys                 │
│       │                                                                    │
│       ▼                                                                    │
│  ┌──────────────────────────────────┐                                      │
│  │ Fetch official fingerprints      │◄── api.github.com/meta              │
│  │ from provider APIs               │◄── bitbucket.org/site/ssh           │
│  └──────────────────────────────────┘◄── gitlab.com/api/v4/metadata       │
│       │                                                                    │
│       ▼                                                                    │
│  ┌──────────────────────────────────┐                                      │
│  │ ssh-keyscan to get actual keys   │                                      │
│  └──────────────────────────────────┘                                      │
│       │                                                                    │
│       ▼                                                                    │
│  ┌──────────────────────────────────┐                                      │
│  │ Verify fingerprint matches       │                                      │
│  │ official API response            │                                      │
│  └──────────────────────────────────┘                                      │
│       │                                                                    │
│       ├── Match ────────────► Store in Keychain + use key                 │
│       │                                                                    │
│       └── MISMATCH ─────────► FATAL ERROR (possible MITM attack!)         │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

### Configuration

```yaml
network:
  mode: filtered

  ssh:
    # Verification mode:
    #   auto     - Verify against official APIs (recommended)
    #   disabled - No SSH key verification
    mode: auto

    # Providers with automatic verification (have official meta APIs)
    auto_verify:
      - github.com      # Uses api.github.com/meta
      - bitbucket.org   # Uses bitbucket.org/site/ssh
      - gitlab.com      # Uses gitlab.com/api/v4/metadata

    # Custom hosts (no official API - must provide fingerprint)
    custom_hosts:
      - host: "git.company.com"
        fingerprint: "SHA256:abc123..."  # Get from your admin

    # Keychain integration
    keychain:
      enabled: true
      service: "kapsis-ssh-known-hosts"
      ttl: 86400  # Refresh keys every 24 hours (seconds)

    # SSH client hardening (applied to container ssh_config)
    config:
      StrictHostKeyChecking: "yes"
      UserKnownHostsFile: "/etc/ssh/ssh_known_hosts"
      ForwardAgent: "no"
      ForwardX11: "no"
      PermitLocalCommand: "no"
```

### How Keys Are Obtained

| Provider | Official Source | API Endpoint |
|----------|-----------------|--------------|
| GitHub | ✅ | `https://api.github.com/meta` → `ssh_key_fingerprints` |
| GitLab | ✅ | `https://gitlab.com/api/v4/metadata` |
| Bitbucket Cloud | ✅ | `https://bitbucket.org/site/ssh` |
| Enterprise/Custom | ⚠️ TOFU | Interactive verification with Keychain storage |

### Enterprise Git Servers

For enterprise or self-hosted Git servers, use the interactive
Trust On First Use (TOFU) mode:

```bash
# Add enterprise Git server
./scripts/lib/ssh-keychain.sh add-host git.company.com
```

This will:
1. Scan the SSH host keys from the server
2. Display fingerprints for verification with your IT administrator
3. Ask for confirmation before trusting
4. Store the verified fingerprint in `~/.kapsis/ssh-hosts.conf`
5. Cache the full key in macOS Keychain

```bash
# List configured custom hosts
./scripts/lib/ssh-keychain.sh list-hosts

# Example output:
# Custom SSH hosts (~/.kapsis/ssh-hosts.conf):
# git.company.com SHA256:abc123...
```

The config file (`~/.kapsis/ssh-hosts.conf`) persists across sessions and can be
shared with team members (fingerprints are public info, not secrets).

### Security Benefits

1. **No hardcoded keys** - Keys fetched and verified automatically
2. **MITM protection** - Fingerprints verified against official APIs before trust
3. **Persistent cache** - Keychain survives container restarts
4. **Automatic refresh** - TTL ensures keys stay current
5. **Audit trail** - Logs when keys are verified/refreshed

### Implementation Details

```bash
# 1. Fetch official fingerprints from GitHub
GITHUB_FINGERPRINTS=$(curl -s https://api.github.com/meta | jq '.ssh_key_fingerprints')

# 2. Scan actual keys from server
ACTUAL_KEYS=$(ssh-keyscan -t ed25519,rsa github.com 2>/dev/null)

# 3. Compute fingerprint of scanned key
ACTUAL_FP=$(echo "$ACTUAL_KEYS" | ssh-keygen -lf - | awk '{print $2}')

# 4. Verify match
if echo "$GITHUB_FINGERPRINTS" | grep -q "${ACTUAL_FP#SHA256:}"; then
    echo "✓ Key verified against official GitHub fingerprints"
    security add-generic-password -s "kapsis-ssh-known-hosts" -a "github.com" -w "$ACTUAL_KEYS"
else
    echo "✗ FINGERPRINT MISMATCH - Possible MITM attack!"
    exit 1
fi
```

### Secret Storage (Platform-compatible)

Keys are securely stored using the native secret service:

| Platform | Backend | Tool |
|----------|---------|------|
| macOS | Keychain | `security` |
| Linux (desktop) | GNOME Keyring / KDE Wallet | `secret-tool` |
| Linux (headless) | File-based (700/600 perms) | Fallback |

```bash
# macOS: View/clear cached keys
security find-generic-password -s "kapsis-ssh-known-hosts" -a "github.com" -w
security delete-generic-password -s "kapsis-ssh-known-hosts" -a "github.com"

# Linux (with secret-tool): View/clear cached keys
secret-tool lookup service "kapsis-ssh-known-hosts" host "github.com"
secret-tool clear service "kapsis-ssh-known-hosts" host "github.com"

# Linux (fallback): Keys stored in ~/.kapsis/ssh-cache/
ls -la ~/.kapsis/ssh-cache/
```

### Error Handling

| Scenario | Behavior |
|----------|----------|
| API unreachable | Use cached key if valid, else fail |
| Fingerprint mismatch | FATAL: Stop container, alert user |
| Key expired | Refresh from API |
| Custom host, no fingerprint | Fail unless `StrictHostKeyChecking: no` |

## Future Enhancements

- IP-based filtering (iptables/nftables)
- Dynamic allowlists from external policy server
- Network observability metrics
- TLS certificate pinning for known hosts
- SOCKS5 proxy support
