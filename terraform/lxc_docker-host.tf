resource "proxmox_virtual_environment_container" "lxc_private-docker-host" {
  description = "Container for hosting containized internal services"

  node_name = "pve"
  vm_id     = 1020

  tags = ["alpine", "docker"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_templates_docker_template,
    proxmox_virtual_environment_container.lxc_backup
  ]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
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
