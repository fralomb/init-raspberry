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
