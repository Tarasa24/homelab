#!/bin/bash
set -e

# Apply terraform
cd terraform && terraform init
terraform apply -auto-approve && terraform apply -auto-approve

# Apply ansible initial playbooks
cd ../ansible

# Init essential services
ansible-playbook playbooks/lxc/backup-init.yml
ansible-playbook playbooks/lxc/dmz-router-init.yml

# Run the rest of the playbooks in parallel
ansible-playbook playbooks/lxc/dmz-docker-host-init.yml
ansible-playbook playbooks/lxc/private-docker-host-init.yml

# Retrun to the root directory
cd ../
