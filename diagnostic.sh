#!/usr/bin/env bash
# DEPRECATED — do not use for fixes (it patched postgres to postgres:15-alpine and broke Bitnami).
# Use: ./scripts/fix-minikube-dev.sh
set -euo pipefail
echo "[ERROR] diagnostic.sh is deprecated and unsafe (wrong postgres image override)."
echo "        Use: ./scripts/fix-minikube-dev.sh"
echo "        Optional PVC reset: ./scripts/fix-minikube-dev.sh --reset-auth-pvc"
exit 1
