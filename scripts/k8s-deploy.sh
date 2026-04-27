#!/usr/bin/env bash
# scripts/k8s-deploy.sh — Deploy the Kapsis K8s operator to a target namespace.
#
# Usage:
#   ./scripts/k8s-deploy.sh --namespace <ns> [options]
#
# Options:
#   --namespace <ns>        Kubernetes namespace to deploy into (required)
#   --operator-image <img>  Operator container image (default: ghcr.io/aviadshiber/kapsis/operator:latest)
#   --sidecar-image <img>   Status sidecar image (default: ghcr.io/aviadshiber/kapsis/status-sidecar:latest)
#   --git-token <token>     Git credential token (stored in Secret kapsis-git-creds)
#   --dry-run               Print generated YAML without applying
#   --help                  Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPERATOR_DIR="$REPO_ROOT/operator"

NAMESPACE=""
OPERATOR_IMAGE="ghcr.io/aviadshiber/kapsis/operator:latest"
SIDECAR_IMAGE="ghcr.io/aviadshiber/kapsis/status-sidecar:latest"
GIT_TOKEN=""
DRY_RUN=false

usage() {
    sed -n '2,14p' "$0" | sed 's/^# //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)   NAMESPACE="$2"; shift 2 ;;
        --operator-image) OPERATOR_IMAGE="$2"; shift 2 ;;
        --sidecar-image)  SIDECAR_IMAGE="$2"; shift 2 ;;
        --git-token)   GIT_TOKEN="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --help|-h)     usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$NAMESPACE" ]]; then
    echo "Error: --namespace is required." >&2
    echo "Run '$0 --help' for usage." >&2
    exit 1
fi

apply() {
    if [[ "$DRY_RUN" == "true" ]]; then
        cat
    else
        kubectl apply -f -
    fi
}

echo "==> Deploying Kapsis operator to namespace: $NAMESPACE"
echo "    Operator image : $OPERATOR_IMAGE"
echo "    Sidecar image  : $SIDECAR_IMAGE"
[[ "$DRY_RUN" == "true" ]] && echo "    (dry-run mode — no changes will be applied)"
echo ""

# ── Step 1: Apply CRD ──────────────────────────────────────────────────────────
echo "==> Step 1: Applying AgentRequest CRD..."
kubectl apply -f "$OPERATOR_DIR/config/crd/bases/kapsis.aviadshiber.github.io_agentrequests.yaml"

# ── Step 2: Render and apply RBAC / Deployment ────────────────────────────────
echo "==> Step 2: Applying RBAC and Deployment..."
for template_file in \
    "$OPERATOR_DIR/config/rbac/service_account.yaml" \
    "$OPERATOR_DIR/config/rbac/role.yaml" \
    "$OPERATOR_DIR/config/rbac/role_binding.yaml" \
    "$OPERATOR_DIR/config/manager/manager.yaml" \
    "$OPERATOR_DIR/config/pdb/pdb.yaml"; do

    [[ -f "$template_file" ]] || { echo "Warning: $template_file not found, skipping."; continue; }
    sed \
        -e "s|NAMESPACE|${NAMESPACE}|g" \
        -e "s|image: controller:latest|image: ${OPERATOR_IMAGE}|g" \
        "$template_file" | apply
done

# ── Step 3: Patch sidecar image env var if non-default ────────────────────────
if [[ "$SIDECAR_IMAGE" != "ghcr.io/aviadshiber/kapsis/status-sidecar:latest" ]]; then
    echo "==> Step 3: Patching KAPSIS_STATUS_SIDECAR_IMAGE..."
    kubectl -n "$NAMESPACE" set env deployment/controller-manager \
        KAPSIS_STATUS_SIDECAR_IMAGE="$SIDECAR_IMAGE" || true
fi

# ── Step 4: Create kapsis-agent ServiceAccount and RBAC ───────────────────────
echo "==> Step 4: Creating kapsis-agent ServiceAccount..."
cat <<EOF | apply
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kapsis-agent
  namespace: ${NAMESPACE}
EOF

# ── Step 5: Create git credentials Secret (if token provided) ─────────────────
if [[ -n "$GIT_TOKEN" ]]; then
    echo "==> Step 5: Creating kapsis-git-creds Secret..."
    # Pass the token via stdin to avoid exposing it in the process table (ps aux).
    printf '%s' "$GIT_TOKEN" | kubectl -n "$NAMESPACE" create secret generic kapsis-git-creds \
        --from-file=GIT_TOKEN=/dev/stdin \
        --dry-run=client -o yaml | apply
fi

echo ""
echo "✓ Done. Watch operator pods with:"
echo "    kubectl -n $NAMESPACE get pods -l control-plane=controller-manager -w"
echo ""
echo "  Submit an AgentRequest:"
echo "    kubectl -n $NAMESPACE apply -f operator/config/samples/agentrequest_smoke_test.yaml"
