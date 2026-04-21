# deployment_k8s

This repository contains the desired state (GitOps) for the elhadj-cloud-lab platform on Kubernetes using Argo CD + Helm.

Structure:
- apps/
- argocd/
- charts/

Environments:
- dev namespace
- prod namespace

Argo CD:
- Apply the Application manifests under argocd/applications/dev and argocd/applications/prod.

CI integration:
- Application repositories build/push images to GHCR, then update apps/<service>/values-<env>.yaml with the new image tag.

Quickstart:
- Install Argo CD in your cluster.
- Apply the Application manifests:
  - argocd/applications/dev/*.yaml
  - argocd/applications/prod/*.yaml

GitHub Secrets required in each application repo (to enable automatic GitOps updates):
- GITOPS_REPO: elhadj-cloud-lab/deployment_k8s
- GITOPS_TOKEN: a token with write access to deployment_k8s