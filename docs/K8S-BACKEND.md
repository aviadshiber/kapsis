# K8s Backend

Run Kapsis agents as Kubernetes **Jobs** instead of local Podman containers.

## Prerequisites

- `kubectl` configured with cluster access
- AgentRequest CRD installed (see [Operator Deployment](#operator-deployment))
- Kapsis operator running in-cluster
- Container images pushed to a registry accessible from the cluster

## Usage

```bash
# Dry-run: output AgentRequest CR YAML without applying
./scripts/launch-agent.sh ~/project --backend k8s --task "implement feature" --dry-run

# Apply to cluster (requires operator running)
./scripts/launch-agent.sh ~/project --backend k8s --task "implement feature"
```

The `--backend k8s` flag switches from local Podman containers to Kubernetes Jobs. All other flags (`--agent`, `--task`, `--spec`, `--branch`, `--memory`, `--cpus`, etc.) work the same way.

## How It Works

1. `launch-agent.sh` parses config and flags (same as Podman backend)
2. K8s backend (`scripts/backends/k8s.sh`) translates config into an AgentRequest CR
3. Config translator (`scripts/lib/k8s-config.sh`) converts Docker-style values to K8s format (`8g` → `8Gi`)
4. CR is applied via `kubectl apply`
5. Operator (in-cluster) watches CRs and creates a `batch/v1 Job` for each
6. Each Job pod runs two containers:
   - **agent**: the AI coding agent (Claude Code, Codex CLI, etc.)
   - **status-sidecar**: watches `/kapsis-status/status.json` and patches pod annotations so the operator can bridge status to the CR
7. Backend polls CR status until completion

### Status Flow

```
agent container
  └─ writes /kapsis-status/status.json
       ↓
status-sidecar
  └─ watches file, patches pod annotations via K8s API
       ↓
operator
  └─ reads pod annotations → updates AgentRequest status
       ↓
k8s.sh (host)
  └─ polls kubectl → surfaces progress to user
```

### Config Translation

| Kapsis Config | K8s Equivalent |
|---------------|----------------|
| `--memory 8g` | `spec.resources.memory: "8Gi"` |
| `--cpus 4` | `spec.resources.cpu: "4"` |
| `--task "..."` | `spec.task.inline: "..."` |
| `--branch feat/x` | `spec.workspace.git.branch: feat/x` |
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
  agent:
    type: claude-cli
    image: ghcr.io/aviadshiber/kapsis/claude-cli:latest
    command: ["bash", "-c", "claude --task 'implement login'"]  # optional override
    workdir: /workspace

  task:
    inline: "Implement the login feature"           # mutually exclusive with specConfigMapRef
    # specConfigMapRef: my-task-cm                  # mounted at /task-spec.md

  workspace:
    git:
      url: https://github.com/org/repo.git
      branch: feat/login
      baseBranch: main
      push: true
      credentialSecretRef: kapsis-git-creds         # Secret with GIT_TOKEN key

  security:
    profile: standard                               # minimal|standard|strict|paranoid
    serviceAccountName: kapsis-agent
    # nestedContainers: false                       # Podman-in-pod (requires admission approval)
    # runtimeClass: ""                              # gvisor or kata-containers for paranoid profile
    runAsUser: 1000
    runAsGroup: 1000

  network:
    mode: filtered                                  # none|filtered|open

  resources:
    memory: "8Gi"
    cpu: "4"
    workspaceSizeLimit: "20Gi"                      # emptyDir size limit

  environment:
    vars:
      # KAPSIS_BACKEND, KAPSIS_AGENT_ID, KAPSIS_AGENT_TYPE are auto-injected
      # by the operator — do not set them here.
      - name: MY_CUSTOM_VAR
        value: "example-value"
    secretRefs:
      - name: agent-api-keys                        # all keys injected as env vars

  liveness:
    enabled: true
    timeoutSeconds: 900
    completionTimeoutSeconds: 120                   # grace period after agent reports done

  ttl: 3600                                         # activeDeadlineSeconds on the Job

  podAnnotations:                                   # passed to Job pod template
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "kapsis-agent"
```

### Status Fields

```bash
kubectl get agentrequest kapsis-abc123
kubectl get agentrequest kapsis-abc123 -o yaml
```

| Field | Description |
|-------|-------------|
| `status.phase` | Pending, Initializing, Running, PostProcessing, Complete, Failed |
| `status.progress` | 0-100 percentage |
| `status.message` | Human-readable status |
| `status.gist` | Short summary of current work |
| `status.exitCode` | Agent container exit code |
| `status.jobName` | Name of the created Job |
| `status.podName` | Name of the Job's pod |
| `status.commitSha` | Git commit SHA (populated after push) |
| `status.pushStatus` | `success`, `failed`, or `skipped` |
| `status.prUrl` | PR URL (if created) |
| `status.pushFallbackCommand` | `git push` command to run from host when `pushStatus=failed` |

### Security Profiles

| Profile | Capabilities | seccomp | readOnlyRootFS |
|---------|-------------|---------|---------------|
| `minimal` | drop ALL, add SETUID/SETGID | RuntimeDefault | No |
| `standard` (default) | drop ALL, add SETUID/SETGID/CHOWN/FOWNER/NET_BIND_SERVICE | RuntimeDefault | No |
| `strict` | drop ALL, add SETUID/SETGID | RuntimeDefault | Yes + `/tmp` emptyDir |
| `paranoid` | drop ALL, add SETUID/SETGID | Localhost (custom) | Yes + `/tmp` emptyDir |

`runAsNonRoot: true` and `allowPrivilegeEscalation: false` are enforced on all profiles.

### Network Isolation

One `NetworkPolicy` is created per namespace per mode (not per agent — avoids O(N) fan-out). It applies to all pods with `app.kubernetes.io/managed-by: kapsis-operator`.

| Mode | Policy | Allowed Egress | Ingress |
|------|--------|---------------|---------|
| `none` | `kapsis-none-policy` | None (deny-all) | Deny-all |
| `filtered` (default) | `kapsis-filtered-policy` | DNS (53) + SSH (22) + HTTP (80) + HTTPS (443) + Git (9418) | Deny-all |
| `open` | None created | Unrestricted | No restriction |

Ingress deny-all is enforced on all modes — agents cannot receive inbound connections.

### Short Names

```bash
kubectl get ar          # Short for agentrequest
kubectl get agent       # Also works
```

## Operator Deployment

Use the deploy script — it substitutes `NAMESPACE` in all config files:

```bash
./scripts/k8s-deploy.sh --namespace <your-namespace> [options]

# Options:
#   --operator-image <img>   Override operator image (default: ghcr.io/aviadshiber/kapsis/operator:latest)
#   --sidecar-image <img>    Override status sidecar image
#   --git-token <token>      Create kapsis-git-creds Secret with this token
#   --dry-run                Print generated YAML without applying

# Example:
./scripts/k8s-deploy.sh \
  --namespace my-namespace \
  --git-token ghp_xxxxxxxxxxxx
```

The script applies in order:
1. CRD
2. Namespace, RBAC (ClusterRole + ClusterRoleBinding + Role + RoleBinding), Deployment
3. PodDisruptionBudget
4. kapsis-agent ServiceAccount
5. kapsis-git-creds Secret (if `--git-token` is provided)

### Manual CRD Install

```bash
kubectl apply -f operator/config/crd/bases/kapsis.aviadshiber.github.io_agentrequests.yaml
```

### Local Development

```bash
cd operator
make install    # Install CRDs in current cluster context
make run        # Run operator locally (outside cluster, uses local kubeconfig)
```

## Smoke Test

```bash
kubectl apply -n <namespace> -f operator/config/samples/agentrequest_smoke_test.yaml
kubectl get agentrequest smoke-test -n <namespace> -w
```

## Security Parity

| Security Feature | Podman | K8s |
|-----------------|--------|-----|
| Non-root execution | `--userns=keep-id` | `runAsNonRoot: true` |
| Read-only root FS | Overlay mount | `readOnlyRootFilesystem` (strict/paranoid) |
| No privilege escalation | `--security-opt=no-new-privileges` | `allowPrivilegeEscalation: false` |
| Capability dropping | `--cap-drop=ALL` | `capabilities.drop: [ALL]` |
| Resource limits | `--memory`, `--cpus` | Job resource limits |
| Network isolation | DNS filtering / `--network=none` | NetworkPolicy (namespace-level) |
| TTL enforcement | Container timeout | `activeDeadlineSeconds` on Job |
| Workspace isolation | emptyDir per agent | emptyDir with size limit |

## Differences from Podman Backend

| Feature | Podman | K8s |
|---------|--------|-----|
| Execution unit | Container | Job (batch/v1) |
| Interactive mode | Supported | Not supported |
| Overlay sandbox | Supported | Not supported (uses git clone in emptyDir) |
| DNS filtering | dnsmasq in container | NetworkPolicy (port-level) |
| Status reporting | Mounted `/kapsis-status` dir | status-sidecar → pod annotations → CR status |
| Audit log access | Bind mount on host | sidecar streams to stdout (log aggregator) |
| Post-container git | Host-side worktree operations | In-pod via entrypoint.sh |

## Secrets Integration

### Option 1: Git Credentials (Built-in)

The operator reads `GIT_TOKEN` from the Secret named in `spec.workspace.git.credentialSecretRef`:

```bash
kubectl create secret generic kapsis-git-creds \
    --from-literal=GIT_TOKEN=ghp_xxxxxxxxxxxx \
    -n <namespace>
```

Or use `./scripts/k8s-deploy.sh --git-token <token>`.

### Option 2: Additional API Keys

```bash
kubectl create secret generic agent-api-keys \
    --from-literal=ANTHROPIC_API_KEY=sk-ant-...
```

```yaml
spec:
  environment:
    secretRefs:
      - name: agent-api-keys   # all keys injected as env vars
```

### Option 3: Vault / OpenBao (via podAnnotations)

```yaml
spec:
  podAnnotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "kapsis-agent"
    vault.hashicorp.com/agent-inject-secret-api-key: "secret/kapsis/anthropic"
```

### Option 4: External Secrets Operator

Sync secrets from Vault, AWS SM, GCP SM, or Azure KV into K8s Secrets, then reference via `secretRefs`.

## Audit Logging

Audit events are written to `/kapsis-audit/` inside the agent container and streamed to stdout by the status-sidecar. Log aggregators (ELK, Splunk, Loki) capture them automatically.

```bash
# Retrieve audit logs from a running or completed pod
kubectl logs -c status-sidecar <pod-name> -n <namespace>

# Or via log aggregator query (e.g., Loki)
{namespace="<namespace>", container="status-sidecar"}
```

No `kubectl cp` is needed. Unlike the Podman backend, audit events are not stored on the host — they live in the cluster's log aggregation system.

For the full audit system documentation, see [AUDIT-SYSTEM.md](AUDIT-SYSTEM.md).

## Troubleshooting

### CR stuck in Pending

```bash
kubectl describe agentrequest <name> -n <namespace>
kubectl get events -n <namespace> --field-selector involvedObject.name=<name>
```

### Job not created

```bash
kubectl logs -n <namespace> -l control-plane=controller-manager
```

### Check operator logs

```bash
kubectl logs -n <namespace> deployment/controller-manager -f
```

### Push failed

When `status.pushStatus == "failed"`, the `status.pushFallbackCommand` field contains a ready-to-run `git push` command. Execute it from the host where git credentials are available:

```bash
kubectl get agentrequest <name> -n <namespace> \
  -o jsonpath='{.status.pushFallbackCommand}'
# Then run the printed command
```

### Admission webhook rejection

If you get a webhook validation error, check:
- `spec.agent.image` matches the configured allowlist
- `spec.security.serviceAccountName` is `kapsis-agent`
- `spec.environment.vars` contains no `KAPSIS_`-prefixed names
- `spec.network.mode: open` requires the opt-in annotation `kapsis.aviadshiber.github.io/allow-open-network: "true"`
