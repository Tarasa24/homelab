resource "proxmox_virtual_environment_container" "lxc_dmz-docker-host" {
  description = "Container for hosting containized external services"

  node_name = "pve"
  vm_id     = 100020

  tags = ["alpine", "docker", "dmz"]
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

  initialization {
    hostname = "dmz-docker-host"

    dns {
      domain = " "
      servers = ["1.1.1.1", "8.8.8.8"] # split("/", var.dmz_router_lan_ip.address)[0]
    }

    ip_config {
      ipv4 {
        address = var.dmz-docker-host_ip.address
        gateway = var.dmz-docker-host_ip.gateway
      }
    }

    user_account {
      password = random_password.dmz_docker_host_password.result
    }
  }

  features {
    nesting = true
  }
  unprivileged = true

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }

  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
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
    volume = "/mnt/USB-SSD/cache"
    path   = "/cache"
    shared = true
  }

  mount_point {
    volume = "/mnt/USB-HDD/immich"
    path   = "/immich"
    shared = true
  }

  disk {
    datastore_id = "local-lvm"
    size         = 10
  }
}

variable "dmz-docker-host_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.1.0.20/22"
    gateway = "10.1.0.1"
  }
}

resource "random_password" "dmz_docker_host_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "dmz-docker_host_password" {
  value     = random_password.dmz_docker_host_password.result
  sensitive = true
}
