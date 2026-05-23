#!/usr/bin/env bash
set -euo pipefail

# ==============================
# FIX APPS CrashLoop (auth + produit-back) after Postgres is Running
# - patches env vars for Spring datasource + JWT_SECRET
# - adds wait-for-db initContainer
# - restarts deployments
# - prints status + last logs if still failing
# ==============================

NAMESPACES=("dev" "prod")

# Services created by your postgres releases (Bitnami releaseName: postgres-auth / postgres-produit)
SVC_AUTH_DB="postgres-auth"
SVC_PRODUIT_DB="postgres-produit"
PG_PORT="5432"

# App deployments
DEP_AUTH="authentification-service"
DEP_BACK="produit-back"

# DB config (must match what you want)
AUTH_DB="auth_db"
AUTH_USER="auth_user"
PRODUIT_DB="produit_db"
PRODUIT_USER="produit_user"

# Secrets (already exist from SealedSecrets)
AUTH_DB_SECRET="postgres-auth-credentials"
PRODUIT_DB_SECRET="postgres-produit-credentials"
AUTH_PWD_KEY="password"
PRODUIT_PWD_KEY="password"

# JWT secret for auth-service
AUTH_JWT_SECRET="authentification-service-secrets"
AUTH_JWT_KEY="jwt-secret"

# Wait time
WAIT_SEC=180

hr(){ echo "------------------------------------------------------------"; }
k(){ kubectl "$@"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1"; exit 1; }
}

require kubectl

echo "[INFO] Context: $(kubectl config current-context)"
hr

for ns in "${NAMESPACES[@]}"; do
  echo "[STEP] Checking namespace $ns"
  k get ns "$ns" >/dev/null
  k -n "$ns" get deploy "$DEP_AUTH" >/dev/null 2>&1 || echo "[WARN] deploy/$DEP_AUTH not found in $ns"
  k -n "$ns" get deploy "$DEP_BACK" >/dev/null 2>&1 || echo "[WARN] deploy/$DEP_BACK not found in $ns"
  k -n "$ns" get secret "$AUTH_DB_SECRET" "$PRODUIT_DB_SECRET" >/dev/null
  k -n "$ns" get secret "$AUTH_JWT_SECRET" >/dev/null 2>&1 || echo "[WARN] secret/$AUTH_JWT_SECRET not found in $ns (JWT_SECRET injection will fail)"
  hr
done

patch_wait_for_db() {
  local ns="$1" dep="$2" svc="$3"
  if ! k -n "$ns" get deploy "$dep" >/dev/null 2>&1; then
    return 0
  fi

  # ensure initContainers exists
  k -n "$ns" patch deploy "$dep" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/initContainers","value":[]}
  ]' >/dev/null 2>&1 || true

  # add wait-for-db initContainer (duplicates OK short term)
  k -n "$ns" patch deploy "$dep" --type='json' -p="[
    {\"op\":\"add\",\"path\":\"/spec/template/spec/initContainers/-\",\"value\":{
      \"name\":\"wait-for-db\",
      \"image\":\"busybox:1.36\",
      \"command\":[\"sh\",\"-c\",
        \"echo Waiting for ${svc}:${PG_PORT}...; for i in \$(seq 1 120); do nc -z ${svc} ${PG_PORT} && exit 0; sleep 2; done; echo DB not reachable; exit 1\"
      ]
    }}
  ]" >/dev/null
}

patch_env_auth() {
  local ns="$1"
  if ! k -n "$ns" get deploy "$DEP_AUTH" >/dev/null 2>&1; then
    return 0
  fi

  # dev uses SPRING_DATASOURCE_URL, prod uses SPRING_DATASOURCE_URL_USER in your app-prod.yaml
  local url_var="SPRING_DATASOURCE_URL"
  if [[ "$ns" == "prod" ]]; then
    url_var="SPRING_DATASOURCE_URL_USER"
  fi

  local jdbc="jdbc:postgresql://${SVC_AUTH_DB}:${PG_PORT}/${AUTH_DB}"

  echo "[PATCH] $ns deploy/$DEP_AUTH env vars ($url_var)"
  k -n "$ns" patch deploy "$DEP_AUTH" --type='merge' -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"containers\": [
            {
              \"name\": \"${DEP_AUTH}\",
              \"env\": [
                {\"name\": \"${url_var}\", \"value\": \"${jdbc}\"},
                {\"name\": \"SPRING_DATASOURCE_USERNAME\", \"value\": \"${AUTH_USER}\"},
                {\"name\": \"SPRING_DATASOURCE_PASSWORD\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"${AUTH_DB_SECRET}\", \"key\": \"${AUTH_PWD_KEY}\"}}},
                {\"name\": \"JWT_SECRET\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"${AUTH_JWT_SECRET}\", \"key\": \"${AUTH_JWT_KEY}\"}}}
              ]
            }
          ]
        }
      }
    }
  }" >/dev/null
}

patch_env_back() {
  local ns="$1"
  if ! k -n "$ns" get deploy "$DEP_BACK" >/dev/null 2>&1; then
    return 0
  fi

  # dev uses SPRING_DATASOURCE_URL, prod uses SPRING_DATASOURCE_URL_PROD in your produit_back app-prod.yaml
  local url_var="SPRING_DATASOURCE_URL"
  if [[ "$ns" == "prod" ]]; then
    url_var="SPRING_DATASOURCE_URL_PROD"
  fi

  local jdbc="jdbc:postgresql://${SVC_PRODUIT_DB}:${PG_PORT}/${PRODUIT_DB}"

  echo "[PATCH] $ns deploy/$DEP_BACK env vars ($url_var)"
  k -n "$ns" patch deploy "$DEP_BACK" --type='merge' -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"containers\": [
            {
              \"name\": \"${DEP_BACK}\",
              \"env\": [
                {\"name\": \"${url_var}\", \"value\": \"${jdbc}\"},
                {\"name\": \"SPRING_DATASOURCE_USERNAME\", \"value\": \"${PRODUIT_USER}\"},
                {\"name\": \"SPRING_DATASOURCE_PASSWORD\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"${PRODUIT_DB_SECRET}\", \"key\": \"${PRODUIT_PWD_KEY}\"}}}
              ]
            }
          ]
        }
      }
    }
  }" >/dev/null
}

show_quick_diag() {
  local ns="$1"
  echo "[DIAG] $ns pods (failed only):"
  k -n "$ns" get pods | awk 'NR==1 || $3 ~ /(CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull)/ {print}'
  echo
  echo "[DIAG] $ns last logs auth (if exists):"
  k -n "$ns" logs deploy/"$DEP_AUTH" --tail=80 2>/dev/null || true
  echo
  echo "[DIAG] $ns last logs back (if exists):"
  k -n "$ns" logs deploy/"$DEP_BACK" --tail=80 2>/dev/null || true
  echo
}

echo "[STEP] Applying fixes (env + wait-for-db) and restarting deployments..."
hr
for ns in "${NAMESPACES[@]}"; do
  echo "[NS] $ns"

  patch_wait_for_db "$ns" "$DEP_AUTH" "$SVC_AUTH_DB"
  patch_wait_for_db "$ns" "$DEP_BACK" "$SVC_PRODUIT_DB"

  patch_env_auth "$ns"
  patch_env_back "$ns"

  echo "[RESTART] rollout restart"
  k -n "$ns" rollout restart deploy "$DEP_AUTH" >/dev/null 2>&1 || true
  k -n "$ns" rollout restart deploy "$DEP_BACK" >/dev/null 2>&1 || true

  hr
done

echo "[STEP] Waiting up to ${WAIT_SEC}s for deployments to become Available..."
for ns in "${NAMESPACES[@]}"; do
  echo "[WAIT] $ns"
  end=$((SECONDS + WAIT_SEC))
  while (( SECONDS < end )); do
    a="$(k -n "$ns" get deploy "$DEP_AUTH" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")"
    b="$(k -n "$ns" get deploy "$DEP_BACK" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")"
    echo "  - auth availableReplicas=${a:-0} | back availableReplicas=${b:-0}"
    if [[ "${a:-0}" != "0" && "${b:-0}" != "0" ]]; then
      echo "[OK] $ns deployments available"
      break
    fi
    sleep 5
  done
  hr
done

echo "[FINAL] Pods status:"
for ns in "${NAMESPACES[@]}"; do
  echo "== $ns =="
  k -n "$ns" get pods
  echo
done

echo "[IF STILL FAILING] Quick diagnostics:"
for ns in "${NAMESPACES[@]}"; do
  show_quick_diag "$ns"
done

echo "[DONE]"
echo
echo "[GITOPS NOTE] These are live patches. To persist, put the same env/initContainer configuration into your Helm charts values/templates or ArgoCD Application helm.values."
