#!/usr/bin/env bash
# Fix durable Minikube/dev : PostgreSQL Bitnami + apps (GitOps)
# Usage:
#   ./scripts/fix-minikube-dev.sh
#   ./scripts/fix-minikube-dev.sh --reset-auth-pvc   # si postgres-auth a été patché avec une mauvaise image
set -euo pipefail

NS="dev"
ARGO_NS="argocd"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESET_AUTH_PVC=false

for arg in "$@"; do
  case "$arg" in
    --reset-auth-pvc) RESET_AUTH_PVC=true ;;
    -h|--help)
      echo "Usage: $0 [--reset-auth-pvc]"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $arg"
      exit 1
      ;;
  esac
done

hr() { echo "------------------------------------------------------------"; }
k() { kubectl "$@"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1"; exit 1; }
}

require_cmd kubectl

if command -v argocd >/dev/null 2>&1; then
  HAS_ARGOCD_CLI=true
else
  HAS_ARGOCD_CLI=false
  echo "[WARN] argocd CLI not found; Argo sync will use kubectl patch only."
fi

echo "[INFO] kubectl context: $(kubectl config current-context)"
echo "[INFO] Repo root: ${REPO_ROOT}"
hr

echo "[STEP 1] Apply ArgoCD Application manifests from Git (local)"
k apply -n "$ARGO_NS" -f "${REPO_ROOT}/argocd/applications/dev/"
hr

echo "[STEP 2] Remove live drift from old hotfix scripts (diagnostic.sh / fix-apps.sh)"
k -n "$NS" delete secret postgres-auth-env postgres-produit-env --ignore-not-found
hr

if [[ "$RESET_AUTH_PVC" == "true" ]]; then
  echo "[STEP 2b] Reset postgres-auth data PVC (corruption after wrong image override)"
  k -n "$NS" delete pod postgres-auth-postgresql-0 --ignore-not-found --wait=true || true
  k -n "$NS" delete pvc data-postgres-auth-postgresql-0 --ignore-not-found --wait=true || true
  hr
fi

sync_argo_app() {
  local app="$1"
  if [[ "$HAS_ARGOCD_CLI" == "true" ]]; then
    echo "[SYNC] argocd app sync ${app} --force"
    argocd app sync "$app" --force || argocd app sync "$app"
  else
    echo "[SYNC] kubectl annotate application/${app} (refresh)"
    k -n "$ARGO_NS" annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  fi
}

echo "[STEP 3] Force ArgoCD sync (postgres + secrets + apps)"
APPS=(
  dev-secrets
  dev-postgres-auth
  dev-postgres-produit
  dev-authentification-service
  dev-produit-back
  dev-produits-front
)
for app in "${APPS[@]}"; do
  if k -n "$ARGO_NS" get application "$app" >/dev/null 2>&1; then
    sync_argo_app "$app"
  else
    echo "[WARN] Application ${app} not found in ${ARGO_NS}, skipping."
  fi
done
hr

echo "[STEP 4] Wait for PostgreSQL pods"
wait_sts_ready() {
  local sts="$1"
  echo "[WAIT] statefulset/${sts}"
  k -n "$NS" rollout status "statefulset/${sts}" --timeout=300s
}

wait_sts_ready postgres-auth-postgresql || true
wait_sts_ready postgres-produit-postgresql || true
hr

echo "[STEP 5] Restart application deployments (pick up initContainers/env from Helm)"
k -n "$NS" rollout restart deploy authentification-service produit-back 2>/dev/null || true
k -n "$NS" rollout status deploy authentification-service --timeout=300s || true
k -n "$NS" rollout status deploy produit-back --timeout=300s || true
hr

echo "[STEP 6] Final status"
k -n "$NS" get pods -o wide
hr

echo "[DIAG] postgres-auth logs (last 30 lines):"
k -n "$NS" logs postgres-auth-postgresql-0 --tail=30 2>/dev/null || echo "  (pod not available)"
echo
echo "[DIAG] authentification-service init logs:"
k -n "$NS" logs deploy/authentification-service -c wait-for-db --tail=30 2>/dev/null || true
echo
echo "[DIAG] produit-back init logs:"
k -n "$NS" logs deploy/produit-back -c wait-for-db --tail=30 2>/dev/null || true
hr

echo "[DONE] If postgres-auth is still CrashLoopBackOff after sync, re-run with:"
echo "  ./scripts/fix-minikube-dev.sh --reset-auth-pvc"
echo
echo "[GITOPS] Commit and push deployment_k8s changes so ArgoCD remote repo matches this fix."
