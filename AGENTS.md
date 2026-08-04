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
│   │   ├── docker/        # Install Docker + docker-compose on Alpine; enables metrics on :9323
│   │   ├── borgmatic/     # Install borgmatic, copy SSH key, restore from backup, set up cron
│   │   ├── lxc_python3/   # Install Python 3 inside an LXC (needed for Ansible modules)
│   │   ├── node_exporter/ # Install prometheus-node-exporter (OpenRC on Alpine, systemd on Debian)
│   │   └── promtail/      # Install loki-promtail, deploy host-specific config from configs/promtail/
│   └── plugins/
│       └── connection/pct_ssh.py  # Custom Ansible connection plugin: SSH → PVE host → pct exec into LXC
├── configs/             # Application/service configuration files deployed by Ansible
│   ├── dmz_router/      # nginx, dnsmasq, WireGuard configs for the DMZ router LXC
│   ├── dmz_docker-host/ # Docker Compose stacks for public-facing DMZ services
│   ├── dmz_bitcoin-node/ # bitcoind + electrs service files and bitcoin.conf
│   ├── private-docker-host/ # Docker Compose stacks for internal LAN services
│   ├── monitoring/      # Prometheus/Loki/Grafana/Alertmanager/Gatus stack
│   ├── backup/          # borgmatic and resticprofile backup job configs
│   ├── promtail/        # Host-specific Promtail configs (backup, dns, dmz-router)
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
| `10.0.1.1` | 1001 | DNS (Technitium DNS) |
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
| `10.1.0.1` | — | DMZ Router (DMZ-side interface) |
| `10.1.0.2` | 10002 | DMZ mail (reserved/unused) |
| `10.1.0.3` | 10003 | Bitcoin node |
| `10.1.0.20` | 100020 | DMZ docker-host (public-facing services) |
| `10.1.0.100` | 1000100 | DMZ Tailscale connector |

### Monitoring VLAN 50 (`10.0.50.x`)
Out-of-band monitoring network — all nodes with the `mon` NIC get a VLAN 50 interface for Prometheus scraping. No DHCP; all static.

| IP | Host |
|---|---|
| `10.0.50.1` | dns |
| `10.0.50.2` | dmz-router |
| `10.0.50.3` | backup |
| `10.0.50.4` | monitoring |
| `10.0.50.20` | private-docker-host |
| `10.0.50.103` | dmz-bitcoin-node |
| `10.0.50.120` | dmz-docker-host |

The Proxmox host itself is the exception: it owns `vmbr0` and has no address on
VLAN 50, so it is scraped on the LAN at `10.0.0.2:9100`. That needs an explicit
allow in `terraform/firewall_base.tf` because the datacenter input policy is
DROP. It carries `host="pve"`, so every existing node rule (NodeDown, CPU,
memory, disk) covers the hypervisor without further change.

**Known drift:** `/etc/network/interfaces` on the PVE host declares
`gateway 10.0.0.1`, but the running kernel had no default route, so the host
could reach the LAN yet had no internet — `apt` could not fetch anything and
`resolv.conf` pointed at an unreachable `1.1.1.1`. The route was restored at
runtime; since the gateway is already declared, a reboot re-applies it. Worth
checking after any network change on the host.

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
| `lxc_monitoring` | `lxc_monitoring.tf` | Alpine | Docker; Prometheus/Loki/Grafana/Alertmanager/Gatus; state in named Docker volumes |
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
| `/mnt/USB-SSD` | `c06ebfa7-...` | ext4 | SSL certs, backups, downloads, cache |
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
| `cadvisor/` | `10.0.50.20` | cAdvisor per-container metrics on `:8081` (VLAN 50) |

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
| ntfy | Push notification server (`10.1.0.24`); exposed at `ntfy.homelab.tarasa24.dev` |
| Promtail | Log shipper to Loki |
| cAdvisor | Per-container metrics on `10.0.50.120:8081` (VLAN 50) |

---

## Monitoring Stack (`10.0.1.4`)

Metrics and log storage on a dedicated container. All state in named Docker volumes, backed up via borgmatic.

| Service | Notes |
|---|---|
| Prometheus | Metrics TSDB; 14d retention, 5GB cap; scrapes node exporters on VLAN 50 |
| Loki | Log aggregation; 7d retention; receives logs from all Promtail agents |
| Alertmanager | Routes alerts from Prometheus and Loki ruler to ntfy |
| Grafana | Dashboards; configured manually (no provisioning); datasources added via UI |
| Gatus | Availability probing + public status page; fully config-as-code |

Grafana datasources (add manually after first deploy):
- **Prometheus** — `http://prometheus:9090` (set as default)
- **Loki** — `http://loki:3100`

### Availability Monitoring (Gatus + cAdvisor)

Service availability is covered by two complementary signals. Neither alone is
sufficient, and they are designed to be read together.

**Gatus** (`configs/monitoring/gatus/config.yaml`) — HTTP probing and the public
status page at `status.homelab.tarasa24.dev`. Replaces both the removed
blackbox-exporter and Uptime Kuma, and unlike Uptime Kuma it is entirely
config-as-code. Endpoints are split into three groups:

| Group | Path probed | Purpose |
|---|---|---|
| `Public` | public DNS → Linode → WireGuard → nginx → service | True end-user experience. Includes the home WAN uplink, so a failure does not isolate the fault. |
| `Internal` | direct to `10.0.1.x` over the LAN | Bypasses the WAN entirely. If Public fails but Internal passes, the fault is in the WAN/Linode/WireGuard/nginx path, not the service. |
| `Infrastructure` | compose service names on the monitoring network | The monitoring stack checking itself. |

Gatus does **not** alert directly. It sets `metrics: true`, Prometheus scrapes it
as job `gatus`, and Alertmanager owns routing to ntfy — one alert pipeline with
one set of grouping, inhibition and resolved-notification semantics.

**cAdvisor** (`configs/{dmz_docker-host,private-docker-host}/cadvisor/`) —
per-container metrics on both Docker hosts, published on the VLAN 50 IP
(`10.0.50.20:8081`, `10.0.50.120:8081`) and scraped as job `cadvisor`. This is
the only source of per-container up/down state: the Docker daemon metrics on
`:9323` are engine-level aggregates and stay green when an individual container
dies. cAdvisor is required because the monitoring LXC has no route into the DMZ
(`10.1.0.0/24`), so DMZ services cannot be probed directly over the LAN.

Runs `privileged: true` with read-only mounts inside an unprivileged LXC; some
cgroup metrics may be unavailable in that environment. `CAdvisorDown` fires if it
stops reporting, because container-level alerting is blind while it is down.

**Metric names caveat**: the Gatus documentation describes `gatus_check_result_total`
and `gatus_uptime`. Neither exists in the shipped binary. The real metrics are
`gatus_results_endpoint_success` (1/0 gauge), `gatus_results_total`,
`gatus_results_certificate_expiration_seconds` and `gatus_results_duration_seconds`.
Verify against the live `/metrics` output after any Gatus upgrade — a renamed
metric silently disables `ExternalServiceDown`.

**Alert delivery path**: Alertmanager reaches ntfy over its *public* URL
(`https://ntfy.homelab.tarasa24.dev/<topic>`), not the DMZ address
`10.1.0.24:8080`. The monitoring LXC is on the LAN with its default gateway at
the home router and has no route into `10.1.0.0/24`, so the internal address
times out on every notification — and because a TCP connect timeout takes about
two minutes, `alertmanager_notifications_failed_total` reads zero for a while
before the failure lands. Do not trust that counter immediately after sending;
confirm against the ntfy topic itself or the Alertmanager log. Delivery therefore
depends on the home uplink, which is acceptable since push to a phone needs
internet anyway; routing the LAN into the DMZ instead would weaken the isolation
the DMZ exists to provide.

**Nightly backup maintenance window**: borgmatic runs from cron at 02:00 UTC on
every host and its `before_backup` hooks stop containers so their volumes can be
copied cold. Those services genuinely go down, and the monitoring is correct to
notice — on 2026-08-03 Docker restarted them at 02:02–02:03 UTC but probes did
not recover until roughly 02:12, because this hardware is slow to bring apps back
to a responsive state.

Alertmanager therefore defines a `nightly-backup` time interval (01:55–03:00 UTC)
and two routes ahead of the normal ones that mute exactly the expected noise:
`ExternalServiceDown`, `ContainerDown`, `ContainerCrashLoop` and
`ContainerErrors`. Everything else stays live during the window, so a real
incident during a backup is still paged. Those two routes deliver to the same
receivers the alerts would otherwise reach, so behaviour outside the window is
unchanged — verified with `amtool config routes test`.

Muting delays rather than discards: an alert still firing when the window closes
notifies then, so a service that fails to come back is still reported. The window
is defined in UTC on purpose — the containers and their crontabs run UTC, so a
UTC window does not drift when local time changes for DST.

The deeper fix is to stop taking services down at all: borgmatic supports
database dump hooks (`postgresql_databases`, `mariadb_databases`) which snapshot
data live and would let most `before_backup`/`after_backup` stop/start pairs be
removed. Until then the mute window is the pragmatic mitigation.

### Known monitoring gaps (accepted)

These are deliberate trade-offs, not oversights. Recorded so a future change does
not assume coverage that does not exist.

**ntfy is a single point of failure in the alert path.** Two distinct failure
modes follow from it:

1. *ntfy itself is down.* Gatus detects it, but the alert saying so is delivered
   through ntfy, so it never arrives.
2. *Anything upstream is down* — Prometheus, Alertmanager, Loki, the monitoring
   LXC, the WAN, or the Proxmox host — and **nothing fires at all**. Silence is
   indistinguishable from everything being healthy. This is the more dangerous
   mode, and this repo has been bitten by it: alerts were undeliverable for
   months while every counter reported success.

Accepted for a homelab. The conventional fixes, if this ever matters:

- **Dead man's switch** for mode 2 — an always-firing `Watchdog` alert
  (`expr: vector(1)`) routed to an external service (healthchecks.io, Better
  Stack) that notifies when it *stops* hearing from you. It has to live outside
  this infrastructure to be meaningful.
- **Second receiver** for mode 1 — Alertmanager delivers to every receiver in a
  matched route, so adding `email_configs` alongside the ntfy webhook gives
  genuinely parallel delivery. A second ntfy instance in the DMZ would not help:
  same host, same failure domain.

**Not covered by any probe**: the Tailscale connectors (1100, 1000100), and the
Linode bastion, which is only covered indirectly because the Gatus `Public` group
traverses it.

**Non-Docker hosts use the systemd collector.** cAdvisor only covers the two
Docker hosts. The Bitcoin node runs `bitcoind` and `electrs` as plain systemd
units on Debian, so service-level down-detection comes from
`node_systemd_unit_state` via `--collector.systemd`, driven by the
`node_exporter_systemd_units` allowlist in the role defaults. That allowlist is
not optional: Debian's build enables the systemd collector by default and emits a
series per unit per state, and a `SystemdUnitDown` rule without a `name` selector
matches every oneshot unit that is legitimately inactive (`apt-daily.service`,
`e2scrub_all.service`, …) — 134 pending alerts, in practice. Both the collector
flag and the alert rule are scoped.

The allowlist regex uses `[.]` rather than `\.` because systemd processes escape
sequences in `ExecStart`. The role also notifies a restart handler when the
override changes; `state: started` alone is a no-op on a running service, so a
changed override would otherwise sit on disk unapplied until the next reboot.

`electrs` binds its DMZ address only and is unreachable over the monitoring VLAN,
so the systemd collector is the only way to see it at all. `bitcoind`'s P2P port
does listen on all addresses and is additionally probed by Gatus over VLAN 50,
and the public Electrum endpoint (`:50002`, TLS-terminated by the nginx stream)
is probed as a `Public` endpoint.

**Container-level coverage depends on explicit `container_name`.** The
`ContainerDown` rules are generated per container name; a service defined without
one gets a Docker-generated name like `root-promtail-1` and is deliberately
skipped, so it has no down-detection.

**The `host` label contract**: every node, docker and cadvisor scrape target
carries a static `host` label, and every Gatus endpoint sets one via
`extra-labels`. Alertmanager's inhibit rule matches on `host` to suppress service
alerts when the machine hosting them is already down. Do not add a `host` label to
the `gatus` scrape job — it would collide with the per-endpoint value and
Prometheus would rename the latter to `exported_host`, breaking the inhibit rules.

### Log Collection (Loki / Promtail)

Logs are collected from all Docker hosts via a Promtail agent running as a container on each host. Each agent ships to Loki at `http://10.0.50.4:3100` (monitoring VLAN).

**Hosts shipping logs:**

| Host | LXC ID | Promtail config |
|---|---|---|
| `monitoring` | 1004 | `configs/monitoring/promtail/promtail-config.yaml` |
| `private-docker-host` | 1020 | `configs/private-docker-host/root/promtail/config.yml` |
| `dmz-docker-host` | 100020 | `configs/dmz_docker-host/root/promtail/config.yml` |
| `dmz-router` | 1002 | `configs/promtail/dmz-router.yaml` |
| `backup` | 1003 | `configs/promtail/backup.yaml` |
| `dns` | 1001 | `configs/promtail/dns.yaml` |

The three Docker hosts run Promtail as a container with Docker service
discovery. `dmz-router`, `backup` and `dns` instead run it as a native Alpine
package via the `promtail` role, tailing static file paths — there is no Docker
daemon on those hosts.

Two things about that role are load-bearing. It sets `use: openrc` explicitly,
because these playbooks run with `gather_facts: false` and Ansible cannot then
detect the init system, so the `rc-update` that registers Promtail in the default
runlevel is skipped silently. That is precisely how `backup` and `dns` ended up
shipping nothing: Promtail had been started by hand, ran until the 2026-05-31
reboot, and never came back. It also resolves its config from `role_path` rather
than a playbook-relative path, so the role works from any playbook.

`ansible_hostname` must be set in the inventory for every host using the role
(the config file is chosen by host name). Without it the role's `src` templates
to an empty path and the task fails.

**Label schema** — every log line gets the following Loki labels:

| Label | Value | Example |
|---|---|---|
| `job` | `{instance}/{service_name}` | `dmz-docker-host/jellyfin` |
| `instance` | hostname of the Docker host | `private-docker-host` |
| `service_name` | Docker Compose service name | `authelia` |
| `container_name` | Docker container name | `/authelia` |
| `stream` | `stdout` or `stderr` | `stdout` |
| `severity` | `critical` for key services, absent otherwise | `critical` |

The `job` label combining `instance/service_name` gives a unique identifier per service per host, useful for filtering in Grafana. The `instance`, `service_name`, and `container_name` labels are required by the [Loki v3 logging dashboard](https://grafana.com/grafana/dashboards/24574).

**Discovery** — Promtail uses Docker service discovery (`docker_sd_configs`) via the Docker socket (`/var/run/docker.sock`). Service name is extracted from the `com.docker.compose.service` container label set automatically by Docker Compose.

**Retention** — Loki is configured for 7-day retention. Older logs are compacted and deleted by the Loki compactor.

**Alerting from logs** — Loki ruler evaluates alert rules in
`configs/monitoring/loki/rules/fake/loki-alerts.yml` and fires to Alertmanager on
pattern matches (errors, OOM kills, auth failures, backup failures, TLS expiry).

The `fake` subdirectory is required, not a placeholder: `auth_enabled: false`
means Loki uses the single tenant `fake`, and the local ruler backend reads rules
from `<storage.local.directory>/<tenant>/`. `rule_path` (scratch space the ruler
writes during evaluation) and `storage.local.directory` (where rule files are
read from) are deliberately different paths, so the read-only rules bind mount
does not have to be nested inside the `loki-data` named volume.

Two failure modes to avoid when editing these rules:

- **Self-reference.** Loki's ruler logs the text of every query it evaluates, and
  Promtail ships Loki's own logs back into Loki, so a rule searching for
  `oom.?kill` matches the ruler log line containing that pattern and fires
  forever. Broad rules must exclude `monitoring/loki` and `monitoring/promtail`.
- **Substring matches.** A bare `error` pattern matches `errors=0`, which Gatus
  prints on every *successful* probe. Use `\b` word boundaries.

Most of these rules detect log *content* only. A down service emits no logs, so
`count_over_time()` returns an empty vector and can never fire — down-detection
for services belongs to Gatus and cAdvisor, not here.

The exception is `LogShippingStopped`, which uses `absent_over_time()` on the
per-host `instance` label to detect a host that has stopped shipping altogether.
Promtail dying is otherwise completely silent — an absence of logs is
indistinguishable from a quiet host — and that is how `backup` and `dns` shipped
nothing between the 2026-05-31 reboot and 2026-08-04. It deliberately does not
scrape Promtail's own `:9080`, which would need another firewall rule on the DMZ
router; the 2h window is sized off the quietest host (`backup`, ~21 syslog lines
per hour).

`NginxErrorRateHigh` uses the `status` and `server_name` stream labels directly,
so no parsing is needed. `TraefikErrorRateHigh` must parse JSON, and Traefik
mixes plain-text startup lines into the same stream, so it needs `| __error__=""`
to drop unparseable lines — without it the query errors on every evaluation. The
field is `DownstreamStatus` (what the client received), not `OriginStatus`.

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
- **State lives on the container disk, never on USB mounts**: Docker service state (databases, app data, config) always uses named Docker volumes, which default to `/var/lib/docker/volumes/` on the container's own disk. Borgmatic then backs these up to the borg server over SSH. USB-mounted cold storage (`/mnt/USB-SSD`, `/mnt/USB-HDD`) is reserved exclusively for bulk data that cannot reasonably be backed up (media libraries, blockchain data, SSL certs). Never use bind mounts to cold storage paths for service state.
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
