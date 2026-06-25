# Tenants

New tenant onboarding should go through the Crossplane `XTenant` Composition.

`tenants/weatherapp/xtenant.yaml` is an inactive example for the current weatherapp tenant. It is intentionally not included in `tenants/weatherapp/kustomization.yaml` yet, because the live tenant is still managed by the older individual manifests. Migrating the existing tenant needs an explicit handoff plan so the existing Cloud SQL claim is not pruned and deleted.
