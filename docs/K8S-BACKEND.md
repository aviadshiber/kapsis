# K8s Backend

Run Kapsis agents as Kubernetes Pods instead of local Podman containers.

## Prerequisites

- `kubectl` configured with cluster access
- AgentRequest CRD installed: `kubectl apply -f operator/config/crd/bases/kapsis.aviadshiber.github.io_agentrequests.yaml`
- Kapsis operator running in-cluster (see [Operator Deployment](#operator-deployment))
- Container images pushed to a registry accessible from the cluster

## Usage

```bash
# Dry-run: output AgentRequest CR YAML without applying
./scripts/launch-agent.sh ~/project --backend k8s --task "implement feature" --dry-run

# Apply to cluster (requires operator running)
./scripts/launch-agent.sh ~/project --backend k8s --task "implement feature"
```

The `--backend k8s` flag switches from local Podman containers to Kubernetes Pods. All other flags (`--agent`, `--task`, `--spec`, `--branch`, `--memory`, `--cpus`, etc.) work the same way.

## How It Works

1. `launch-agent.sh` parses config and flags (same as Podman backend)
2. K8s backend (`scripts/backends/k8s.sh`) translates config into an AgentRequest CR
3. Config translator (`scripts/lib/k8s-config.sh`) converts Docker-style values to K8s format (e.g., `8g` → `8Gi`)
4. CR is applied via `kubectl apply`
5. Backend polls CR status until completion
6. Operator (in-cluster) watches CRs, creates Pods, bridges status

### Config Translation

| Kapsis Config | K8s Equivalent |
|---------------|----------------|
| `--memory 8g` | `resources.memory: "8Gi"` |
| `--cpus 4` | `resources.cpu: "4"` |
| `--task "..."` | `spec.task.inline: "..."` |
| `--branch feat/x` | `spec.git.branch: feat/x` |
| `--network filtered` | `spec.network.mode: filtered` |
| `--security strict` | `spec.security.profile: strict` |

## AgentRequest CRD

The `AgentRequest` custom resource defines a single agent execution:

```yaml
apiVersion: kapsis.aviadshiber.github.io/v1alpha1
kind: AgentRequest
metadata:
  name: kapsis-abc123
spec:
  image: kapsis-claude-cli:latest
  agent:
    type: claude-cli
    command: ["bash", "-c", "claude --task 'implement login'"]
    workdir: /workspace
  resources:
    memory: "8Gi"
    cpu: "4"
  git:
    repoUrl: https://github.com/org/repo.git       # → GIT_REPO_URL env var
    branch: feat/login                              # → KAPSIS_BRANCH env var
    baseBranch: main                                # → KAPSIS_BASE_BRANCH env var
    push: true                                      # → KAPSIS_DO_PUSH env var
    credentialSecretRef:                             # → GIT_CREDENTIAL from Secret
      name: git-credentials
      key: token
  task:
    inline: "Implement the login feature"           # → KAPSIS_TASK env var
    # Or mount from ConfigMap:
    # specConfigMapRef:                             # Mounted at /task-spec.md
    #   name: my-task-spec
    #   key: spec.md                               # Default key if omitted
  environment:
    vars:
      # KAPSIS_BACKEND, KAPSIS_AGENT_ID, and KAPSIS_AGENT_TYPE are
      # auto-injected by the operator — do not set them here.
      - name: MY_CUSTOM_VAR
        value: "example-value"
    secretRefs:
      - name: agent-api-keys                       # All keys injected as env vars
  network:
    mode: filtered                                  # Default; NetworkPolicy planned
  security:
    profile: standard
    serviceAccountName: kapsis-agent
  ttl: 3600
  podAnnotations:                                   # Optional: passed to Pod
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "kapsis-agent"
```

### Status Fields

```bash
# Check agent status
kubectl get agentrequest kapsis-abc123

# Detailed status
kubectl get agentrequest kapsis-abc123 -o yaml
```

| Field | Description |
|-------|-------------|
| `status.phase` | Pending, Initializing, Running, PostProcessing, Complete, Failed |
| `status.progress` | 0-100 percentage |
| `status.message` | Human-readable status |
| `status.gist` | Short summary of current work |
| `status.exitCode` | Container exit code |
| `status.podName` | Name of the created Pod |
| `status.commitSha` | Git commit SHA (if push succeeded) |
| `status.pushStatus` | success, failed, skipped |
| `status.prUrl` | PR URL (if created) |

### Feature Maturity

| CRD Field | Status | Notes |
|-----------|--------|-------|
| `spec.image` | Implemented | Container image |
| `spec.agent.type` | Implemented | Agent type label + env var |
| `spec.agent.command` | Implemented | Pod command |
| `spec.agent.workdir` | Implemented | Container working directory |
| `spec.resources.memory` | Implemented | Guaranteed QoS (requests = limits) |
| `spec.resources.cpu` | Implemented | Guaranteed QoS (requests = limits) |
| `spec.git.branch` | Implemented | → `KAPSIS_BRANCH` env var |
| `spec.git.baseBranch` | Implemented | → `KAPSIS_BASE_BRANCH` env var |
| `spec.git.push` | Implemented | → `KAPSIS_DO_PUSH` env var |
| `spec.git.repoUrl` | Implemented | → `GIT_REPO_URL` env var |
| `spec.git.credentialSecretRef` | Implemented | → `GIT_CREDENTIAL` from Secret |
| `spec.task.inline` | Implemented | → `KAPSIS_TASK` env var |
| `spec.task.specConfigMapRef` | Implemented | Mounted at `/task-spec.md` |
| `spec.environment.vars` | Implemented | User env vars |
| `spec.environment.secretRefs` | Implemented | Secret envFrom |
| `spec.environment.configMounts` | Implemented | ConfigMap volume mounts |
| `spec.security.profile` | Implemented | Capabilities + readOnlyRoot |
| `spec.security.serviceAccountName` | Implemented | Pod service account |
| `spec.ttl` | Implemented | `activeDeadlineSeconds` |
| `spec.podAnnotations` | Implemented | Passed to Pod metadata |
| `spec.network.mode` | Implemented | NetworkPolicy per pod (see [Network Isolation](#network-isolation)) |

### Network Isolation

The operator enforces network isolation using a two-layer defense model:

| Layer | Mechanism | Scope |
|-------|-----------|-------|
| **NetworkPolicy** (K8s-native) | Port-level egress filtering | Blocks traffic on unauthorized ports |
| **dnsmasq** (in-container) | DNS-name-level filtering | Blocks traffic to unauthorized domains |

The operator automatically creates and manages a `NetworkPolicy` per agent pod based on `spec.network.mode`:

| Mode | NetworkPolicy | Allowed Egress |
|------|--------------|----------------|
| `none` | Deny-all egress | Nothing (complete isolation) |
| `filtered` (default) | Port-restricted egress | DNS (53 UDP/TCP) + SSH (22) + HTTP (80) + HTTPS (443) + Git (9418) |
| `open` | No policy created | Unrestricted |

In `filtered` mode, the NetworkPolicy restricts egress to standard service ports. Fine-grained domain filtering (e.g., only `github.com`, `registry.npmjs.org`) is handled by dnsmasq inside the container, matching the Podman backend behavior.

For additional enforcement, cluster administrators can layer CNI-specific DNS policies (Cilium `CiliumNetworkPolicy` with FQDN rules, or Calico `GlobalNetworkPolicy` with domain-based rules) on top of the standard NetworkPolicy.

### Short Names

```bash
kubectl get ar          # Short for agentrequest
kubectl get agent       # Also works
```

## Operator Deployment

### Install CRD

```bash
kubectl apply -f operator/config/crd/bases/kapsis.aviadshiber.github.io_agentrequests.yaml
```

### Build and Deploy Operator

```bash
cd operator
make docker-build IMG=kapsis-operator:latest
make deploy IMG=kapsis-operator:latest
```

### Local Development

```bash
cd operator
make install    # Install CRDs
make run        # Run operator locally (outside cluster)
```

## Security Parity

The K8s backend maintains the same security model as Podman:

| Security Feature | Podman | K8s |
|-----------------|--------|-----|
| Non-root execution | `--userns=keep-id` | `runAsNonRoot: true` |
| Read-only root FS | Overlay mount | `readOnlyRootFilesystem` (strict/paranoid) |
| No privilege escalation | `--security-opt=no-new-privileges` | `allowPrivilegeEscalation: false` |
| Resource limits | `--memory`, `--cpus` | Pod resource limits |
| Network isolation | DNS filtering / `--network=none` | NetworkPolicy + dnsmasq (per mode) |
| TTL enforcement | Container timeout | `activeDeadlineSeconds` |

## Differences from Podman Backend

| Feature | Podman | K8s |
|---------|--------|-----|
| Interactive mode | Supported | Not supported |
| Overlay sandbox | Supported | Not supported (uses git clone) |
| DNS filtering | dnsmasq in container | NetworkPolicy |
| Status reporting | Mounted `/kapsis-status` dir | Pod annotations → CR status |
| Post-container git | Host-side worktree operations | In-pod via entrypoint.sh |

## Secrets Integration

The Podman backend automatically pulls secrets from your OS keychain. The K8s backend uses Kubernetes-native secret mechanisms instead.

### Option 1: Kubernetes Secrets (Built-in)

Create a Secret and reference it in the CR:

```bash
kubectl create secret generic agent-creds \
    --from-literal=ANTHROPIC_API_KEY=sk-ant-...
```

```yaml
spec:
  environment:
    secretRefs:
      - name: agent-creds
```

### Option 2: Vault / OpenBao (via podAnnotations)

Use `podAnnotations` to enable the Vault Agent Injector sidecar:

```yaml
spec:
  podAnnotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "kapsis-agent"
    vault.hashicorp.com/agent-inject-secret-api-key: "secret/kapsis/anthropic"
```

### Option 3: External Secrets Operator

Use ESO to sync secrets from any provider (Vault, AWS SM, GCP SM, Azure KV) into K8s Secrets, then reference them via `secretRefs` as in Option 1.

## Audit Logging

When audit logging is enabled, the K8s backend provides equivalent functionality to the Podman backend using Kubernetes-native volume and environment mechanisms.

### Enabling Audit in K8s

Set `KAPSIS_AUDIT_ENABLED=true` on the host, or specify `spec.audit.enabled: true` in the AgentRequest CR:

```yaml
spec:
  audit:
    enabled: true
```

### How It Works

1. **Environment injection**: The K8s config translator (`scripts/lib/k8s-config.sh`) adds `KAPSIS_AUDIT_ENABLED=true` and `KAPSIS_AUDIT_DIR=/kapsis-audit` to the CR's `spec.environment.vars`
2. **Volume provisioning**: The operator creates an `emptyDir` volume named `kapsis-audit` and mounts it at `/kapsis-audit` inside the agent container
3. **In-pod logging**: The audit library writes hash-chained JSONL events to `/kapsis-audit/` during the session
4. **File retrieval**: After pod completion, the K8s backend retrieves audit files via `kubectl cp`:

```bash
kubectl cp <namespace>/<pod-name>:/kapsis-audit/. ~/.kapsis/audit/
```

### CRD `spec.audit.enabled` Field

The `AuditSpec` type in the AgentRequest CRD:

```go
type AuditSpec struct {
    Enabled bool `json:"enabled,omitempty"`
}
```

When `spec.audit.enabled` is true, the operator's pod builder automatically:

- Adds an `emptyDir` volume (`kapsis-audit`)
- Mounts it at `/kapsis-audit`
- Injects `KAPSIS_AUDIT_ENABLED=true` and `KAPSIS_AUDIT_DIR=/kapsis-audit` as container environment variables

### Differences from Podman

| Aspect | Podman | K8s |
|--------|--------|-----|
| Volume type | Bind mount (host directory) | emptyDir (pod-local) |
| Real-time access | Yes (host can read during session) | No (files retrieved after completion) |
| Persistence | Files persist on host | Files exist only while pod is running |
| Retrieval | Automatic (shared volume) | `kubectl cp` after pod completion |

### Post-Run Analysis

After retrieval, audit files are stored in `~/.kapsis/audit/` and can be analyzed with the standard report tool:

```bash
./scripts/audit-report.sh --latest --verify
```

For the full audit system documentation, see [AUDIT-SYSTEM.md](AUDIT-SYSTEM.md).

## Troubleshooting

### CR stuck in Pending
```bash
kubectl describe agentrequest <name>
kubectl get events --field-selector involvedObject.name=<name>
```

### Pod not created
```bash
kubectl logs -l app.kubernetes.io/managed-by=kapsis-operator
```

### Check operator logs
```bash
kubectl logs -n kapsis-system deployment/kapsis-operator-controller-manager
```
