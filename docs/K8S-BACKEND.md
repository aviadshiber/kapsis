# K8s Backend

Run Kapsis agents as Kubernetes Pods instead of local Podman containers.

## Prerequisites

- `kubectl` configured with cluster access
- AgentRequest CRD installed: `kubectl apply -f operator/config/crd/bases/kapsis.io_agentrequests.yaml`
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
apiVersion: kapsis.io/v1alpha1
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
    branch: feat/login
    baseBranch: main
    push: true
  task:
    inline: "Implement the login feature"
  network:
    mode: filtered
  security:
    profile: standard
    serviceAccountName: kapsis-agent
  ttl: 3600
  podAnnotations:                             # Optional: passed to Pod
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

### Short Names

```bash
kubectl get ar          # Short for agentrequest
kubectl get agent       # Also works
```

## Operator Deployment

### Install CRD

```bash
kubectl apply -f operator/config/crd/bases/kapsis.io_agentrequests.yaml
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
| Network isolation | DNS filtering / `--network=none` | NetworkPolicy (per mode) |
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
