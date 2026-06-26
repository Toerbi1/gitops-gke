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

### 1. Envoy Gateway operator

Envoy Gateway is managed by ArgoCD through the official Helm chart in `apps/envoy-gateway.yaml`.
The same app file also applies this repo's `GatewayClass`, `Gateway`, and wildcard `Certificate` resources from `infra/envoy-gateway/`.

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

The script also registers the weatherapp tenant policy and Kubernetes auth role.

### 5. Put secrets into Vault (manual)

These cannot be automated — they come from external sources. Run each command inside the vault pod:

```bash
EXEC="kubectl exec -n vault vault-0 -- sh -c"

# Log in first
$EXEC "vault login <root-token> > /dev/null"

# AVWX API key
$EXEC "vault kv put secret/tenants/weatherapp/config avwx-api-key=<api-key>"

# Cloud SQL passwords used by Crossplane to create the instance and app user.
# The backend reads this same db-password through its tenant SecretStore.
$EXEC "vault kv put secret/tenants/weatherapp/cloudsql \
  root-password=<postgres-superuser-password> \
  db-password=<db-password>"

# GitHub PAT for the private frontend image (ghcr.io/bhuang02/frontend)
# Build the dockerconfigjson value: base64("<github-username>:<PAT>")
$EXEC 'vault kv put secret/tenants/weatherapp/github \
  dockerconfigjson-raw='"'"'{"auths":{"ghcr.io":{"auth":"<base64(username:PAT)>"}}}'"'"
```

Generated and discovered values such as `db-host`, `db-name`, and `username` are not stored in Vault. Crossplane publishes them to the `weatherapp-cloudsql-connection` Secret in the tenant namespace.

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
4. Database (`weatherapp`)
5. User (`weatherapp`)

Monitor:

```bash
kubectl get xpostgresqlinstance -A
kubectl get databaseinstance.sql.gcp.upbound.io,database.sql.gcp.upbound.io,user.sql.gcp.upbound.io -A
```

All resources should reach `SYNCED: True  READY: True`.

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

New tenants should be provisioned with one `XTenant` object. The `XTenant` Composition creates:

- tenant namespace
- Vault `SecretStore`
- ExternalSecrets for AVWX config, GHCR pull secret, and DB password
- Cloud SQL `PostgreSQLInstance` claim
- backend/frontend Deployments and Services
- Gateway API `HTTPRoute`

Use `tenants/weatherapp/xtenant.yaml` as the starting point:

```yaml
apiVersion: platform.fhbgl.study/v1alpha1
kind: XTenant
metadata:
  name: weatherapp
spec:
  parameters:
    name: weatherapp
    namespace: tenant-weatherapp
    hostname: weather.ben.fhbgl.study
    vaultPath: tenants/weatherapp
    vaultRole: weatherapp-tenant
    backendImage: ghcr.io/bhuang02/hochschule-burgenland-bswe-ws2024-2at-backend:latest
    frontendImage: ghcr.io/bhuang02/frontend:latest
    gcpProjectId: cloud-project-493810
    region: europe-west4
    vpcName: ben-cluster-vpc
```

The Vault secret paths remain deterministic:

```bash
secret/tenants/<name>/config
secret/tenants/<name>/github
secret/tenants/<name>/cloudsql
```

Existing tenants should be migrated carefully. Do not remove their old Argo-managed `PostgreSQLInstance` claim until the `XTenant` owner/adoption path is planned, because deleting the claim can delete the external Cloud SQL instance.

The DNS record for `<name>.<domain>` is still created automatically by external-dns when the generated HTTPRoute is applied.

---

## Application updates

Production tenants should include `tenants/components/app-version-production`.
That component is the single place for the production backend/frontend image tags.
Changing it rolls the same application version to every production tenant that includes it.

The staging tenant is managed separately under `tenants/weatherapp-staging/` and includes
`tenants/components/app-version-staging`. To test a release candidate:

1. Update backend/frontend tags in `tenants/components/app-version-staging/kustomization.yaml`.
2. Let ArgoCD sync `weatherapp-staging`.
3. Verify `https://weather-staging.ben.fhbgl.study`.
4. Copy the tested tags to `tenants/components/app-version-production/kustomization.yaml`.
5. Let ArgoCD sync production tenants.

Staging uses its own namespace, hostname, Vault paths, and Cloud SQL claim. It reuses the
existing VPC private services connection through the `existing-private-services`
PostgreSQL composition, so it does not try to create a second VPC peering.

---

## Known manual steps summary

| Step | Why it cannot be automated |
|---|---|
| Enable GCP APIs | Not included in Terraform yet |
| Vault init + unseal | By design — unseal key must never be stored in the cluster |
| Vault secrets (API keys, passwords, PATs) | Sensitive external values, cannot be committed to git |
| Crossplane WI IAM bindings | Infra Terraform has `members = []` (known gap); SA names are dynamic |

## Code of Conduct / Plagiarism
As always, you must follow the Hochschule Burgenland code of conduct.
If plagiarism is detected across groups or to reference repositories, the affected pillar(s) will
be graded with 0 points. This also applies to Generative AI areas without any reference.