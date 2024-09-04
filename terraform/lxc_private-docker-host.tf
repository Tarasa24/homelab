resource "proxmox_virtual_environment_container" "lxc_private-docker-host" {
  description = "Container for hosting containized internal services"

  node_name = "pve"
  vm_id     = 1020

  tags = ["alpine", "docker"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_templates_docker_template,
    proxmox_virtual_environment_container.lxc_backup,
    proxmox_virtual_environment_container.lxc_dmz_router # For ssl certificate
  ]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
  }

  memory {
    dedicated = 2048
    swap      = 2048
  }

  initialization {
    hostname = "private-docker-host"

    ip_config {
      ipv4 {
        address = var.private-docker-host_ip.address
        gateway = var.private-docker-host_ip.gateway
      }
    }
  }

  network_interface {
    name = "eth0"
  }

  mount_point {
    volume    = "/mnt/usb-ssd/ssl"
    path      = "/etc/letsencrypt"
    read_only = true
  }
  mount_point {
    volume = "/mnt/usb-hdd/jellyfin-media"
    path   = "/media"
  }

  mount_point {
    volume = "/mnt/usb-ssd/downloads"
    path   = "/downloads"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 10
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/private-docker-host-init.yml
    EOT
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
