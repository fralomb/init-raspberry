# Raspberry Pi k3s cluster bootstrap

Ansible playbooks to turn one or more fresh Raspberry Pis into a lightweight
[k3s](https://docs.k3s.io) Kubernetes cluster: one master node and zero or more workers.

## 1. Choose the OS

**Recommended: Raspberry Pi OS Lite (64-bit)** — official Debian-based image, no desktop,
~60-80MB RAM idle, best driver/firmware support, and the reference platform in the
[k3s Raspberry Pi docs](https://docs.k3s.io/installation/requirements#operating-systems).
The 64-bit variant is required for many container images (arm64).

Alternative if you want the absolute minimum footprint: [DietPi](https://dietpi.com)
(~30-50MB RAM idle, ~500MB disk). It is also Debian-based, so these playbooks work on it
too, but Raspberry Pi OS Lite is the safer default for hardware support.

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
ansible-playbook playbook.yaml
```

What it does:

- **`common` role** (all nodes): installs base packages, appends
  `cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset` to `cmdline.txt`
  (`/boot/firmware/cmdline.txt` on Bookworm+, `/boot/cmdline.txt` on older releases),
  disables `dphys-swapfile`, and reboots if the kernel parameters changed.
- **`k3s-server` role** (master): installs k3s in server mode via the official
  `get.k3s.io` script and reads the generated node token.
- **`k3s-agent` role** (workers): installs k3s in agent mode, joining the master with
  the token collected in the previous play. With an empty `[workers]` group this play
  simply skips, leaving a single-node cluster.

Pin a k3s version or change channel in [group_vars/all.yaml](group_vars/all.yaml)
(`k3s_version`, `k3s_channel`).

## 5. Verify and access the cluster

On the master:

```bash
sudo k3s kubectl get nodes -o wide
```

From outside, copy `/etc/rancher/k3s/k3s.yaml` from the master (or set
`k3s_fetch_kubeconfig: true` in the `k3s-server` role vars), then replace `127.0.0.1`
with the master IP:

```bash
sed 's/127.0.0.1/<master-ip>/' k3s.yaml > ~/.kube/config-raspberry
export KUBECONFIG=~/.kube/config-raspberry
kubectl get nodes
```

### Troubleshooting

- `k3s check-config` complains about cgroups → confirm the parameters landed in
  `/proc/cmdline`; the node needs a reboot after editing `cmdline.txt`.
- On Ubuntu (not Raspberry Pi OS) the vxlan module is separate:
  `sudo apt install linux-modules-extra-raspi`.
- Using `wireguard-native` as Flannel backend requires `sudo apt install wireguard`.
- `restorecon: command not found` → `sudo apt-get install policycoreutils`.

## K3s dependencies
### Argocd
TODO

### Traefik
TODO

### Cert-Manager
[How to configure](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md#provide-default-certificate-with-cert-manager-and-cloudflare-dns) Traefik with Cert-Manger for signed certificates.

Install `Cert-Manager` via [Helm chart](https://cert-manager.io/docs/installation/helm/).


Create a secret containing the API token of Cloudflare in the `traefik` namespace:
```
kubectl create secret generic cloudflare --from-literal=api-token=XXX --type=Opaque --namespace traefik
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
