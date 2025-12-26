# Network Isolation for Kapsis

This document describes the smart network isolation solution for Kapsis that enables secure, configurable network access for AI coding agents.

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

1. **Container startup**: dnsmasq starts with allowlist configuration
2. **DNS queries**: Container's resolv.conf points to local dnsmasq
3. **Allowed hosts**: Forward to upstream DNS, return real IP
4. **Blocked hosts**: Return NXDOMAIN immediately

### Podman Integration

```bash
# Filtered mode adds:
podman run \
  --dns=127.0.0.1 \
  -v /path/to/dnsmasq.conf:/etc/dnsmasq.conf:ro \
  ...

# None mode adds:
podman run --network=none ...
```

### dnsmasq Configuration (Generated)

```
# Kapsis Network Allowlist
domain-needed
bogus-priv

# Allowed hosts (resolve normally)
server=/github.com/8.8.8.8
server=/gitlab.com/8.8.8.8
server=/npmjs.org/8.8.8.8

# Default: block everything else
address=/#/0.0.0.0
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

## Future Enhancements

- IP-based filtering (iptables/nftables)
- Dynamic allowlists from external policy server
- Network observability metrics
- TLS certificate pinning for known hosts
- SOCKS5 proxy support
