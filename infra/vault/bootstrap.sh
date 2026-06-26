#!/usr/bin/env bash
set -euo pipefail

ROOT_TOKEN="${1:?Usage: ./bootstrap.sh <root-token>}"
NAMESPACE="vault"
POD="vault-0"

run() {
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "vault login $ROOT_TOKEN > /dev/null && $1"
}

echo "==> Enabling KV v2 secrets engine at secret/"
run "vault secrets enable -path=secret kv-v2" || echo "    (already enabled, skipping)"

echo "==> Enabling Kubernetes auth method"
run "vault auth enable kubernetes" || echo "    (already enabled, skipping)"

echo "==> Configuring Kubernetes auth method"
run "vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc"

echo "==> Writing policies"
for policy in admin eso cert-manager crossplane weatherapp-tenant weatherapp-staging-tenant; do
  echo "    -> $policy"
  kubectl cp "infra/vault/policies/${policy}.hcl" "${NAMESPACE}/${POD}:/tmp/${policy}.hcl"
  run "vault policy write ${policy}-policy /tmp/${policy}.hcl"
done

echo "==> Creating Kubernetes auth roles"
run "vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=1h"

run "vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=1h"

run "vault write auth/kubernetes/role/crossplane \
  bound_service_account_names=crossplane \
  bound_service_account_namespaces=crossplane-system \
  policies=crossplane-policy \
  ttl=1h"

run "vault write auth/kubernetes/role/weatherapp-tenant \
  bound_service_account_names=default \
  bound_service_account_namespaces=tenant-weatherapp \
  policies=weatherapp-tenant-policy \
  ttl=1h"

run "vault write auth/kubernetes/role/weatherapp-staging-tenant \
  bound_service_account_names=default \
  bound_service_account_namespaces=tenant-weatherapp-staging \
  policies=weatherapp-staging-tenant-policy \
  ttl=1h"

echo "==> Done. Vault is configured."
