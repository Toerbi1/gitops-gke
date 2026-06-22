
# Vault Bootstrap

This document describes the one-time manual steps required after Vault

is first deployed by ArgoCD, plus the automated script that handles

everything else.



1. Wait for the `vault-0` pod to be `Running` (not yet `Ready`, that's expected):

```bash

   kubectl get pods -n vault

```

2. Initialize Vault (ONLY ONCE per instance — running this twice will fail):

```bash

   kubectl exec -n vault vault-0 -- vault operator init \

     -recovery-shares=1 \

     -recovery-threshold=1 \

     -format=json

```

   This uses GCP KMS auto-unseal (configured via `seal "gcpckms"` in

   values.yaml), so no manual unseal keys are needed — only recovery

   keys, which are used for disaster recovery, not routine unsealing.

   **Copy the `root_token` value somewhere safe. Do not commit it,

   do not paste it in chat/Slack/issues.**

3. Store the root token as a Kubernetes Secret:

```bash

   kubectl create secret generic vault-root-token \

     --namespace vault \

     --from-literal=token=<paste root_token here>

```

4. Verify Vault is unsealed:

```bash

   kubectl exec -n vault vault-0 -- vault status

```

   Expect `Seal Type: gcpckms`, `Sealed: false`.

5. Run the bootstrap script to configure everything else:

```bash

   ./infra/vault/bootstrap.sh <root_token>

```

   This is idempotent — safe to re-run if a step partially fails.

## What bootstrap.sh does

- Enables the KV v2 secrets engine at `secret/`

- Enables the Kubernetes auth method

- Configures Kubernetes auth to validate tokens against this cluster

- Writes least-privilege policies for: admin, ESO, cert-manager, Crossplane

- Creates Kubernetes auth roles binding each component's ServiceAccount

  to its corresponding policy

