resource "proxmox_virtual_environment_container" "lxc_monitoring" {
  description = "Container for gathering and displaying monitoring data"

  node_name = "pve"
  vm_id     = 1004

  tags = ["alpine", "docker", "monitoring"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_backup
  ]

  memory {
    dedicated = 2048
    swap      = 2048
  }

  cpu {
    cores = 2
  }

  initialization {
    hostname = "monitoring"

    ip_config {
      ipv4 {
        address = var.monitoring_ip.address
        gateway = var.monitoring_ip.gateway
      }
    }

    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    user_account {
      password = random_password.monitoring_password.result
    }
  }

  features {
    nesting = true
  }
  unprivileged = true

  network_interface {
    name = "eth0"
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }


  disk {
    datastore_id = "local-lvm"
    size         = 20
  }

  mount_point {
    volume = "/mnt/USB-SSD/monitoring-cold"
    path   = "/mnt/monitoring-cold"
  }
}

variable "monitoring_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.4/22"
    gateway = "10.0.0.1"
  }
}

resource "random_password" "monitoring_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "monitoring_password" {
  value     = random_password.monitoring_password.result
  sensitive = true
}
