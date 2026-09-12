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
│   ├── dmz_proxy/       # nginx, Certbot configs for the DMZ reverse proxy LXC
│   ├── dmz_docker-host/ # Docker Compose stacks for public-facing DMZ services
│   ├── dmz_bitcoin-node/ # bitcoind + electrs service files and bitcoin.conf
│   ├── private-docker-host/ # Docker Compose stacks for internal LAN services
│   ├── monitoring/      # Prometheus/Loki/Grafana/Alertmanager/Gatus stack
│   ├── backup/          # borgmatic and resticprofile backup job configs
│   └── promtail/        # Host-specific Promtail configs (backup, dns, dmz-proxy)
├── secrets/             # git-crypt encrypted secrets (keys, credentials, API tokens)
│   ├── backup/          # Restic password, SSH keypair for borg
│   ├── hetzner/         # Hetzner Storage Box SSH key + Certbot DNS-01 API token
│   └── private-docker-host/ # App-level secrets for internal services
├── scripts/create.sh    # Full bring-up script: terraform apply then ansible init playbooks
├── devenv.nix           # Reproducible dev shell definition
└── .gitattributes       # git-crypt filter applied to secrets/**
```

---

## Network Architecture

Four tagged VLANs on a single VLAN-aware `vmbr0` (no more separate `vmbr1`):

| Network | CIDR | VLAN | Purpose |
|---|---|---|---|
| **Lab** | `10.0.30.0/24` | 30 | PVE host + internal LXC/VM services |
| **DMZ** | `10.0.40.0/24` | 40 | Internet-facing services |
| **Monitoring** | `10.0.50.0/24` | 50 | Out-of-band Prometheus scraping |

Gateway and DHCP for Lab and DMZ are both the UXG (`10.0.30.1` / `10.0.40.1`). No DHCP on DMZ — all DMZ hosts are static.

### Physical host
- PVE node at `10.0.30.2` on Lab (`vmbr0.30`), gateway `10.0.30.1` (UXG).
- Still dual-homed: the pre-migration flat-LAN address `10.0.0.2/22` (gateway `10.0.0.1`) is deliberately still present on `vmbr0` as a failsafe — full cutover (removing it, running `pve_init.yml`) hasn't happened yet.

### Lab subnet (`10.0.30.x`)
| IP | VMID | Role |
|---|---|---|
| `10.0.30.2` | — | PVE host |
| `10.0.30.11` | 3011 | DNS (Technitium DNS) |
| `10.0.30.13` | 3013 | Backup server |
| `10.0.30.14` | 3014 | Monitoring (Prometheus/Grafana/Loki) |
| `10.0.30.15` | 3015 | Home Assistant VM |
| `10.0.30.20` | 3020 | Private docker-host (internal services) |
| `10.0.30.21–30` | — | Virtual NICs on the private docker-host, see table below |

### DMZ subnet (`10.0.40.x`)
| IP | VMID | Role |
|---|---|---|
| `10.0.40.10` | 4010 | dmz-proxy (nginx + certbot; replaces the old dmz-router) |
| `10.0.40.13` | 4013 | Bitcoin node |
| `10.0.40.20` | 4020 | DMZ docker-host (public-facing services) |
| `10.0.40.21–30` | — | Virtual NICs on the DMZ docker-host, see table below |

Tailscale connectors and the DMZ-router's WireGuard/dnsmasq role are gone; the UXG now terminates ingress directly.

### Monitoring VLAN 50 (`10.0.50.x`)
Out-of-band monitoring network — all nodes with the `mon` NIC get a VLAN 50 interface for Prometheus scraping. No DHCP; all static.

| IP | Host |
|---|---|
| `10.0.50.1` | dns |
| `10.0.50.2` | dmz-proxy |
| `10.0.50.3` | backup |
| `10.0.50.4` | monitoring |
| `10.0.50.20` | private-docker-host |
| `10.0.50.103` | dmz-bitcoin-node |
| `10.0.50.120` | dmz-docker-host |

The Proxmox host itself is the exception: it owns `vmbr0` and has no address on
VLAN 50, so it is scraped on the Lab VLAN at `10.0.30.2:9100`. That needs an explicit
allow in `terraform/firewall_base.tf` because the datacenter input policy is
DROP. It carries `host="pve"`, so every existing node rule (NodeDown, CPU,
memory, disk) covers the hypervisor without further change. Home Assistant has
no `mon` NIC and isn't scraped over VLAN 50.

---

## Proxmox LXC/VM Inventory

All containers use Alpine Linux unless noted. Templates are downloaded by Terraform before use.

| Resource | VMID | TF file | OS | Notes |
|---|---|---|---|---|
| `lxc_dns` | 3011 | `lxc_dns.tf` | Alpine | DNS server; provisioned via `local-exec` in Terraform |
| `lxc_backup` | 3013 | `lxc_backup.tf` | Alpine | Borg server + resticprofile; USB-SSD backup mount |
| `lxc_monitoring` | 3014 | `lxc_monitoring.tf` | Alpine | Docker; Prometheus/Loki/Grafana/Alertmanager/Gatus; state in named Docker volumes |
| `vm_homeassistant` | 3015 | `vm_homeassistant.tf` | HAOS (qcow2) | Full VM; 4 GB RAM; OVMF/UEFI; q35 machine type |
| `lxc_private-docker-host` | 3020 | `lxc_private-docker-host.tf` | Alpine | Docker; internal services; SSL certs + media shares mounted |
| `lxc_dmz_proxy` | 4010 | `lxc_dmz_proxy.tf` | Alpine | Single DMZ NIC + mon NIC; nginx + Certbot only (replaces `lxc_dmz_router`; no WireGuard/dnsmasq) |
| `lxc_dmz_bitcoin_node` | 4013 | `lxc_dmz_bitcoin_node.tf` | Debian | Privileged; USB Bitcoin disk mounts; DMZ network only |
| `lxc_dmz-docker-host` | 4020 | `lxc_dmz_docker-host.tf` | Alpine | Docker; DMZ network; GPU passthrough (`/dev/dri/renderD128`) |

Removed as part of the network overhaul (VLAN restructure, dnsmasq no longer needed since the UXG is now DHCP/gateway for both VLANs): `lxc_dmz_router`, `lxc_homelab_tailscale_connector`, `lxc_dmz_tailscale_connector`, `lxc_tailscale_connector_template`, `lxc_nixos_template`.

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

- `secrets/backup/ssh/` — SSH keypair used by borgmatic clients to authenticate to the borg server
- `secrets/backup/resticprofile/` — Restic repository password (repository is a Hetzner Storage Box over SFTP, authenticated via `secrets/hetzner/`)
- `secrets/hetzner/` — Hetzner Storage Box SSH key + host key, and the Certbot DNS-01 API token
- `secrets/private-docker-host/` — Application-level secrets for internal services
- `secrets/terraform.tfvars` — Proxmox API credentials (`proxmox_config` map)
- `secrets/dmz_router/` — DMZ router specific secrets

---

## DMZ Proxy (`10.0.40.10`, was DMZ Router)

Replaces the old `dmz-router`. The UXG now terminates ingress and is the DMZ's
gateway/DHCP server directly, so this container no longer routes, NATs, or
runs WireGuard/dnsmasq — it's just:

1. **Reverse proxy + TLS termination** — nginx with stream module; wildcard certs for `*.homelab.tarasa24.dev`, `*.dormlab.tarasa24.dev`, `*.lan.tarasa24.dev` obtained via Certbot DNS-01 against the Hetzner DNS API. SSL certs are stored on the shared `/mnt/USB-SSD/ssl` mount (accessible to `private-docker-host` and `dmz-docker-host` as read-only).

Firewall is managed by Proxmox (via Terraform): strict `DROP` in/out policy.
Outbound needs an explicit `ACCEPT` rule per backend it proxies to — every
nginx `proxy_pass`/stream target (jellyfin, ntfy, radicale, electrs, bitcoind,
Gatus, Loki, Unifi, Authelia, backup) needs its own rule in
`terraform/lxc_dmz_proxy.tf`; same-VLAN destinations are not exempt from this
container's own firewall, only unscoped WAN rules (80/443/53, no `dest`) are.

---

## Private Docker-Host (`10.0.30.20`)

Internal (LAN-only) services deployed as Docker Compose stacks. Ansible copies all contents of `configs/private-docker-host/` to `/root/` on the container, discovers all `docker-compose.yaml` files recursively, builds a `COMPOSE_FILE=...` `.env`, then does `docker-compose pull` + `docker-compose up -d`.

Virtual NICs `eth0:0` through `eth0:9` (`10.0.30.21–30`) are assigned at boot via `/etc/local.d/assign-ips.start` so each service can bind a dedicated IP.

### Services

| Compose file | IP | Services |
|---|---|---|
| `traefik/` | `10.0.30.20` | Traefik v3 reverse proxy (HTTP/HTTPS :80/:443, dashboard :8080) |
| `authelia/` | `10.0.30.21` | Authelia SSO/2FA |
| `vaultwarden/` | `10.0.30.22` | Vaultwarden (Bitwarden-compatible password manager) |
| `arr_stack/` | `10.0.30.23` | WireGuard + qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, FlareSolverr |
| `firefly_iii/` | `10.0.30.24` | Firefly III personal finance |
| `unifi-controller/` | `10.0.30.25` | Unifi network controller |
| (root compose) | `10.0.30.20` | Promtail (log shipper) |
| `ghostfolio/` | `10.0.30.26` | Ghostfolio portfolio tracker (Postgres + Redis) |
| `kimai/` | `10.0.30.27` | Kimai time tracking (MariaDB) |
| `cadvisor/` | `10.0.50.20` | cAdvisor per-container metrics on `:8081` (VLAN 50) |

The `arr_stack` services run inside a WireGuard network namespace (all share the `wireguard` container's network via `network_mode: service:wireguard`).

Traefik reads TLS certificates from the shared Certbot mount (`/etc/letsencrypt/live/*.lan.tarasa24.dev`).

---

## DMZ Docker-Host (`10.0.40.20`)

Internet-accessible services, isolated in the DMZ. Has GPU passthrough (`/dev/dri/renderD128`) for hardware transcoding.

| Service | Notes |
|---|---|
| Jellyfin | Media server; `/media` from USB-HDD |
| Immich | Photo management; `/immich` from USB-HDD |
| Radicale | CalDAV/CardDAV server |
| ntfy | Push notification server (`10.0.40.24`); exposed at `ntfy.homelab.tarasa24.dev` |
| Promtail | Log shipper to Loki |
| cAdvisor | Per-container metrics on `10.0.50.120:8081` (VLAN 50) |

---

## Monitoring Stack (`10.0.30.14`)

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
| `Public` | public DNS → home WAN IP → UXG port forward → nginx → service | True end-user experience. Includes the home WAN uplink, so a failure does not isolate the fault. |
| `Internal` | direct to `10.0.30.x` over the LAN | Bypasses the WAN entirely. If Public fails but Internal passes, the fault is in the WAN/UXG/nginx path, not the service. |
| `Infrastructure` | compose service names on the monitoring network | The monitoring stack checking itself. |

Gatus does **not** alert directly. It sets `metrics: true`, Prometheus scrapes it
as job `gatus`, and Alertmanager owns routing to ntfy — one alert pipeline with
one set of grouping, inhibition and resolved-notification semantics.

**cAdvisor** (`configs/{dmz_docker-host,private-docker-host}/cadvisor/`) —
per-container metrics on both Docker hosts, published on the VLAN 50 IP
(`10.0.50.20:8081`, `10.0.50.120:8081`) and scraped as job `cadvisor`. This is
the only source of per-container up/down state: the Docker daemon metrics on
`:9323` are engine-level aggregates and stay green when an individual container
dies. Lab→DMZ routing works now (unlike the old dmz-router setup), so the
monitoring LXC could reach DMZ ports directly, but cAdvisor is still needed
for per-container granularity that the daemon-level metrics don't have.

Runs `privileged: true` with read-only mounts inside an unprivileged LXC; some
cgroup metrics may be unavailable in that environment. `CAdvisorDown` fires if it
stops reporting, because container-level alerting is blind while it is down.

**Metric names caveat**: the Gatus documentation describes `gatus_check_result_total`
and `gatus_uptime`. Neither exists in the shipped binary. The real metrics are
`gatus_results_endpoint_success` (1/0 gauge), `gatus_results_total`,
`gatus_results_certificate_expiration_seconds` and `gatus_results_duration_seconds`.
Verify against the live `/metrics` output after any Gatus upgrade — a renamed
metric silently disables `ExternalServiceDown`.

**Alert delivery path**: Alertmanager reaches ntfy directly at its internal
DMZ address (`10.0.40.24:8080`), not the public URL — Lab→DMZ routing works
now, so this removes the WAN and hairpin NAT from the alert path entirely.
Confirm this keeps working after any UXG firewall change; delivery would
otherwise fail silently (a TCP connect timeout takes about two minutes, so
`alertmanager_notifications_failed_total` reads zero for a while before a
real failure shows up there — confirm against the ntfy topic itself or the
Alertmanager log instead of trusting that counter immediately).

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
| `monitoring` | 3014 | `configs/monitoring/promtail/promtail-config.yaml` |
| `private-docker-host` | 3020 | `configs/private-docker-host/root/promtail/config.yml` |
| `dmz-docker-host` | 4020 | `configs/dmz_docker-host/root/promtail/config.yml` |
| `dmz-proxy` | 4010 | `configs/promtail/dmz-proxy.yaml` |
| `backup` | 3013 | `configs/promtail/backup.yaml` |
| `dns` | 3011 | `configs/promtail/dns.yaml` |
| `pve` (hypervisor) | — | `configs/promtail/pve.yaml` |
| `dmz-bitcoin-node` | 4013 | `configs/promtail/dmz-bitcoin-node.yaml` |

The three Docker hosts run Promtail as a container with Docker service
discovery. `dmz-proxy`, `backup` and `dns` instead run it as a native Alpine
package via the `promtail` role, tailing static file paths — there is no Docker
daemon on those hosts.

`pve` and `dmz-bitcoin-node` are Debian and run systemd, and Promtail is not
packaged in bookworm, so the role installs the upstream release binary plus a
systemd unit and scrapes **journald** rather than files. That is the only log
source that matters on those two: kernel messages, LXC/VM start and stop and
storage errors on the hypervisor, and `bitcoind`/`electrs` output on the Bitcoin
node — which is where the "why" lives when `SystemdUnitDown` fires.

Journal scraping has a cardinality trap. Every login creates a fresh
`session-<N>.scope`, and a per-unit stream label therefore grows without bound;
the relabel rules drop those and the `user@<N>.service` units explicitly. Entries
with no unit at all (kernel, early boot) default to `service_name=kernel`,
otherwise they produce a bare `<instance>/` job label.

**Grafana datasources are provisioned as code** in
`configs/monitoring/grafana/provisioning/`, so Prometheus and Loki exist on a
fresh deploy instead of being added by hand. They are matched by **name** and
carry no explicit `uid`: the datasources already existed with Grafana-assigned
UIDs, and declaring a different one makes provisioning look them up by that uid,
fail with "data source not found", and crash-loop Grafana at startup. Only pin a
uid on a datasource provisioned from scratch.

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
- **Server**: `lxc_backup` at `10.0.30.13`. Repositories stored at `/backup/repos/` (USB-SSD). Access is key-restricted via `authorized_keys` with `borg serve --restrict-to-path`.
- **Clients**: Each service container has the `borgmatic` Ansible role applied. The role installs borgmatic, copies the SSH private key from `secrets/backup/ssh/id_ed25519`, copies the host-specific borgmatic config from `configs/backup/borg/<hostname>.yaml`, runs `borgmatic extract` to restore on first deploy, then schedules nightly backups via cron at 02:00.
- **Trigger all**: `ansible-playbook playbooks/all/borg-backup-all.yml`

### Restic (remote Hetzner Storage Box)
- **Client**: `lxc_backup` also runs resticprofile to back up to a Hetzner Storage Box over SFTP.
- Profiles: `global`, `borg-to-hetzner-storagebox`, `immich-media-to-hetzner-storagebox`.
- SSH key + host key come from `secrets/hetzner/`; the restic password comes from `secrets/backup/resticprofile/`.

---

## Tailscale Connectivity

Removed as part of the network overhaul — both connectors (`lxc_homelab_tailscale_connector`, `lxc_dmz_tailscale_connector`) and their template have been destroyed. The UXG terminates ingress directly now; nothing replaces this mesh path.

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
2. `cd ansible && ansible-playbook playbooks/pve/pve_init.yml` — mounts USB disks, registers PVE storage pools, makes `vmbr0` VLAN-aware and removes the obsolete `vmbr1`.

### Full bring-up (`scripts/create.sh`)
```bash
cd terraform && terraform init
terraform apply -auto-approve   # run twice — some resources depend on outputs of the first pass
cd ../ansible
ansible-playbook playbooks/lxc/backup-init.yml       # backup server must be up first
ansible-playbook playbooks/lxc/dmz-proxy-init.yml    # DMZ reverse proxy (nginx + certs)
ansible-playbook playbooks/lxc/dmz-docker-host-init.yml
ansible-playbook playbooks/lxc/private-docker-host-init.yml
```

Some containers (`lxc_dns`, `lxc_dmz_bitcoin_node`) trigger their Ansible playbook automatically via Terraform `local-exec` provisioners.

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
