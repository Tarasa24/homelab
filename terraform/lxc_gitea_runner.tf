resource "proxmox_virtual_environment_container" "lxc_gitea_runner" {
  description = "Standalone Gitea Actions runner. Deliberately separate from private-docker-host: a CI job running here must not be able to touch the host it runs on, including if a future job's purpose is deploying homelab changes."

  node_name = "pve"
  vm_id     = 3012

  tags = ["alpine", "docker", "ci"]

  memory {
    dedicated = 3072
    swap      = 3072
  }

  cpu {
    cores = 2
  }

  initialization {
    hostname = "gitea-runner"

    ip_config {
      ipv4 {
        address = var.gitea_runner_ip.address # Lab IP (eth0)
        gateway = var.gitea_runner_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = "10.0.50.6/24" # Monitoring VLAN IP (mon)
      }
    }

    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      password = random_password.gitea_runner_password.result
    }
  }

  # nesting required for Docker + dind sidecar
  features {
    nesting = true
  }
  unprivileged = true

  # net0/net1 order matters: firewall rules below reference them positionally
  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_ids["lab"]
    firewall = true
  }

  network_interface {
    name     = "mon"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_ids["monitoring"]
    firewall = true
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 30
  }

  # Both create-time-only; absent from imported state, so they'd otherwise
  # force a replace on every plan.
  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
    ]
  }
}

variable "gitea_runner_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.30.12/24"
    gateway = "10.0.30.1"
  }
}

resource "random_password" "gitea_runner_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "gitea_runner_password" {
  value     = random_password.gitea_runner_password.result
  sensitive = true
}

# output_policy=DROP: no route to Proxmox API/SSH exists until a scoped
# deploy token (excluding this vm_id) is added deliberately later.
resource "proxmox_virtual_environment_firewall_options" "lxc_gitea_runner" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_gitea_runner
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_gitea_runner.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "DROP"
}

resource "proxmox_virtual_environment_firewall_rules" "lxc_gitea_runner" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_gitea_runner,
    proxmox_virtual_environment_firewall_options.lxc_gitea_runner
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_gitea_runner.vm_id

  # net0 = eth0 (Lab), net1 = mon. No inbound rule on net0: Ansible uses
  # pct exec, and act_runner only polls Gitea outbound.

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound DNS (udp)"
    iface   = "net0"
    dport   = "53"
    proto   = "udp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound DNS (tcp)"
    iface   = "net0"
    dport   = "53"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound HTTPS - apk packages, Docker Hub/ghcr image pulls for act_runner/dind/job containers, actions marketplace"
    iface   = "net0"
    dport   = "443"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound HTTP - some apk mirrors are plain http"
    iface   = "net0"
    dport   = "80"
    proto   = "tcp"
  }

  # 10.0.30.29 is Gitea's virtual sub-IP on private-docker-host
  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound to Gitea (job polling/registration)"
    iface   = "net0"
    dport   = "80"
    proto   = "tcp"
    dest    = "10.0.30.29/32"
  }

  # 9323 = docker daemon metrics; without it that scrape target reads down permanently.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow Prometheus to scrape node_exporter/cAdvisor/docker over the monitoring VLAN"
    iface   = "net1"
    source  = "10.0.50.0/24"
    dport   = "9100,8081,9323"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to Loki"
    iface   = "net1"
    dport   = "3100"
    proto   = "tcp"
    dest    = "10.0.50.4/32"
  }
}
