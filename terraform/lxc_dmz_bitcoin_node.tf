resource "proxmox_virtual_environment_container" "lxc_dmz_bitcoin_node" {
  description = "Debian container for Bitcoin node in DMZ"

  node_name = "pve"
  vm_id     = 10003

  tags = ["debian", "dmz"]

  depends_on = [
    proxmox_virtual_environment_container.lxc_backup,
    proxmox_virtual_environment_container.lxc_dmz_router
  ]

  memory {
    dedicated = 2048
    swap      = 2048
  }

  cpu {
    cores = 4
  }

  features {
    nesting = true
  }
  unprivileged = false

  initialization {
    hostname = "bitcoin-node"

    dns {
      servers = ["1.1.1.1", "8.8.8.8"] # split("/", var.dmz_router_lan_ip.address)[0]
    }

    ip_config {
      ipv4 {
        address = var.dmz_bitcoin_node_ip.address
        gateway = var.dmz_bitcoin_node_ip.gateway
      }
    }
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.debian_template.id
    type             = "debian"
  }

  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
  }

  disk {
    datastore_id = "local-lvm"
    size         = 15
  }

  console {
    type = "console"
  }

  mount_point {
    volume    = "/mnt/USB-BITCOIN"
    path      = "/mnt/bitcoin"
  }

  mount_point {
    volume    = "/mnt/USB-BITCOIN-APPS"
    path      = "/mnt/bitcoin-apps"
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dmz-bitcoin-node-init.yml
    EOT
  }
}

variable "dmz_bitcoin_node_ip" {
  description = "The IP address of bitcoin node in DMZ"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.1.0.3/24"
    gateway = "10.1.0.1"
  }
}
