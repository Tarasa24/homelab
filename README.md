1. Add ssh pubkey to pve's authorized_keys file
2. Run `ansible-playbook playbooks/pve/pve_init.yml` to initialize the pve host to basic known state
3. Run `terraform apply`