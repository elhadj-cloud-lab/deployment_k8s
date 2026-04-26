# deployment_k8s

Ce dépôt contient l'état désiré (**GitOps**) de la plateforme `elhadj-cloud-lab` sur Kubernetes via **Argo CD + Helm**.

## Objectif

- Décrire le déploiement Kubernetes de chaque service (charts Helm)
- Définir les valeurs par environnement (dev/prod)
- Déclarer les applications ArgoCD qui synchronisent automatiquement le cluster

## Structure du dépôt

- `charts/`
  - Charts Helm (1 chart par service)
- `apps/`
  - Values Helm par environnement (fichiers `values-dev.yaml` / `values-prod.yaml`)
- `argocd/applications/`
  - Manifests ArgoCD `Application` pour dev et prod
    - `argocd/applications/dev/`
    - `argocd/applications/prod/`

## Environnements

- **DEV**: namespace `dev`
- **PROD**: namespace `prod`

Chaque `Application` ArgoCD (dev/prod) référence un chart Helm dans `charts/` et un fichier de values dans `apps/`.

## Déploiement via ArgoCD

### Prérequis

- ArgoCD installé sur le cluster (namespace `argocd`)

### Bootstrap ArgoCD

Appliquer les manifests `Application`:

```bash
kubectl apply -n argocd -f argocd/applications/dev/
kubectl apply -n argocd -f argocd/applications/prod/
```

ArgoCD va ensuite:

- installer / mettre à jour les releases Helm
- faire le self-heal
- pruner les ressources supprimées

## CI -> GitOps (mise à jour automatique des tags)

Les dépôts applicatifs (ex: `produits_front`, `produit_back`, `authentification-service`) font:

1) build + tests
2) build/push image Docker dans GHCR (ex: `ghcr.io/<org>/<repo>:dev-<sha>`)
3) mise à jour GitOps: modification du champ `image.tag` dans `apps/<service>/values-<env>.yaml`

### Variables/Secrets côté dépôts applicatifs

- `GITOPS_REPO` (GitHub variable): repo GitOps cible (ex: `elhadj-cloud-lab/deployment_k8s`)
- `GITOPS_TOKEN` (GitHub secret): token avec droits d'écriture sur le repo GitOps

## Secrets (Sealed Secrets)

Ce dépôt supporte la gestion GitOps des secrets via **Bitnami Sealed Secrets**.

Manifests ArgoCD (installation du controller):

- DEV: `argocd/applications/dev/sealed-secrets.yaml`
- PROD: `argocd/applications/prod/sealed-secrets.yaml`

### Principe

- Tu ne commits **jamais** de `Secret` en clair.
- Tu commits un `SealedSecret` (chiffré), qui sera déchiffré en `Secret` par le controller dans le cluster.

### Important

- Le chiffrement dépend de la **clé du cluster**.
- Un `SealedSecret` généré pour le cluster DEV ne peut pas forcément être déchiffré en PROD (bonnes pratiques: séparer dev/prod).

### Installation de kubeseal

Installer l'outil `kubeseal` sur ta machine (Windows) via la méthode de ton choix (release GitHub Bitnami).

### Générer un SealedSecret (exemple)

1) Créer un secret local en YAML (sans l'appliquer) :

```bash
kubectl -n dev create secret generic produit-back-secrets \
  --from-literal=JWT_SECRET=change-me \
  --dry-run=client -o yaml > secret.yaml
```

2) Le chiffrer avec kubeseal (en récupérant le certificat du controller) :

```bash
kubeseal \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  --format yaml < secret.yaml > sealedsecret.yaml
```

3) Commit `sealedsecret.yaml` dans Git (dans un dossier dédié, par ex `apps/<service>/sealedsecrets/`).

4) ArgoCD synchronise -> le controller crée automatiquement le `Secret`.

## Ingress Controller (NGINX)

Ce dépôt gère aussi l'installation de **ingress-nginx** via ArgoCD:

- DEV: `argocd/applications/dev/ingress-nginx.yaml`
- PROD: `argocd/applications/prod/ingress-nginx.yaml`

### DEV (Minikube)

Pour Minikube, le controller est exposé en **NodePort** pour éviter `minikube tunnel`:

- HTTP: `30080`
- HTTPS: `30443`

Récupérer l'IP Minikube:

```bash
minikube ip
```

### PROD (Cloud)

En cloud, le controller est exposé en **LoadBalancer** (IP publique gérée par le cloud).

## Routage (Option A - même domaine)

Exemple typique:

- `/` -> frontend
- `/api` -> backend

Le chart `charts/produits-front` contient un template `Ingress` capable de router `/api` vers le service `produit-back`.

## Conventions & bonnes pratiques

- **Tags immuables** en prod (ex: `prod-<sha>`), éviter de dépendre de `latest`
- **Idempotence**: les changements doivent être représentés par Git (pas de modifs manuelles sur le cluster)
- **Séparation dev/prod** via values dédiés
- **Ports**: aligner l'image Docker (port d'écoute) avec `containerPort` et `service.targetPort`

## Dépannage

### ArgoCD

- Lister les Applications:

```bash
kubectl -n argocd get applications
```

### Ingress

- Vérifier le controller:

```bash
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc
```

- Vérifier les ingress:

```bash
kubectl -n dev get ingress
kubectl -n prod get ingress
```

### Helm templates (debug)

```bash
helm template produits-front charts/produits-front -f apps/produits_front/values-dev.yaml
```