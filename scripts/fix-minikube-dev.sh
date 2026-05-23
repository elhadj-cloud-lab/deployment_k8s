#!/usr/bin/env bash
# Sync ArgoCD apps (postgres natif postgres:15-alpine + backends) — voir README.
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
fi

echo "[INFO] kubectl context: $(kubectl config current-context)"
hr

k apply -n "$ARGO_NS" -f "${REPO_ROOT}/argocd/applications/dev/"
hr

k -n "$NS" delete secret postgres-auth-env postgres-produit-env --ignore-not-found
hr

if [[ "$RESET_AUTH_PVC" == "true" ]]; then
  k -n "$NS" delete pod postgres-auth-0 --ignore-not-found --wait=true || true
  k -n "$NS" delete pvc data-postgres-auth-0 --ignore-not-found --wait=true || true
  hr
fi

sync_argo_app() {
  local app="$1"
  if [[ "$HAS_ARGOCD_CLI" == "true" ]]; then
    argocd app sync "$app" --force || argocd app sync "$app"
  else
    k -n "$ARGO_NS" annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  fi
}

APPS=(
  dev-secrets
  dev-postgres-auth
  dev-postgres-produit
  dev-authentification-service
  dev-produit-back
  dev-produits-front
)
for app in "${APPS[@]}"; do
  k -n "$ARGO_NS" get application "$app" >/dev/null 2>&1 && sync_argo_app "$app" || true
done
hr

k -n "$NS" rollout status statefulset/postgres-auth --timeout=300s || true
k -n "$NS" rollout status statefulset/postgres-produit --timeout=300s || true
k -n "$NS" rollout restart deploy authentification-service produit-back 2>/dev/null || true
k -n "$NS" get pods -o wide
