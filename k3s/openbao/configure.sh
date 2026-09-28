#!/usr/bin/env bash
# One-time OpenBao setup for External Secrets Operator, run from the control machine
# after `bao operator init` and unseal (see README):
#   - KV v2 secrets engine at secret/
#   - policy external-secrets: read-only on secret/*
#   - Kubernetes auth, role external-secrets bound to ESO's ServiceAccount
# Idempotent: re-running it only rewrites the policy, config and role.
#
# Usage: BAO_TOKEN=<root token> k3s/openbao/configure.sh
set -euo pipefail

: "${BAO_TOKEN:?set BAO_TOKEN to the root token}"

# The token goes through stdin, not the command line (visible in the node's process list)
printf '%s\n' "$BAO_TOKEN" | kubectl -n openbao exec -i openbao-0 -- sh -euc '
read -r BAO_TOKEN
export BAO_TOKEN BAO_ADDR=http://127.0.0.1:8200

bao secrets list | grep -q "^secret/" || bao secrets enable -path=secret -version=2 kv

bao policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

bao auth list | grep -q "^kubernetes/" || bao auth enable kubernetes
# In-cluster: OpenBao reviews tokens with its own ServiceAccount (system:auth-delegator)
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443

bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
'
echo "OpenBao configured for External Secrets Operator"
