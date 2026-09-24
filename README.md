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
- `argocd.homelab.francesco-lombardo.it` resolves to the master node (local DNS or a Cloudflare record).
- TLS uses Traefik's default TLSStore: the `*.homelab.francesco-lombardo.it` name is part of the
  `francesco-lombardo-it-cert` certificate in [k3s/cert-manager/cloudflare-issuer.yaml](k3s/cert-manager/cloudflare-issuer.yaml).
  Without it, Traefik serves its self-signed certificate.

Initial `admin` password:
```
kubectl -n gitops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Traefik
k3s ships Traefik v3 as a packaged component. [k3s/traefik/traefik_config.yaml](k3s/traefik/traefik_config.yaml)
is a `HelmChartConfig` that overrides its values (HTTP→HTTPS redirect, default TLSStore,
dashboard, access logs). It is installed through `k3s_addons` like Argo CD. The values target the
Traefik chart version bundled with the pinned `k3s_version` (chart 40.1.x for `v1.36.4+k3s1`):
re-check them against that chart's `values.yaml` when bumping k3s.

### Cert-Manager
[How to configure](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md#provide-default-certificate-with-cert-manager-and-cloudflare-dns) Traefik with Cert-Manger for signed certificates.

`Cert-Manager` is installed via its [Helm chart](https://cert-manager.io/docs/installation/helm/)
([k3s/cert-manager/cert-manager-chart.yaml](k3s/cert-manager/cert-manager-chart.yaml)), and the
Cloudflare DNS-01 `Issuer` plus the wildcard `Certificate`s live in
[k3s/cert-manager/cloudflare-issuer.yaml](k3s/cert-manager/cloudflare-issuer.yaml). Both are in
`k3s_addons`; k3s retries the issuer file until the chart has installed the cert-manager CRDs.

Create a secret containing the API token of Cloudflare in the `kube-system` namespace (where the
`Issuer` and Traefik live):
```
kubectl create secret generic cloudflare --from-literal=api-token=XXX --type=Opaque --namespace kube-system
```

### Cloudflare DDNS
Allows to dynamically change the IP address of the domains defined in Cloudflare using an API Token.
Based on this [repo](https://github.com/timothymiller/cloudflare-ddns).

At the moment, it is using a secret injected in the deployment, but it needs to be re-thinked using some kind of Secrets management tool.

In order to generate the configuration use `envsubst` to substitute the cloudflare secrets:
```
CF_API_TOKEN="XXX" CF_ZONE_ID_1="YYY" CF_ZONE_ID_2="ZZZ" envsubst < k3s/ddns/config.json > config.json
```
Then, create the secret using the file:
```
kubectl create secret generic config-cloudflare-ddns --from-file=config.json -n ddns
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
