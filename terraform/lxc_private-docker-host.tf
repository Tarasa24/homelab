resource "proxmox_virtual_environment_container" "lxc_private-docker-host" {
  description = "Container for hosting containized internal services"

  node_name = "pve"
  vm_id     = 1020

  tags = ["alpine", "docker"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_backup
  ]

  memory {
    dedicated = 4096
    swap      = 4096
  }

  cpu {
    cores = 2
  }

  initialization {
    hostname = "private-docker-host"

    ip_config {
      ipv4 {
        address = var.private-docker-host_ip.address # LAN IP (eth0)
        gateway = var.private-docker-host_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = "10.0.50.20/24" # Monitoring VLAN IP (mon)
      }
    }

    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      password = random_password.private_docker_host_password.result
    }
  }

  features {
    nesting = true
  }
  unprivileged = true

  network_interface {
    name = "eth0"
    bridge = "vmbr0"
    firewall = true
  }


  network_interface {
    name    = "mon"
    bridge  = "vmbr0"
    vlan_id = var.vlan_ids["monitoring"]
    firewall = true
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }


  disk {
    datastore_id = "local-lvm"
    size         = 68
  }

  mount_point {
    volume    = "/mnt/USB-SSD/ssl"
    path      = "/etc/letsencrypt"
    read_only = true
    shared    = true
  }
  mount_point {
    volume = "/mnt/USB-HDD/jellyfin-media"
    path   = "/media"
    shared = true
  }

  mount_point {
    volume = "/mnt/USB-SSD/downloads"
    path   = "/downloads"
  }

  mount_point {
    volume = "/mnt/USB-SSD/cache"
    path   = "/cache"
    shared = true
  }
}

variable "private-docker-host_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.20/22"
    gateway = "10.0.0.1"
  }
}

resource "random_password" "private_docker_host_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "private-docker_host_password" {
  value     = random_password.private_docker_host_password.result
  sensitive = true
}
