# Raspberry Pi k3s cluster bootstrap

Ansible playbooks to turn one or more fresh Raspberry Pis into a lightweight
[k3s](https://docs.k3s.io) Kubernetes cluster: one master node and zero or more workers.

## 1. Choose the OS

**Required: Raspberry Pi OS Lite (64-bit), Bookworm (Debian 12) or later.**

These playbooks target that baseline *only*. They depend on behaviour introduced in
Bookworm and make no attempt to support older releases or other distributions:

- the kernel command line lives at `/boot/firmware/cmdline.txt` (moved from `/boot/`)
- cgroup v2 unified hierarchy — `memory` is exposed via `/sys/fs/cgroup/cgroup.controllers`
- swap is provided by zram (`systemd-zram-setup@zram0`), not `dphys-swapfile`, so the
  playbooks do no swap handling at all: zram is compressed RAM, never touches the SD
  card, and k3s tolerates it

The 64-bit variant is required — most container images are arm64 only.

Verified on Raspberry Pi OS Trixie (Debian 13), arm64, Raspberry Pi 4 Model B.

DietPi, Ubuntu Server and other Debian derivatives are **not supported and not tested**;
expect to adjust the `common` role if you use one.

## 2. Flash the SD card

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (`brew install raspberry-pi-imager` on macOS):

1. Choose device → your Pi model.
2. Choose OS → *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**.
3. Choose storage → the SD card.
4. Before writing, open the OS customisation settings (`Cmd+Shift+X` / "Edit settings") and set:
   - **Hostname**: unique per node (e.g. `k3s-master`, `k3s-worker-1`).
   - **Username/password**: e.g. user `pi`.
   - **Enable SSH** with public-key authentication (paste your `~/.ssh/id_*.pub`).
   - **Wi-Fi** credentials only if not using ethernet (prefer ethernet for cluster nodes).
5. Write, boot the Pi, and verify access: `ssh pi@<node-ip>`.

Repeat for every node. Give each node a static IP (DHCP reservation on the router is the
easiest way) so the inventory stays stable.

## 3. Configure the inventory

Edit [inventory/hosts](inventory/hosts): one host in `[master]`, zero or more in `[workers]`.

```ini
[master]
k3s-master ansible_host=192.168.1.10

[workers]
k3s-worker-1 ansible_host=192.168.1.11
```

## 4. Run the playbook

```bash
ansible-playbook playbook.yaml -K
```

`-K` prompts for the sudo password. Raspberry Pi OS only grants passwordless sudo to the
legacy default user, so an Imager-created user needs it. If your nodes have different sudo
passwords, use an `ansible-vault` encrypted `ansible_become_password` per host instead.

What it does:

- **`common` role** (all nodes): installs base packages, appends
  `cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset` to
  `/boot/firmware/cmdline.txt`, and reboots if the kernel parameters changed. Note the
  Pi firmware injects `cgroup_disable=memory`; the appended `cgroup_enable=memory`
  comes later on the command line and wins.
- **`k3s-server` role** (master): installs k3s in server mode via the official
  `get.k3s.io` script and reads the generated node token.
- **`k3s-agent` role** (workers): installs k3s in agent mode, joining the master with
  the token collected in the previous play. With an empty `[workers]` group this play
  simply skips, leaving a single-node cluster.

`k3s_version` in [group_vars/all.yaml](group_vars/all.yaml) is pinned to an exact
release. This keeps every node on the same version and skips the `update.k3s.io`
channel lookup the install script would otherwise do. Blank it to track `k3s_channel`
(`stable`/`latest`) instead.

## 5. Verify and access the cluster

On the master:

```bash
sudo k3s kubectl get nodes -o wide
```

From your machine, `k3s_fetch_kubeconfig` (on by default) pulls the kubeconfig to
`~/.kube/config-raspberry` at the end of the master play, rewrites the server address
from `127.0.0.1` to the master's IP, renames the cluster/user/context from `default` to
`localk3s`, and chmods it to `0600`. It is written outside the repo deliberately — it
holds a cluster-admin client certificate and key.

```bash
export KUBECONFIG=~/.kube/config-raspberry
kubectl get nodes
```

To merge it into your main kubeconfig instead:

```bash
KUBECONFIG=~/.kube/config:~/.kube/config-raspberry kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config
kubectl config use-context localk3s
```

Change the destination and the name with `k3s_kubeconfig_dest` and `k3s_context_name` in
[roles/k3s-server/defaults/main.yaml](roles/k3s-server/defaults/main.yaml).

### Troubleshooting

- `k3s check-config` complains about cgroups → confirm the parameters landed in
  `/proc/cmdline`; the node needs a reboot after editing `cmdline.txt`.
- Using `wireguard-native` as Flannel backend requires `sudo apt install wireguard`.
- `restorecon: command not found` → `sudo apt-get install policycoreutils`.

## K3s dependencies
### Secrets (OpenBao + External Secrets)
Secrets are kept in [OpenBao](https://openbao.org) (the open-source fork of HashiCorp Vault) and
synced into Kubernetes Secrets by the [External Secrets Operator](https://external-secrets.io)
(ESO). Nothing secret is committed and there are no `kubectl create secret` steps. Both are the
first entries of `k3s_addons`, since every other component waits for a Secret from them:

- [k3s/openbao/openbao-chart.yaml](k3s/openbao/openbao-chart.yaml): OpenBao, single node with
  integrated Raft storage, UI at `https://bao.homelab.francesco-lombardo.it`.
- [k3s/external-secrets/external-secrets-chart.yaml](k3s/external-secrets/external-secrets-chart.yaml): ESO.
- [k3s/external-secrets/openbao-secret-store.yaml](k3s/external-secrets/openbao-secret-store.yaml): the
  `openbao` `ClusterSecretStore`. ESO logs in with its own ServiceAccount through OpenBao's
  Kubernetes auth, so there is no token to store.
- One `ExternalSecret` next to each consumer (`*-secret.yaml`), reading a path under `secret/`.

| OpenBao path | Keys | Kubernetes Secret |
|---|---|---|
| `secret/cloudflare` | `api-token` | `kube-system/cloudflare` |
| `secret/tailscale/operator-oauth` | `client_id`, `client_secret` | `tailscale/operator-oauth` |
| `secret/argocd/repo-init-raspberry` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | `gitops/repo-init-raspberry` |
| `secret/open-webui` | `secret-key`, `admin-email`, `admin-password` (optional) | `ai/open-webui-secret` |

#### Sealing
OpenBao encrypts its storage with a root key that never touches the disk. At init the key is
split into 5 **unseal keys**, any 3 of which rebuild it. After every restart (pod, node reboot,
upgrade) OpenBao starts **sealed**: it answers nothing until 3 unseal keys are entered. The
already synced Kubernetes Secrets are kept meanwhile, so running apps are not affected: only
new or changed secrets wait for the unseal.

#### First setup
Once the playbook has run and the `openbao-0` pod is `Running` (not Ready: it is sealed):
```bash
# 1. Init, unseal, and configure the KV engine, ESO policy and Kubernetes auth role.
#    No certificate yet: Traefik serves its self-signed one, hence the flag.
ansible-playbook openbao.yaml -e openbao_validate_certs=false

# 2. Secrets (paths and keys in the table above), with the local CLI (brew install openbao)
export BAO_ADDR=https://bao.homelab.francesco-lombardo.it
export BAO_SKIP_VERIFY=true                 # until the certificate is issued
jq -r .root_token ~/.config/homelab/openbao-init.json | bao login -
bao kv put secret/cloudflare api-token=XXX
```
[openbao.yaml](openbao.yaml) runs the [openbao](roles/openbao) role from the control machine
against the OpenBao API at `https://bao.homelab.francesco-lombardo.it`. That IngressRoute points
to the UI Service, which includes the sealed pod, so init and unseal go through it too. Each
phase checks the current state first:

1. **Init** (only if not initialised): the 5 unseal keys and the root token are written to
   `~/.config/homelab/openbao-init.json` (mode 0600, outside the repo), not printed.
2. **Unseal** (only if sealed): with the keys from that file or, if it does not exist, prompted for.
3. **Configure**: KV v2 mount, policies and Kubernetes auth roles from
   [roles/openbao/defaults/main.yaml](roles/openbao/defaults/main.yaml), writing only what differs.
   The token is `-e openbao_token=...`, else the root token from the file, else prompted for.

The same command is used after a restart (unseal) and after changing the defaults (configure):
`ansible-playbook openbao.yaml`. `-e openbao_validate_certs=false` is only needed until the
wildcard certificate exists.

Whoever has the init file can unseal OpenBao and has the root token, which defeats splitting
the key. Once everything works, copy the keys and token to a password manager and delete
the file: from then on the playbook asks for them.

The `bao kv put` examples in the sections below assume that shell. The UI at
`https://bao.homelab.francesco-lombardo.it` works too.

The whole sequence, from wiping the nodes to testing rotation, sealing and backups, is in
[docs/fresh-install.md](docs/fresh-install.md).

Secrets created earlier with `kubectl create secret` are taken over by their `ExternalSecret`
(same name) at the first sync, so migrating needs no downtime.

After a restart, `ansible-playbook openbao.yaml` unseals it. Check with:
```bash
bao status                                             # Sealed: false
kubectl get clustersecretstore openbao                 # STATUS Valid
kubectl get externalsecrets -A                         # STATUS SecretSynced
```

#### Backups
Raft snapshots hold every secret, encrypted with the root key, so they are only usable with the
unseal keys:
```bash
bao operator raft snapshot save bao-$(date +%F).snap
```

### Argocd
Installed by the `k3s-server` role through the k3s
[auto-deploying AddOns](https://docs.k3s.io/installation/packaged-components#auto-deploying-manifests-addons):
every file listed in `k3s_addons` ([roles/k3s-server/defaults/main.yaml](roles/k3s-server/defaults/main.yaml))
is copied to `/var/lib/rancher/k3s/server/manifests/`, and k3s applies it on start and on
every change. [k3s/argocd/argocd-chart.yaml](k3s/argocd/argocd-chart.yaml) is a `HelmChart`
that installs Argo CD in the `gitops` namespace, plus a Traefik `IngressRoute` exposing the
dashboard (and the gRPC API for the `argocd` CLI) at `https://argocd.homelab.francesco-lombardo.it`.

To change the Argo CD config, edit the manifest and re-run the playbook. Check the install with:
```
kubectl -n kube-system get helmchart argocd
kubectl -n kube-system logs job/helm-install-argocd
kubectl -n gitops get pods,ingressroute
```

Prerequisites:
- `argocd.homelab.francesco-lombardo.it` resolves to the master node (see [Tailscale](#tailscale-private-access)).
- TLS uses Traefik's default TLSStore: the `*.homelab.francesco-lombardo.it` name is part of the
  `francesco-lombardo-it-cert` certificate in [k3s/cert-manager/cloudflare-issuer.yaml](k3s/cert-manager/cloudflare-issuer.yaml).
  Without it, Traefik serves its self-signed certificate.

Initial `admin` password:
```
kubectl -n gitops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

#### Applications (app of apps)
[k3s/argocd/argocd-apps.yaml.j2](k3s/argocd/argocd-apps.yaml.j2), also in `k3s_addons`, is the root
`homelab-apps` Application: Argo CD syncs every manifest under [apps/](apps) (recursively, with
prune and self-heal), and those are the Applications of the homelab workloads. Add a workload by
committing its manifests there, not by editing `k3s_addons`.

It is an Ansible template (AddOns ending in `.j2` are rendered, the others copied as they are):
the revision it syncs is `argocd_apps_revision`, `HEAD` (the default branch, `master`) unless
overridden. To test a branch before merging:
```
ansible-playbook playbook.yaml -K -e argocd_apps_revision=<branch>
```
A plain `kubectl patch` of the Application would be undone at the next playbook run or k3s
restart, when k3s re-applies the AddOn. On a branch that does not exist on `master` yet, Argo CD
otherwise reports `apps: app path does not exist`.

The repo is private, so Argo CD reads it through a GitHub App. Create the App (permission
*Contents: read-only*), install it on this repository and generate a private key (a `.pem`,
`-----BEGIN RSA PRIVATE KEY-----`). Store it in [OpenBao](#secrets-openbao--external-secrets):
```
bao kv put secret/argocd/repo-init-raspberry \
  githubAppID=<app-id> githubAppInstallationID=<installation-id> \
  githubAppPrivateKey=@argocd-app.private-key.pem
```
[k3s/argocd/argocd-repo-secret.yaml](k3s/argocd/argocd-repo-secret.yaml) turns it into the
`repo-init-raspberry` Secret in `gitops` (the only namespace Argo CD reads repository Secrets
from), adding `type`, `url` and the `argocd.argoproj.io/secret-type: repository` label.
Both IDs are plain numbers:
- `githubAppID` is the **App ID** shown at the top of the App's settings page (Settings →
  Developer settings → GitHub Apps → *app* → General). It is not the Client ID (`Iv1.…`) listed
  just below it. With the Client ID, Argo CD fails with `strconv.ParseInt: parsing "Iv1.…"`.
- `githubAppInstallationID` is the number at the end of the installation's settings URL
  (`https://github.com/settings/installations/<id>`).

Check with `kubectl -n gitops get applications`.

### Traefik
k3s ships Traefik v3 as a packaged component. [k3s/traefik/traefik-config.yaml](k3s/traefik/traefik-config.yaml)
is a `HelmChartConfig` that overrides its values (HTTP→HTTPS redirect, default TLSStore,
dashboard disabled, access logs). It is installed through `k3s_addons` like Argo CD. The values target the
Traefik chart version bundled with the pinned `k3s_version` (chart 40.1.x for `v1.36.4+k3s1`):
re-check them against that chart's `values.yaml` when bumping k3s.

### Cert-Manager
[How to configure](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md#provide-default-certificate-with-cert-manager-and-cloudflare-dns) Traefik with Cert-Manger for signed certificates.

`Cert-Manager` is installed via its [Helm chart](https://cert-manager.io/docs/installation/helm/)
([k3s/cert-manager/cert-manager-chart.yaml](k3s/cert-manager/cert-manager-chart.yaml)), and the
Cloudflare DNS-01 `Issuer` plus the wildcard `Certificate`s live in
[k3s/cert-manager/cloudflare-issuer.yaml](k3s/cert-manager/cloudflare-issuer.yaml). Both are in
`k3s_addons`; k3s retries the issuer file until the chart has installed the cert-manager CRDs.

The Cloudflare API token (permission *Zone → DNS → Edit*) goes in
[OpenBao](#secrets-openbao--external-secrets); [k3s/cert-manager/cloudflare-secret.yaml](k3s/cert-manager/cloudflare-secret.yaml)
syncs it to the `cloudflare` Secret in `kube-system`, where the `Issuer` and Traefik live:
```
bao kv put secret/cloudflare api-token=XXX
```

### Tailscale (private access)
Nothing in the homelab is exposed to the internet: no router port forwarding, no DDNS. Remote
access goes through [Tailscale](https://tailscale.com/kb/1236/kubernetes-operator), running in the
cluster, deployed by Argo CD from [apps/tailscale/](apps/tailscale):

- [apps/tailscale/tailscale-operator.yaml](apps/tailscale/tailscale-operator.yaml) is the Application
  installing the Tailscale Kubernetes operator chart in the `tailscale` namespace.
- [apps/tailscale/subnet-router.yaml](apps/tailscale/subnet-router.yaml) is a `Connector` that makes the
  operator run a subnet router advertising `192.168.1.0/24`, so tailnet devices reach the LAN (and
  Traefik on the master) as if they were at home. What tailnet users can actually reach through it
  is decided by the [tailnet policy](#tailnet-policy).

DNS is a single static Cloudflare record, **DNS only** (grey cloud): `*.homelab.francesco-lombardo.it`
`A` → `192.168.1.16` (the master's LAN IP). The same name works at home without Tailscale and remotely
through it; certificates keep working since the DNS-01 challenge needs no inbound traffic. If a
name does not resolve at home, the router's DNS rebinding protection is dropping answers with a
private IP: allow the domain there.

One-time setup in the [Tailscale admin console](https://login.tailscale.com/admin):

1. Access controls: apply the [tailnet policy](#tailnet-policy) below.
2. Settings → Trust credentials: create an OAuth client with the scopes listed in the
   [operator docs](https://tailscale.com/kb/1236/kubernetes-operator#prerequisites) (`Devices Core`,
   `Auth Keys`, `Services` write) and tag `tag:k8s-operator`.
3. Store it in [OpenBao](#secrets-openbao--external-secrets). The operator pod waits for the
   `operator-oauth` Secret, synced by [apps/tailscale/operator-oauth-secret.yaml](apps/tailscale/operator-oauth-secret.yaml):
   ```
   bao kv put secret/tailscale/operator-oauth client_id=XXX client_secret=YYY
   ```

Check with `kubectl get connector` and `kubectl -n tailscale get pods`; the `homelab-subnet-router`
device then shows up in the admin console with the route approved.

#### Tailnet policy
Paste into Access controls → JSON editor, replacing the default allow-all policy. The subnet
router enforces these grants on routed traffic, so the tailnet only reaches the homelab, not the
whole home network.

```jsonc
{
  // The operator tags itself tag:k8s-operator and the devices it creates tag:k8s.
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  },
  // Approve the Connector's route without a manual click.
  "autoApprovers": {
    "routes": { "192.168.1.0/24": ["tag:k8s"] }
  },
  "grants": [
    // Your own devices can talk to each other
    { "src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"] },
    // Homelab services through Traefik on the master
    { "src": ["autogroup:member"], "dst": ["192.168.1.16/32"], "ip": ["tcp:443", "tcp:80"] },
    // SSH to the k3s nodes (master + worker) and the Kubernetes API
    { "src": ["autogroup:member"], "dst": ["192.168.1.15/32", "192.168.1.16/32"], "ip": ["tcp:22"] },
    { "src": ["autogroup:member"], "dst": ["192.168.1.16/32"], "ip": ["tcp:6443"] }
  ],
  // Checked on every save: a failing test rejects the change and the old policy stays active.
  "tests": [
    {
      "src": "fra.lombardo92@gmail.com",
      "accept": ["192.168.1.16:443", "192.168.1.15:22"],
      // Home router UI and Traefik's internal entrypoint (8080) must stay unreachable
      "deny": ["192.168.1.1:443", "192.168.1.16:8080"]
    }
  ]
}
```

- `tagOwners` and `autoApprovers` grant no access; only `grants` does. Tagged devices (operator,
  subnet router) get no grant, so they cannot open connections towards your devices.
- `tests` does not change access: each entry asserts that traffic from `src` is allowed to every
  `accept` destination and blocked for every `deny` one (`host:port`). Update it together with
  the grants, and change `src` if your Tailscale login differs.
- Keep the node IPs in sync with [inventory/hosts](inventory/hosts) and the route with
  [apps/tailscale/subnet-router.yaml](apps/tailscale/subnet-router.yaml).
- Add back an `ssh` section only if you use Tailscale SSH; plain SSH through the subnet route uses
  the `tcp:22` grant.

## Local AI models
[Ollama](https://ollama.com) serves the models and [Open WebUI](https://docs.openwebui.com) is
the chat UI and API in front of it, both deployed by Argo CD from [apps/ai/](apps/ai):

| | Node | Exposed |
|---|---|---|
| Ollama ([apps/ai/ollama.yaml](apps/ai/ollama.yaml)) | Pi 5 (8 GB), label `homelab/ai=true` | no: ClusterIP only, it has no authentication |
| Open WebUI ([apps/ai/open-webui.yaml](apps/ai/open-webui.yaml)) | any other node | `https://ai.homelab.francesco-lombardo.it` |

Inference runs on the CPU (llama.cpp), so stick to small quantized models. On the Pi 5,
`qwen3:1.7b`/`gemma3:1b` answer quickly and `qwen3:4b`/`gemma3:4b`/`llama3.2:3b` are better
but slower (a few tokens/s); 7–8B models fit but crawl. Ollama keeps one model in memory at a
time (`OLLAMA_MAX_LOADED_MODELS=1`) and is capped at 6 GiB, so a model too large is OOM-killed
instead of starving the node.

### USB SSD for the model weights
Models are GBs each: they live on a USB SSD on the Pi 5, not on the SD card. The disk is
formatted **ext4** (the container needs POSIX ownership; exFAT/NTFS don't have it). Formatting is
a one-time manual step since it wipes the disk:
```bash
lsblk -f                              # find the SSD, e.g. /dev/sda
sudo wipefs -a /dev/sda
sudo parted -s /dev/sda mklabel gpt mkpart ssd ext4 0% 100%
sudo mkfs.ext4 -L ssd /dev/sda1
```
The `ssd-storage` role mounts it for hosts with `ssd_storage: true`
([host_vars/k3s-worker-1.yaml](host_vars/k3s-worker-1.yaml)): `LABEL=ssd` on `/mnt/ssd` via
fstab, with `nofail` so the Pi still boots without the disk, and creates `/mnt/ssd/ollama`. If
the disk is already mounted elsewhere or has another label, set `ssd_mount`/`ssd_label` there
(defaults in [roles/ssd-storage/defaults/main.yaml](roles/ssd-storage/defaults/main.yaml)).
It uses the `ansible.posix` collection, part of the full `ansible` package; with `ansible-core`
only, run `ansible-galaxy collection install -r requirements.yml`.

[apps/ai/storage.yaml](apps/ai/storage.yaml) turns that directory into a `local` PersistentVolume
bound to the `homelab/ai=true` node, which also pins Ollama there.

### Node label
`k3s_node_labels` in a host's vars is applied by the last play of `playbook.yaml` (the node name
is the inventory hostname, which must match the Pi's hostname). To set it without the playbook:
```
kubectl label node k3s-worker-1 homelab/ai=true
```

### Models
The models in `ollama.models.pull` are downloaded at pod start when missing from the SSD
(`nomic-embed-text` is the embedding model Open WebUI uses for documents). Pull others through
the UI (Admin settings → Models) or:
```
kubectl -n ai exec deploy/ollama -- ollama pull gemma3:4b
kubectl -n ai exec deploy/ollama -- ollama list
```

### Open WebUI
Open WebUI reaches Ollama through `OLLAMA_BASE_URLS` (`ollamaUrls` in the chart values), so the
pulled models show up in the model picker with nothing to set in the UI. Admin settings →
Connections shows the in-cluster URL.

Its settings are declared in [apps/ai/open-webui.yaml](apps/ai/open-webui.yaml) and git wins:
`ENABLE_PERSISTENT_CONFIG=False` re-applies them on every start, so a change made in Admin
settings lasts until the next restart unless it is copied into the values. Users, chats and model
presets are stored in the database and are kept. Configured there:
sign-ups disabled, API keys enabled, `qwen3:1.7b` as default and task model (titles, tags), and
document embeddings through Ollama (`nomic-embed-text`).

What can't be committed lives in [OpenBao](#secrets-openbao--external-secrets) at
`secret/open-webui`, synced to the `open-webui-secret` Secret by an `ExternalSecret` shipped with
the chart (`extraResources`). All its keys are optional:
- `secret-key` signs the login sessions. Without it, a random key is generated at every start and
  everyone is logged out on restart.
- `admin-email` / `admin-password` create the admin account at start if no user exists yet.
  Without them, the first account created in the UI becomes the admin (sign-ups stay disabled
  for everyone after that).
```
bao kv put secret/open-webui secret-key=$(openssl rand -hex 32) \
  admin-email=<email> admin-password=<password>
kubectl -n ai rollout restart statefulset open-webui   # env vars are read at start
```

OpenAI-compatible API for scripts, editors and agents: create a key in Settings → Account → API
keys, then use `https://ai.homelab.francesco-lombardo.it/api` as base URL:
```
curl https://ai.homelab.francesco-lombardo.it/api/chat/completions \
  -H "Authorization: Bearer $OPENWEBUI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model": "qwen3:1.7b", "messages": [{"role": "user", "content": "hello"}]}'
```

Check the deployment:
```
kubectl -n gitops get applications
kubectl -n ai get pods,pvc -o wide
kubectl -n ai logs deploy/ollama
```

## Extras

### Install Docker (optional)
k3s ships its own containerd, so Docker is **not** required for the cluster. If a node
needs standalone Docker anyway:

```bash
ansible-playbook docker-playbook.yaml
```

Docker-Compose is installed via pip, since the `docker/compose` release page has no
build for `arm`.

- Docker doc: [link](https://docs.docker.com/engine/install/debian/)
- Install Docker Engine: [link](https://docs.docker.com/engine/install/ubuntu/)
- Install Docker-Compose: [link](https://docs.docker.com/compose/install/)

### Install Ansible on the Pi itself
Only needed to run playbooks directly on a Raspberry: the bash script
`install-ansible` (run with sudo) will do the job.
