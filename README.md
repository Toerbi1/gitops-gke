# gitops-gke

GitOps repository for the GKE cluster. Uses ArgoCD app-of-apps to manage all infrastructure tooling and tenant workloads.

## Architecture

```
infra/argocd/root-app.yaml   ← applied once manually to bootstrap
        │
        └── apps/            ← ArgoCD watches this directory
              ├── argocd.yaml
              ├── vault.yaml
              ├── eso.yaml / eso-config.yaml
              ├── cert-manager.yaml
              ├── external-dns.yaml
              ├── crossplane.yaml / crossplane-config.yaml
              ├── envoy-gateway.yaml
              └── weatherapp.yaml
```

**Infra tools:** Vault · External Secrets Operator (ESO) · Crossplane (GCP providers) · cert-manager · external-dns · Envoy Gateway

**Tenants:** `tenants/weatherapp/` — Spring Boot backend + Quasar/Vue frontend + Cloud SQL (PostgreSQL 16)

---

## Prerequisites

- `kubectl` pointing at the GKE cluster
- `gcloud` authenticated with permissions on the project
- Terraform/OpenTofu apply completed (GKE cluster, VPC, KMS, service accounts exist)

---

## Bootstrap sequence

### 1. Install Envoy Gateway operator (manual)

There is no working Helm chart for Envoy Gateway. Install the operator directly from the GitHub release:

```bash
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.2.0/install.yaml
```

ArgoCD only manages the `GatewayClass` and `Gateway` resources in `infra/envoy-gateway/`, not the operator itself.

### 2. Enable required GCP APIs (manual)

```bash
gcloud services enable cloudresourcemanager.googleapis.com servicenetworking.googleapis.com \
  --project=<project-id>
```

Required for Crossplane's Cloud SQL VPC peering. Safe to re-run if already enabled.

### 3. Bootstrap ArgoCD

Install ArgoCD (if not already done):

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 9.5.21 \
  --namespace argocd --create-namespace
```

Apply the bootstrap AppProject and root app to start the self-managing loop:

```bash
kubectl apply -f infra/argocd/bootstrap-project.yaml
kubectl apply -f infra/argocd/root-app.yaml
```

ArgoCD will now auto-sync everything under `apps/` — including re-managing itself.

### 4. Initialize and configure Vault (manual)

Wait for the `vault-0` pod to be Running, then initialize:

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1
```

Save the **Unseal Key** and **Root Token** — you will need them every time the pod restarts.

Unseal:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>
```

Run the bootstrap script to configure the KV engine, Kubernetes auth, policies, and ESO/cert-manager/crossplane roles:

```bash
./infra/vault/bootstrap.sh <root-token>
```

Then register the weatherapp tenant policy and role (not yet wired into the bootstrap script):

```bash
kubectl cp infra/vault/policies/weatherapp-tenant.hcl vault/vault-0:/tmp/weatherapp-tenant.hcl

kubectl exec -n vault vault-0 -- sh -c "
  vault login <root-token> > /dev/null
  vault policy write weatherapp-tenant-policy /tmp/weatherapp-tenant.hcl
  vault write auth/kubernetes/role/weatherapp-tenant \
    bound_service_account_names=default \
    bound_service_account_namespaces=tenant-weatherapp \
    policies=weatherapp-tenant-policy \
    ttl=1h
"
```

### 5. Put secrets into Vault (manual)

These cannot be automated — they come from external sources. Run each command inside the vault pod:

```bash
EXEC="kubectl exec -n vault vault-0 -- sh -c"

# Log in first
$EXEC "vault login <root-token> > /dev/null"

# AVWX API key
$EXEC "vault kv put secret/tenants/weatherapp/config avwx-api-key=<api-key>"

# Database credentials
# db-password here must match the cloudsql db-password below
$EXEC "vault kv put secret/tenants/weatherapp/db \
  username=weatherapp \
  password=<db-password> \
  db-name=weatherapp \
  db-host=placeholder"

# Cloud SQL passwords used by Crossplane to create the instance and user
# db-password must be identical to the value in weatherapp/db above
$EXEC "vault kv put secret/tenants/weatherapp/cloudsql \
  root-password=<postgres-superuser-password> \
  db-password=<db-password>"

# GitHub PAT for the private frontend image (ghcr.io/bhuang02/frontend)
# Build the dockerconfigjson value: base64("<github-username>:<PAT>")
$EXEC 'vault kv put secret/tenants/weatherapp/github \
  dockerconfigjson-raw='"'"'{"auths":{"ghcr.io":{"auth":"<base64(username:PAT)>"}}}'"'"
```

> **Password note:** `secret/tenants/weatherapp/db` → `password` and `secret/tenants/weatherapp/cloudsql` → `db-password` must be the same value. The first is what the backend uses to connect; the second is what Crossplane sets on the Cloud SQL user when creating it.

### 6. Fix Crossplane Workload Identity bindings (manual)

Terraform creates the `crossplane` GCP service account but does not add the IAM Workload Identity member bindings for the provider pods (known gap in the infra repo: `members = []`).

After Crossplane installs and the provider pods are running, execute:

```bash
PROJECT_ID=<project-id>
CROSSPLANE_SA="crossplane@${PROJECT_ID}.iam.gserviceaccount.com"

for SA in $(kubectl get serviceaccounts -n crossplane-system -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
for sa in d['items']:
    ann = sa['metadata'].get('annotations', {})
    if 'crossplane' in ann.get('iam.gke.io/gcp-service-account', ''):
        print(sa['metadata']['name'])
"); do
  gcloud iam service-accounts add-iam-policy-binding "$CROSSPLANE_SA" \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[crossplane-system/${SA}]" \
    --project="$PROJECT_ID"
done
```

There are typically 7 provider SAs (compute, sql, iam, servicenetworking, container, cloudplatform, upbound-family). The SA names contain auto-generated hashes that change on every fresh install, so they cannot be hardcoded — this script discovers them at runtime. It is safe to re-run.

After adding the bindings, restart provider pods to pick up the new permissions:

```bash
kubectl delete pods -n crossplane-system -l pkg.crossplane.io/revision
```

### 7. Wait for Cloud SQL to provision (~10 minutes)

Crossplane automatically creates resources in order:
1. GlobalAddress (VPC peering IP range)
2. ServiceNetworking Connection (VPC peering)
3. DatabaseInstance (Cloud SQL PostgreSQL 16)
4. User (`weatherapp`)

Monitor:

```bash
kubectl get xpostgresqlinstance -A
kubectl get databaseinstance.sql.gcp.upbound.io,user.sql.gcp.upbound.io -A
```

All resources should reach `SYNCED: True  READY: True`.

### 8. Create the application database and update db-host (manual)

Crossplane provisions the instance and user but does not create the application database. Once the instance is READY:

```bash
PROJECT_ID=<project-id>

# Get the auto-generated instance name (includes a random hash suffix)
INSTANCE=$(kubectl get databaseinstance.sql.gcp.upbound.io -A \
  -o jsonpath='{.items[0].metadata.name}')

# Create the weatherapp database
gcloud sql databases create weatherapp --instance=$INSTANCE --project=$PROJECT_ID

# Get the private IP assigned to the instance
PRIVATE_IP=$(kubectl get databaseinstance.sql.gcp.upbound.io -A \
  -o jsonpath='{.items[0].status.atProvider.privateIpAddress}')

# Update Vault with the real db-host
kubectl exec -n vault vault-0 -- sh -c "
  vault login <root-token> > /dev/null
  vault kv patch secret/tenants/weatherapp/db db-host=${PRIVATE_IP}
"

# Force ESO to pick up the new value and restart the backend
kubectl annotate externalsecret weatherapp-db -n tenant-weatherapp \
  force-sync="$(date +%s)" --overwrite

kubectl rollout restart deployment/backend -n tenant-weatherapp
```

The backend runs Flyway on startup and will create all tables automatically on first connection.

---

## Verification

```bash
# All ArgoCD apps should be Synced/Healthy
kubectl get applications -n argocd

# Tenant pods (backend + frontend should both be 1/1 Running)
kubectl get pods -n tenant-weatherapp

# End-to-end health check through the gateway
curl http://weather.<domain>/api/actuator/health
# Expected: {"status":"UP","components":{"db":{"status":"UP"},...}}

# API smoke test
curl http://weather.<domain>/api/user/
```

---

## Adding a new tenant

1. **Create tenant manifests** under `tenants/<name>/`:
   - `kustomization.yaml`
   - `secretstore.yaml` — Vault SecretStore scoped to the tenant namespace
   - `externalsecrets.yaml` — maps `secret/tenants/<name>/*` paths to Kubernetes secrets
   - `backend.yaml`, `frontend.yaml` — Deployments + Services
   - `httproute.yaml` — hostname `<name>.<domain>`, `/api` → backend, `/` → frontend
   - `cloudsql-claim.yaml` — PostgreSQLInstance claim (triggers Cloud SQL provisioning)

2. **Add `apps/<name>.yaml`** — an ArgoCD Application pointing at `tenants/<name>/`.

3. **Add a Vault policy** following `infra/vault/policies/weatherapp-tenant.hcl` as a template, and register the role (same as step 4 above).

4. **Put tenant secrets into Vault** at `secret/tenants/<name>/...`. The exact paths are defined by the tenant's `externalsecrets.yaml` — that file is the source of truth for what needs to go into Vault.

5. After Cloud SQL provisions: **create the database** and **update `db-host`** (same as step 8 above).

The DNS record for `<name>.<domain>` is created automatically by external-dns when the HTTPRoute is applied.

---

## Known manual steps summary

| Step | Why it cannot be automated |
|---|---|
| Envoy Gateway operator install | No Helm chart repo exists for the operator |
| Enable GCP APIs | Not included in Terraform yet |
| Vault init + unseal | By design — unseal key must never be stored in the cluster |
| Vault secrets (API keys, passwords, PATs) | Sensitive external values, cannot be committed to git |
| Crossplane WI IAM bindings | Infra Terraform has `members = []` (known gap); SA names are dynamic |
| Create Cloud SQL `weatherapp` database | Crossplane Composition only creates the instance and user, not the database |
| Update `db-host` in Vault | Cloud SQL private IP is only known after provisioning completes |
