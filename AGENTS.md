# Homelab — Agent Reference

This document describes the structure, design decisions, and operational patterns of this homelab repository. It is intended as a starting point for agent sessions working on this codebase.

---

## Overview

A single-node homelab running on **Proxmox VE (PVE)**. Infrastructure is managed with a two-layer IaC approach:

1. **Terraform** — provisions LXC containers and VMs on Proxmox, manages firewall rules, and downloads OS templates.
2. **Ansible** — configures the provisioned containers after Terraform creates them.

For most resources Terraform creates the container/VM and Ansible is invoked via `local-exec` provisioner or separately via `scripts/create.sh`. The `devenv.nix` file provides a reproducible dev shell (via [devenv](https://devenv.sh)) with Terraform, Ansible, `git-crypt`, and supporting tools.

---

## Repository Layout

```
homelab/
├── terraform/           # Proxmox resource definitions (LXC containers, VMs, firewalls)
├── ansible/
│   ├── ansible.cfg      # Ansible configuration (inventory path, roles path, custom plugins)
│   ├── inventory.ini    # Static inventory of all hosts grouped by role/network
│   ├── playbooks/       # Per-host init playbooks (organised by target type)
│   │   ├── pve/         # Proxmox host bootstrap
│   │   ├── lxc/         # LXC container init playbooks
│   │   ├── linode/      # Linode bastion host playbook
│   │   └── all/         # Cross-host playbooks (e.g. trigger borg backup on all hosts)
│   ├── roles/
│   │   ├── docker/      # Install Docker + docker-compose on Alpine
│   │   ├── borgmatic/   # Install borgmatic, copy SSH key, restore from backup, set up cron
│   │   └── lxc_python3/ # Install Python 3 inside an LXC (needed for Ansible modules)
│   └── plugins/
│       └── connection/pct_ssh.py  # Custom Ansible connection plugin: SSH → PVE host → pct exec into LXC
├── configs/             # Application/service configuration files deployed by Ansible
│   ├── dmz_router/      # nginx, dnsmasq, WireGuard configs for the DMZ router LXC
│   ├── dmz_docker-host/ # Docker Compose stacks for public-facing DMZ services
│   ├── private-docker-host/ # Docker Compose stacks for internal LAN services
│   ├── monitoring/      # Prometheus/Thanos/Loki/Grafana stack
│   ├── backup/          # borgmatic and resticprofile backup job configs
│   └── linode/          # WireGuard server config + nftables for the Linode bastion
├── secrets/             # git-crypt encrypted secrets (keys, credentials, API tokens)
│   ├── wireguard/       # WireGuard private/public keys and preshared key
│   ├── backup/          # Restic password, SSH keypair for borg, S3 credentials
│   ├── linode/          # Linode API key (used by Certbot DNS-01 challenge)
│   └── private-docker-host/ # App-level secrets for internal services
├── docs/                # draw.io network diagrams (LAN and DMZ router views)
├── scripts/create.sh    # Full bring-up script: terraform apply then ansible init playbooks
├── devenv.nix           # Reproducible dev shell definition
└── .gitattributes       # git-crypt filter applied to secrets/**
```

---

## Network Architecture

Three distinct IP networks are used:

| Network | CIDR | Purpose |
|---|---|---|
| **Homelab LAN** | `10.0.0.0/22` | Physical PVE host + internal LXC/VM services |
| **DMZ** | `10.1.0.0/24` | Internet-facing services isolated behind the DMZ router |
| **DMZ-Bastion tunnel** | `10.2.0.0/30` | WireGuard point-to-point between DMZ router and Linode VPS |
| **Tailscale** | `100.64.0.0/10` | Remote access mesh overlay |

### Physical host
- PVE node at `10.0.0.2` on the LAN, gateway `10.0.0.1` (home router).

### LAN subnet (`10.0.1.x`)
Static allocations:

| IP | VM/LXC ID | Role |
|---|---|---|
| `10.0.1.1` | 1001 | DNS (T-DNS / Pi-hole) |
| `10.0.1.2` | 1002 | DMZ Router |
| `10.0.1.3` | 1003 | Backup server |
| `10.0.1.4` | 1004 | Monitoring (Prometheus/Grafana/Loki) |
| `10.0.1.5` | 1005 | Home Assistant VM |
| `10.0.1.20` | 1020 | Private docker-host (internal services) |
| `10.0.1.21–30` | — | Virtual NICs on the private docker-host (one per service) |
| `10.0.1.100` | 1100 | Homelab Tailscale connector |

### DMZ subnet (`10.1.0.x`)
| IP | VM/LXC ID | Role |
|---|---|---|
| `10.1.0.1` | — | DMZ Router (LAN-side interface) |
| `10.1.0.3` | 10003 | Bitcoin node |
| `10.1.0.20` | 100020 | DMZ docker-host (public-facing services) |
| `10.1.0.100` | 1000100 | DMZ Tailscale connector |

### Linode (cloud)
- `45.79.249.185` — Debian VPS acting as WireGuard server / public-IP bastion for the DMZ.

---

## Proxmox LXC/VM Inventory

All containers use Alpine Linux unless noted. Templates are downloaded by Terraform before use.

| Resource | TF file | OS | Notes |
|---|---|---|---|
| `lxc_dns` | `lxc_dns.tf` | Alpine | DNS server; provisioned via `local-exec` in Terraform |
| `lxc_dmz_router` | `lxc_dmz_router.tf` | Alpine | Two NICs (LAN + DMZ bridge `vmbr1`); WireGuard + nginx + dnsmasq + Certbot |
| `lxc_backup` | `lxc_backup.tf` | Alpine | Borg server + resticprofile; USB-SSD backup mount |
| `lxc_monitoring` | `lxc_monitoring.tf` | Alpine | Docker; Prometheus/Thanos/Loki/Grafana; cold storage on USB-SSD |
| `vm_homeassistant` | `vm_homeassistant.tf` | HAOS (qcow2) | Full VM; 4 GB RAM; OVMF/UEFI; q35 machine type |
| `lxc_private-docker-host` | `lxc_private-docker-host.tf` | Alpine | Docker; internal services; SSL certs + media shares mounted |
| `lxc_homelab_tailscale_connector` | `lxc_homelab_tailscale_connector.tf` | Alpine | Cloned from Tailscale connector template |
| `lxc_dmz_bitcoin_node` | `lxc_dmz_bitcoin_node.tf` | Debian | Privileged; USB Bitcoin disk mounts; DMZ network only |
| `lxc_dmz-docker-host` | `lxc_dmz_docker-host.tf` | Alpine | Docker; DMZ network; GPU passthrough (`/dev/dri/renderD128`) |
| `lxc_nixos_template` | `lxc_nixos_template.tf` | NixOS | Template container; converted to template after init |
| `lxc_tailscale_connector_template` | `lxc_tailscale_connector_template.tf` | Alpine | Template with `/dev/net/tun` passthrough; cloned for each connector |

---

## Storage Layout (USB drives on PVE host)

| Mount | UUID | Filesystem | Used for |
|---|---|---|---|
| `/mnt/USB-HDD` | `d10e88e6-...` | ext4 | Jellyfin media, Immich photos, LXC templates/images |
| `/mnt/USB-SSD` | `c06ebfa7-...` | ext4 | SSL certs, backups, downloads, cache, monitoring cold storage |
| `/mnt/USB-BITCOIN` | `fcadd3af-...` | xfs | Bitcoin blockchain data |
| `/mnt/USB-BITCOIN-APPS` | `9fa5a1fb-...` | xfs | Bitcoin application data |

PVE storage pools `USB-HDD` and `USB-SSD` are registered as Proxmox `dir` storage (images/rootdir/vztmpl/snippets).

---

## Secrets Management

Secrets live under `secrets/` and are encrypted with **git-crypt** (key file `crypt.key`, excluded from git via `.gitignore`). The `.gitattributes` file applies the `git-crypt` filter to all files under `secrets/**`.

Secrets are consumed by Ansible playbooks via `lookup('file', '../../../secrets/...')` — they are never inlined into config files in plain text. Categories:

- `secrets/wireguard/` — WireGuard server/client private keys, public keys, preshared key
- `secrets/backup/ssh/` — SSH keypair used by borgmatic clients to authenticate to the borg server
- `secrets/backup/resticprofile/` — Restic repository password, S3 access/secret keys for Linode Object Storage
- `secrets/linode/` — Linode API credentials for Certbot DNS-01 ACME challenge
- `secrets/private-docker-host/` — Application-level secrets for internal services
- `secrets/terraform.tfvars` — Proxmox API credentials (`proxmox_config` map)
- `secrets/dmz_router/` — DMZ router specific secrets

---

## DMZ Router (`10.0.1.2` / `10.1.0.1`)

The DMZ router LXC is the most complex container — it acts as:

1. **WireGuard client** — tunnels to Linode bastion (`10.2.0.1`) over UDP port 51820. All DMZ traffic is NATed through this tunnel (MASQUERADE on `wg0` and `eth0`). Config: `configs/dmz_router/wg0.conf.j2`.
2. **DHCP + DNS server** for the DMZ — `dnsmasq` bound to the `dmz` interface, serving `10.1.0.100–254`. Config: `configs/dmz_router/dnsmasq.conf`.
3. **Reverse proxy + TLS termination** — nginx with stream module; wildcard certs for `*.homelab.tarasa24.dev`, `*.dormlab.tarasa24.dev`, `*.lan.tarasa24.dev` obtained via Certbot DNS-01 against Linode API. SSL certs are stored on the shared `/mnt/USB-SSD/ssl` mount (accessible to `private-docker-host` and `dmz-docker-host` as read-only).
4. **Static route** — routes Tailscale CGNAT range (`100.64.0.0/10`) via the DMZ Tailscale connector at `10.1.0.100`.

Firewall is managed by Proxmox (via Terraform): the DMZ router has a strict `DROP` in/out policy with explicit `ACCEPT` rules only for WireGuard outbound, backup SSH, Authelia, Unifi, and LAN traffic inbound.

---

## Linode Bastion (`45.79.249.185`)

A Debian VPS that acts as the public endpoint for the WireGuard server. It:
- Runs `wg-quick@wg0` (systemd) as the WireGuard server on `10.2.0.1`.
- Uses `nftables` for packet forwarding/masquerading from the DMZ WireGuard client.
- Root login is `prohibit-password` (key-only SSH).

Config templates: `configs/linode/wg0.conf.j2`, `configs/linode/nftables.conf.j2`.

---

## Private Docker-Host (`10.0.1.20`)

Internal (LAN-only) services deployed as Docker Compose stacks. Ansible copies all contents of `configs/private-docker-host/` to `/root/` on the container, discovers all `docker-compose.yaml` files recursively, builds a `COMPOSE_FILE=...` `.env`, then does `docker-compose pull` + `docker-compose up -d`.

Virtual NICs `eth0:0` through `eth0:9` (`10.0.1.21–30`) are assigned at boot via `/etc/local.d/assign-ips.start` so each service can bind a dedicated IP.

### Services

| Compose file | IP | Services |
|---|---|---|
| `traefik/` | `10.0.1.20` | Traefik v3 reverse proxy (HTTP/HTTPS :80/:443, dashboard :8080) |
| `authelia/` | `10.0.1.21` | Authelia SSO/2FA |
| `vaultwarden/` | `10.0.1.22` | Vaultwarden (Bitwarden-compatible password manager) |
| `arr_stack/` | `10.0.1.23` | WireGuard + qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, FlareSolverr |
| `firefly_iii/` | `10.0.1.24` | Firefly III personal finance |
| `unifi-controller/` | `10.0.1.25` | Unifi network controller |
| (root compose) | `10.0.1.20` | Promtail (log shipper) |
| `ghostfolio/` | `10.0.1.26` | Ghostfolio portfolio tracker (Postgres + Redis) |
| (root compose) | `10.0.1.20` | Prometheus (scraping agent) + Promtail (log shipper) |

The `arr_stack` services run inside a WireGuard network namespace (all share the `wireguard` container's network via `network_mode: service:wireguard`).

Traefik reads TLS certificates from the shared Certbot mount (`/etc/letsencrypt/live/*.lan.tarasa24.dev`).

---

## DMZ Docker-Host (`10.1.0.20`)

Internet-accessible services, isolated in the DMZ. Has GPU passthrough (`/dev/dri/renderD128`) for hardware transcoding.

| Service | Notes |
|---|---|
| Jellyfin | Media server; `/media` from USB-HDD |
| Immich | Photo management; `/immich` from USB-HDD |
| Radicale | CalDAV/CardDAV server |
| Prometheus + Promtail | Local metrics/log scraping agents |

---

## Monitoring Stack (`10.0.1.4`)

Long-term metrics and log storage on a dedicated container.

| Service | Notes |
|---|---|
| Prometheus | Short-retention TSDB; 30 min block duration (feeds Thanos) |
| Thanos sidecar | Ships Prometheus blocks to MinIO (object store) |
| Thanos store | Reads historical data from MinIO |
| Thanos querier | Unified query layer across sidecar + store |
| Thanos compactor | Compacts/downsamples blocks in object store |
| Loki | Log aggregation; stores chunks in MinIO |
| MinIO | Local S3-compatible object store on cold USB-SSD mount |
| Grafana | Dashboards; provisions datasources from `grafana/provisioning/` |

---

## Backup Strategy

Two complementary backup tools run on all relevant containers:

### Borg (local + SSH)
- **Server**: `lxc_backup` at `10.0.1.3`. Repositories stored at `/backup/repos/` (USB-SSD). Access is key-restricted via `authorized_keys` with `borg serve --restrict-to-path`.
- **Clients**: Each service container has the `borgmatic` Ansible role applied. The role installs borgmatic, copies the SSH private key from `secrets/backup/ssh/id_ed25519`, copies the host-specific borgmatic config from `configs/backup/borg/<hostname>.yaml`, runs `borgmatic extract` to restore on first deploy, then schedules nightly backups via cron at 02:00.
- **Trigger all**: `ansible-playbook playbooks/all/borg-backup-all.yml`

### Restic (remote S3)
- **Client**: `lxc_backup` also runs resticprofile to back up to Linode Object Storage (S3-compatible).
- Profiles: `global`, `borg-to-linode-s3`, `immich-media-to-linode-s3`.
- S3 credentials (`access_key`, `secret_key`) and the restic password come from `secrets/backup/resticprofile/`.

---

## Tailscale Connectivity

Two Tailscale connectors provide remote-access mesh:

- **Homelab connector** (`10.0.1.100`, LXC 1100) — advertises LAN subnet routes into Tailscale.
- **DMZ connector** (`10.1.0.100`, LXC 1000100) — advertises DMZ subnet routes.

Both are cloned from `lxc_tailscale_connector_template` (LXC 3003), which has `/dev/net/tun` passed through. The template is prepared by `ansible-playbook playbooks/lxc/tailscale-connector-template-init.yml`.

---

## Custom Ansible Connection Plugin (`pct_ssh`)

Located at `ansible/plugins/connection/pct_ssh.py`. Allows Ansible to manage LXC containers on Proxmox without requiring direct SSH into each container. Flow:

```
Ansible controller → SSH to PVE host → pct exec <lxc_id> -- <command>
```

Inventory hosts use `ansible_connection=pct_ssh` and `lxc_host=<VMID>`. The plugin supports cgroupv2 (wraps commands in `systemd-run`), handles ControlPersist, and retries on connection failure.

---

## Bootstrap Sequence

### Initial PVE setup (once)
1. Add SSH public key to PVE host's `authorized_keys`.
2. `cd ansible && ansible-playbook playbooks/pve/pve_init.yml` — mounts USB disks, registers PVE storage pools, creates the DMZ bridge `vmbr1`.

### Full bring-up (`scripts/create.sh`)
```bash
cd terraform && terraform init
terraform apply -auto-approve   # run twice — some resources depend on outputs of the first pass
cd ../ansible
ansible-playbook playbooks/lxc/backup-init.yml       # backup server must be up first
ansible-playbook playbooks/lxc/dmz-router-init.yml   # DMZ router (WireGuard + nginx + certs)
ansible-playbook playbooks/lxc/dmz-docker-host-init.yml
ansible-playbook playbooks/lxc/private-docker-host-init.yml
```

Some containers (`lxc_dns`, `lxc_nixos_template`, `lxc_tailscale_connector_template`, `lxc_dmz_bitcoin_node`) trigger their Ansible playbook automatically via Terraform `local-exec` provisioners.

---

## Key Conventions

- **Alpine Linux** is the default OS for all LXC containers. The `lxc_python3` role installs Python 3 as a pre-task before any Ansible module that requires it.
- **LXC containers are unprivileged** unless there is a specific reason (bitcoin node requires privileged for its filesystem mounts).
- **Firewall policy**: Proxmox cluster-level firewall defaults to `input=DROP, output=ACCEPT`. Per-container rules layer on top. The DMZ router has `output=DROP` with explicit allow-list rules.
- **Secrets are never in configs**: all sensitive values are read at Ansible runtime via `lookup('file', '...')` from the encrypted `secrets/` tree.
- **SSL certificates are centralised**: Certbot runs only on the DMZ router. Certs are stored on the shared USB-SSD mount and bind-mounted read-only into containers that need them.
- **Borgmatic restore-on-deploy**: the borgmatic role always attempts `borgmatic extract --archive latest` before starting services — this is how service state (Docker volumes, configs) is restored after reprovisioning.
- **Terraform `terraform.tfvars`**: sensitive Proxmox endpoint/credentials live in `secrets/terraform.tfvars` (git-crypt encrypted). The Proxmox provider SSH key is read from `~/.ssh/homelab_proxmox`.
- **Domain naming**: `*.lan.tarasa24.dev` for internal LAN services (via Traefik), `*.homelab.tarasa24.dev` and `*.dormlab.tarasa24.dev` for DMZ/externally reachable services (via nginx on the DMZ router).

---

## Agent Workflow Guidelines

When working on new features or changes in this repository, agents should follow this workflow:

### Branch Strategy
- **Each new feature/session**: Create a dedicated feature branch following the pattern `feature/<descriptive-name>`
- **Branch naming**: Use lowercase with hyphens (e.g., `feature/add-prometheus-alerts`, `feature/update-nginx-config`)
- **Base branch**: Always branch from `main` unless otherwise specified

### Git Operations
- **Manual approval required**: Agents can propose commits but must wait for explicit user approval before creating them
- **Commit messages**: Follow conventional commit format when creating commits: `type(scope): description`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Scope: Component being changed (e.g., `terraform`, `ansible`, `docker`, `monitoring`)
  - Example: `feat(monitoring): add Prometheus alerts for disk usage`
- **Atomic commits**: Each commit should represent a single logical change

### Pull Request Process
1. **Feature completion**: When all changes for a feature are complete and tested
2. **Create PR**: Create a GitHub pull request from the feature branch to `main`
3. **PR description**: Include clear description of changes, testing performed, and any breaking changes
4. **Manual review**: The PR will undergo manual code review by the repository owner before merging
5. **No auto-merge**: Do not automatically merge PRs - wait for explicit approval

### Testing Requirements
- **Local validation**: Run relevant tests/checks before proposing changes
- **Terraform**: Run `terraform fmt`, `terraform validate`
- **Ansible**: Run `ansible-lint` on playbooks when available
- **Service verification**: Test that services start correctly with the changes

### Communication Protocol
- **Progress updates**: Provide clear updates on what has been implemented
- **Decision points**: Ask for clarification on implementation details when needed
- **Risk assessment**: Highlight any potential risks or breaking changes in proposed changes
