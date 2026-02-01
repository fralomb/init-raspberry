# Raspberry Pi K3s Cluster Setup

This repository contains Ansible playbooks and Kubernetes manifests to set up a complete K3s cluster on Raspberry Pi devices with GitOps capabilities.

## Overview

This project automates the setup of:
- **Raspberry Pi OS Lite** (64-bit headless) - Recommended lightweight distribution
- **K3s** - Lightweight Kubernetes distribution optimized for ARM
- **Gateway API** with Envoy Gateway - Modern Kubernetes ingress controller
- **Cert-Manager** - Automatic TLS certificate management via Let's Encrypt
- **ArgoCD** - GitOps continuous delivery

## Prerequisites

### Hardware
- One or more Raspberry Pi 4/5 (4GB+ RAM recommended)
- MicroSD cards (32GB+ recommended) or external SSDs (recommended for etcd)
- Network connectivity (Ethernet recommended for stability)

### Software
- Raspberry Pi OS Lite (64-bit) - [Download](https://www.raspberrypi.com/software/operating-systems/)
- SSH enabled on all Raspberry Pi devices
- Ansible installed on your control machine

## Quick Start

### 1. Install Ansible (on your control machine)

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y ansible

# macOS
brew install ansible

# Or run the provided script on Raspberry Pi
sudo ./install-ansible
```

### 2. Configure Inventory

Edit `inventory/hosts` to define your cluster:

```ini
[k3s_master]
raspberry-master ansible_host=192.168.1.100

[k3s_workers]
raspberry-worker-1 ansible_host=192.168.1.101
raspberry-worker-2 ansible_host=192.168.1.102

[k3s_cluster:children]
k3s_master
k3s_workers

[k3s_cluster:vars]
ansible_user=pi
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_python_interpreter=/usr/bin/python3
```

### 3. Configure SSH Access

```bash
# Copy your SSH key to all nodes
ssh-copy-id pi@192.168.1.100
ssh-copy-id pi@192.168.1.101
ssh-copy-id pi@192.168.1.102
```

### 4. Run the Playbook

```bash
# Full setup (system + K3s)
ansible-playbook -i inventory/hosts playbook.yaml

# System setup only
ansible-playbook -i inventory/hosts playbook.yaml --tags system-setup

# K3s installation only
ansible-playbook -i inventory/hosts playbook.yaml --tags k3s
```

### 5. Access the Cluster

After installation, copy the kubeconfig from the master node:

```bash
# From your local machine
scp pi@192.168.1.100:~/.kube/config ~/.kube/config

# Or directly use kubectl on the master
ssh pi@192.168.1.100 kubectl get nodes
```

## Kubernetes Components Installation

After K3s is installed, apply the Kubernetes manifests in order:

### 1. Gateway API

```bash
# Install Gateway API CRDs and Envoy Gateway
kubectl apply -f k3s/gateway-api/gateway-api-crds.yaml
kubectl apply -f k3s/gateway-api/envoy-gateway.yaml

# Wait for Envoy Gateway to be ready
kubectl wait --for=condition=available deployment/envoy-gateway -n envoy-gateway-system --timeout=120s

# Install GatewayClass and Gateway
kubectl apply -f k3s/gateway-api/gateway-class.yaml
kubectl apply -f k3s/gateway-api/default-gateway.yaml
```

### 2. Cert-Manager

```bash
# Install Cert-Manager
kubectl apply -f k3s/cert-manager/cert-manager-chart.yaml

# Wait for Cert-Manager to be ready
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=120s

# Create Cloudflare API token secret (update with your token)
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n cert-manager

# Apply ClusterIssuers and Certificates
kubectl apply -f k3s/cert-manager/cluster-issuers.yaml
kubectl apply -f k3s/cert-manager/certificates.yaml
```

### 3. ArgoCD

```bash
# Install ArgoCD
kubectl apply -f k3s/argocd/argocd-chart.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argocd-server -n gitops --timeout=180s

# Apply HTTPRoute for ingress
kubectl apply -f k3s/argocd/argocd-httproute.yaml

# Get initial admin password
kubectl -n gitops get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Configuration

### Update Domains

Before deploying, update the domain names in:
- `k3s/cert-manager/cluster-issuers.yaml` - Email addresses
- `k3s/cert-manager/certificates.yaml` - DNS names
- `k3s/argocd/argocd-chart.yaml` - ArgoCD domain
- `k3s/argocd/argocd-httproute.yaml` - ArgoCD hostname
- `k3s/gateway-api/default-gateway.yaml` - TLS certificate references

### Cloudflare Setup

For automatic TLS certificates with Cloudflare DNS:

1. Go to Cloudflare Dashboard -> My Profile -> API Tokens
2. Create Token -> Use template "Edit zone DNS"
3. Zone Resources: Include -> Specific zone -> your domain
4. Create the Kubernetes secret:
   ```bash
   kubectl create secret generic cloudflare-api-token \
     --from-literal=api-token=YOUR_TOKEN \
     -n cert-manager
   ```

### K3s Options

Customize K3s installation in `group_vars/all.yaml`:

```yaml
# K3s version
k3s_version: "v1.29.0+k3s1"

# Master node arguments
k3s_master_extra_args: >-
  --disable traefik
  --disable servicelb
  --write-kubeconfig-mode 644

# Worker node arguments
k3s_worker_extra_args: ""
```

## Directory Structure

```
.
├── README.md
├── playbook.yaml                 # Main Ansible playbook
├── install-ansible               # Script to install Ansible
├── inventory/
│   └── hosts                     # Ansible inventory
├── group_vars/
│   └── all.yaml                  # Global variables
├── roles/
│   ├── system-setup/             # System preparation role
│   │   ├── defaults/main.yaml
│   │   ├── handlers/main.yaml
│   │   └── tasks/
│   │       ├── main.yaml
│   │       ├── update-upgrade.yaml
│   │       ├── configure-cgroups.yaml
│   │       ├── install-requirements.yaml
│   │       └── install-helm.yaml
│   ├── k3s-master/               # K3s master installation
│   │   ├── defaults/main.yaml
│   │   ├── handlers/main.yaml
│   │   └── tasks/main.yaml
│   ├── k3s-worker/               # K3s worker installation
│   │   ├── defaults/main.yaml
│   │   ├── handlers/main.yaml
│   │   └── tasks/main.yaml
│   └── docker/                   # Docker installation (optional)
└── k3s/
    ├── gateway-api/              # Gateway API configuration
    │   ├── gateway-api-crds.yaml
    │   ├── envoy-gateway.yaml
    │   ├── gateway-class.yaml
    │   └── default-gateway.yaml
    ├── cert-manager/             # Certificate management
    │   ├── cert-manager-chart.yaml
    │   ├── cluster-issuers.yaml
    │   ├── certificates.yaml
    │   └── cloudflare-secret.yaml
    ├── argocd/                   # GitOps
    │   ├── argocd-chart.yaml
    │   └── argocd-httproute.yaml
    ├── traefik/                  # Legacy Traefik config
    └── ddns/                     # Dynamic DNS
```

## Install Docker (Optional)

The `docker` role installs Docker Engine and Docker Compose:

```bash
ansible-playbook -i inventory/hosts playbook-docker.yaml
```

Docker Compose is installed via pip since ARM releases are not available on the official release page.

### Useful Docker Links
- [Docker Install Guide](https://docs.docker.com/engine/install/debian/)
- [Docker Compose Install](https://docs.docker.com/compose/install/)

## Cloudflare DDNS (Optional)

Dynamic DNS allows updating Cloudflare DNS records when your IP changes:

```bash
# Generate configuration with environment variables
CF_API_TOKEN="XXX" CF_ZONE_ID_1="YYY" CF_ZONE_ID_2="ZZZ" envsubst < k3s/ddns/config.json > config.json

# Create the secret
kubectl create secret generic config-cloudflare-ddns --from-file=config.json -n ddns

# Apply the deployment
kubectl apply -f k3s/ddns/cloudflare-deployment.yaml
```

## Troubleshooting

### Cgroups not enabled

If K3s fails to start, ensure cgroups are enabled:

```bash
# Check current cmdline
cat /boot/firmware/cmdline.txt

# Should contain: cgroup_memory=1 cgroup_enable=memory
# If not, add them and reboot
```

### Node not joining cluster

Check the K3s agent logs:

```bash
sudo journalctl -u k3s-agent -f
```

Verify the master is reachable:

```bash
curl -k https://MASTER_IP:6443
```

### Certificate issues

Check Cert-Manager logs:

```bash
kubectl logs -n cert-manager deployment/cert-manager -f
```

Check certificate status:

```bash
kubectl get certificates -A
kubectl describe certificate wildcard-tls -n gateway-infra
```

### vxlan support

On newer Raspberry Pi OS, vxlan support has been moved to a separate kernel module:

```bash
sudo apt update --allow-releaseinfo-change
sudo apt upgrade -y
sudo apt install linux-modules-extra-raspi
```

### Wireguard

If using wireguard-native as the Flannel backend:

```bash
sudo apt install -y wireguard
```

### restorecon error

If you see `restorecon: command not found`:

```bash
sudo apt-get install policycoreutils
```

## Useful Links

- [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/)
- [K3s Documentation](https://docs.k3s.io/)
- [K3s Raspberry Pi Requirements](https://docs.k3s.io/advanced#raspberry-pi)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [Cert-Manager](https://cert-manager.io/)
- [ArgoCD](https://argo-cd.readthedocs.io/)

## License

MIT
