resource "proxmox_virtual_environment_container" "lxc_backup" {
  description = "Container running various backup services (borg, restic)"

  node_name = "pve"
  vm_id     = 1003

  tags         = ["alpine"]
  unprivileged = true

  features {
    fuse = true
  }

  initialization {
    hostname = "backup"

    ip_config {
      ipv4 {
        address = var.lxc_backup_ip.address
        gateway = var.lxc_backup_ip.gateway
      }
    }

    dns {
      domain = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      password = random_password.lxc_backup_password.result
    }
  }

  network_interface {
    name = "veth0"
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 5
  }

  mount_point {
    volume = "/mnt/USB-SSD/backup"
    path   = "/backup"
  }
}

variable "lxc_backup_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.3/22"
    gateway = "10.0.0.1"
  }
}

resource "random_password" "lxc_backup_password" {
  length  = 16
  special = true
}
