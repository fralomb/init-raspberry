# Fresh install and OpenBao secrets test

Rebuild the cluster from scratch and check that every secret flows from OpenBao:

| OpenBao path | Kubernetes Secret | Consumer | Delivered by |
|---|---|---|---|
| `secret/cloudflare` | `kube-system/cloudflare` | cert-manager DNS-01 | k3s addon |
| `secret/argocd/repo-init-raspberry` | `gitops/repo-init-raspberry` | Argo CD repo access | k3s addon |
| `secret/tailscale/operator-oauth` | `tailscale/operator-oauth` | Tailscale operator | Argo CD (`apps/tailscale`) |
| `secret/open-webui` | `ai/open-webui-secret` | Open WebUI | Argo CD (`apps/ai`) |

Bootstrap order: k3s addons (OpenBao, ESO, cert-manager, Argo CD) → manual init/unseal →
secrets in OpenBao → ESO syncs → certificates and Argo CD repo access → Argo CD deploys
Tailscale and the AI stack.

## 0. Before you start
- On the control machine: `ansible`, `kubectl`, and the OpenBao CLI
  (`brew install openbao`, binary `bao`).
- Collect the secret values:
  - Cloudflare API token (Zone → DNS → Edit on `francesco-lombardo.it`)
  - Tailscale OAuth client ID and secret (tag `tag:k8s-operator`)
  - GitHub App: numeric **App ID** (not the `Iv1.…` Client ID), installation ID, private key `.pem`
  - Open WebUI: an admin email and password
- In the Tailscale admin console, delete the old `homelab-k8s-operator` and `homelab-subnet-router`
  machines. Otherwise the new ones register as `…-1`.

## 1. Wipe the cluster
```bash
ssh pi@192.168.1.15 'sudo /usr/local/bin/k3s-agent-uninstall.sh'   # worker first
ssh pi@192.168.1.16 'sudo /usr/local/bin/k3s-uninstall.sh'
rm -f ~/.kube/config-raspberry
```
The uninstall scripts remove k3s, its data and every PersistentVolume under
`/var/lib/rancher/k3s/storage` (OpenBao, Open WebUI). The Ollama models on the SSD
(`/mnt/ssd/ollama`) are kept and reused. To test the model download as well:
`ssh pi@192.168.1.15 'sudo rm -rf /mnt/ssd/ollama/*'`.

## 2. Install
```bash
git checkout claude/dazzling-keller-oao382
ansible-playbook playbook.yaml -K
export KUBECONFIG=~/.kube/config-raspberry
kubectl get nodes -L homelab/ai          # both Ready, k3s-worker-1 has homelab/ai=true
kubectl -n kube-system get helmcharts    # openbao, external-secrets, cert-manager, argocd
```

## 3. Initialise and unseal OpenBao
```bash
kubectl -n openbao get pods               # openbao-0 Running, 0/1 (sealed)
kubectl -n openbao exec -ti openbao-0 -- bao operator init
```
This prints 5 unseal keys and the root token **once**. Store them in your password manager.
```bash
# 3 times, a different key each time (prompted)
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal
kubectl -n openbao exec openbao-0 -- bao status       # Initialized true, Sealed false
kubectl -n openbao get pods                           # openbao-0 1/1
```

## 4. Configure OpenBao for External Secrets
```bash
BAO_TOKEN=<root token> k3s/openbao/configure.sh
kubectl get clustersecretstore openbao                # STATUS Valid, READY True
```

## 5. Store the secrets
There is no certificate yet (it needs the Cloudflare token), so go through a port-forward:
```bash
kubectl -n openbao port-forward svc/openbao 8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login                                              # paste the root token

bao kv put secret/cloudflare api-token=<token>
bao kv put secret/tailscale/operator-oauth client_id=<id> client_secret=<secret>
bao kv put secret/argocd/repo-init-raspberry \
  githubAppID=<app id> githubAppInstallationID=<installation id> \
  githubAppPrivateKey=@/path/to/app.private-key.pem
bao kv put secret/open-webui secret-key=$(openssl rand -hex 32) \
  admin-email=<email> admin-password=<password>

bao kv list secret/                                   # argocd/ cloudflare open-webui tailscale/
```

## 6. Bootstrap secrets synced
```bash
kubectl get externalsecrets -A
#   kube-system  cloudflare            SecretSynced
#   gitops       repo-init-raspberry   SecretSynced
kubectl -n gitops get secret repo-init-raspberry --show-labels   # secret-type=repository
kubectl -n kube-system get certificate francesco-lombardo-it-cert  # READY True (1-2 min)
```
ESO refreshes every hour. To sync right away, force it:
`kubectl -n kube-system annotate externalsecret cloudflare force-sync=$(date +%s) --overwrite`.

Now `https://bao.homelab.francesco-lombardo.it` and `https://argocd.homelab.francesco-lombardo.it`
serve a valid certificate.

## 7. Argo CD: sync from the branch
```bash
kubectl -n gitops patch application homelab-apps --type merge \
  -p '{"spec":{"source":{"targetRevision":"claude/dazzling-keller-oao382"}}}'
kubectl -n gitops get applications -w
#   homelab-apps, tailscale-operator, ollama, open-webui → Synced / Healthy
```
While the Tailscale CRDs are installing, the root app briefly shows a failed sync for the
`Connector`; its retry settles it. Argo CD UI admin password:
`kubectl -n gitops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

## 8. Tailscale
```bash
kubectl -n tailscale get externalsecret operator-oauth    # SecretSynced
kubectl -n tailscale get pods                             # operator + subnet router Running
kubectl get connector homelab-subnet-router               # SubnetRouter, Ready
```
In the admin console, `homelab-k8s-operator` and `homelab-subnet-router` show up and the
`192.168.1.0/24` route is auto-approved. Test from a phone on mobile data with Tailscale on:
`https://argocd.homelab.francesco-lombardo.it` loads.

## 9. Local AI
```bash
kubectl -n ai get pods,pvc -o wide        # ollama on k3s-worker-1, open-webui on k3s-master
kubectl -n ai get externalsecret open-webui-secret        # SecretSynced
kubectl -n ai logs deploy/ollama -f       # model pulls (only if the SSD was wiped)
```
If the Open WebUI pod started before its Secret was synced, it ran without it (all the
references are optional). Restart it once so it creates the admin account and uses the fixed
session key:
```bash
kubectl -n ai rollout restart statefulset open-webui
```
Log in at `https://ai.homelab.francesco-lombardo.it` with the admin email and password from
OpenBao, then create an API key (Settings → Account) and test:
```bash
curl https://ai.homelab.francesco-lombardo.it/api/chat/completions \
  -H "Authorization: Bearer <key>" -H 'Content-Type: application/json' \
  -d '{"model": "qwen3:1.7b", "messages": [{"role": "user", "content": "hello"}]}'
```

## 10. OpenBao scenarios
**Rotation.** A change in OpenBao reaches the Secret:
```bash
bao kv patch secret/open-webui secret-key=$(openssl rand -hex 32)
kubectl -n ai annotate externalsecret open-webui-secret force-sync=$(date +%s) --overwrite
kubectl -n ai get secret open-webui-secret -o jsonpath='{.data.secret-key}' | base64 -d; echo
kubectl -n ai rollout restart statefulset open-webui   # env vars are read at start
```

**Sealed OpenBao.** Apps keep working and only the refreshes fail:
```bash
kubectl -n openbao delete pod openbao-0                # comes back sealed (0/1)
kubectl -n kube-system annotate externalsecret cloudflare force-sync=$(date +%s) --overwrite
kubectl get clustersecretstore openbao                 # not Valid
kubectl get externalsecrets -A                         # SecretSyncedError...
kubectl -n kube-system get secret cloudflare           # ...but the Secret is still there
curl -sI https://ai.homelab.francesco-lombardo.it | head -1   # still served
```
Then unseal (step 3, three keys) and the store and ExternalSecrets go back to Valid and
SecretSynced at the next refresh (or force-sync).

**Node reboot.** Reboot the node running OpenBao
(`kubectl -n openbao get pod openbao-0 -o wide`) and check it comes back sealed. Unseal, and
nothing else is needed.

**Backup and restore.**
```bash
bao operator raft snapshot save bao-$(date +%F).snap
# restore test (overwrites the current data):
bao operator raft snapshot restore bao-<date>.snap
```
The snapshot is encrypted and only usable with the unseal keys.

## 11. Finish
- Create a personal login instead of the root token, then revoke it:
  ```bash
  bao auth enable userpass
  bao policy write admin - <<'EOF'
  path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"] }
  EOF
  bao write auth/userpass/users/<you> password=<password> policies=admin
  bao token revoke -self
  ```
  A new root token can be generated at any time with the unseal keys (`bao operator generate-root`).
- Merge the PR. Then either re-run the playbook, or reset the root app with
  `kubectl -n gitops patch application homelab-apps --type merge -p '{"spec":{"source":{"targetRevision":"HEAD"}}}'`.
