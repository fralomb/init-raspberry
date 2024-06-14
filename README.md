# Tools to install into a Raspberry
The following Ansible playbook is meant to install some of the tools and dependencies in a Raspberry system.

## Install Ansible
In the  case i need to execute an Ansible playbook directly on a Raspberry i'll need also to install Ansible itlsef.
To do that, the bash script `install-ansible` will do the job.

## Install Docker
The role `docker` will install all the Docker deamon and the Docker-Compose dependencies. 
The Docker-Compose tool is installed via pip, since in the `docker/compose` release page there's no release built for `arm`.

### Useful links
- Docker doc: [link](https://docs.docker.com/engine/install/debian/)
- Install Docker Engine: [link](https://docs.docker.com/engine/install/ubuntu/)
- Install Docker-Compose: [link](https://docs.docker.com/compose/install/)

## Install K3s
Doc: `https://docs.k3s.io`

Installation requirements for Raspberry Pi OS: `https://docs.k3s.io/advanced#raspberry-pi`

- Enable `cgroups` by appending `cgroup_memory=1 cgroup_enable=memory` to `/boot/cmdline.txt`.
- vxlan support on Raspberry Pi has been moved into a separate kernel module
    ```
    sudo apt update --allow-releaseinfo-change
    sudo upgrade -y
    sudo apt install linux-modules-extra-raspi
    ```
- Using wireguard-native as the Flannel backend required
    ```
    sudo apt install -y wireguard
    ```
- Error `restorecon: command not found` --> `sudo apt-get install policycoreutils`
### Access K3s cluster from outside
The kubeconfig file stored at `/etc/rancher/k3s/k3s.yaml` is used to configure access to the Kubernetes cluster.

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

