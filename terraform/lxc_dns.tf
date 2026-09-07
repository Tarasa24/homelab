resource "proxmox_virtual_environment_container" "lxc_dns" {
  description = "Container for T-DNS server"

  node_name = "pve"
  vm_id     = 3011

  tags = ["alpine", "dns"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_backup
  ]

  memory {
    dedicated = 512
    swap      = 512
  }

  cpu {
    cores = 1
  }

  initialization {
    hostname = "dns"

    ip_config {
      ipv4 {
        address = var.dns_ip.address # LAN IP (eth0)
        gateway = var.dns_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = "10.0.50.1/24" # Monitoring VLAN IP (mon)
      }
    }

    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      password = random_password.dns_password.result
    }
  }

  unprivileged = true
  features {
    nesting = true
  }

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
    size         = 20
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dns-init.yml
    EOT
  }

  # Both are create-time-only: the imported live container has neither in its
  # actual state (the password isn't readable back, and template_file_id only
  # matters for the initial clone), so config declaring them forces an
  # unwanted replace on every plan after a VMID-preserving import.
  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
    ]
  }
}

variable "dns_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.30.11/24"
    gateway = "10.0.30.1"
  }
}

resource "random_password" "dns_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "dns_password" {
  value     = random_password.dns_password.result
  sensitive = true
}
