# Tenants

New tenant onboarding should go through the Crossplane `XTenant` Composition.

`tenants/weatherapp/xtenant.yaml` is an inactive example for the current weatherapp tenant. It is intentionally not included in `tenants/weatherapp/kustomization.yaml` yet, because the live tenant is still managed by the older individual manifests. Migrating the existing tenant needs an explicit handoff plan so the existing Cloud SQL claim is not pruned and deleted.

Production tenants should include `tenants/components/app-version-production` so a single image tag change rolls out to all production tenants. Staging tenants should use `tenants/components/app-version-staging` to test candidate versions before promotion.
