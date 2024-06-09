resource "proxmox_virtual_environment_container" "lxc_authentik" {
  description = "Container running Authentik identity provider"

  node_name = "pve"
  vm_id     = 2004

  tags = ["alpine", "docker"]

  depends_on = [proxmox_virtual_environment_container.lxc_templates_docker_template]
  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
  }

  initialization {
    hostname = "authentik"

    ip_config {
      ipv4 {
        address = var.authentik_ip.address
        gateway = var.authentik_ip.gateway
      }
    }
  }

  mount_point {
    volume = "USB-SSD:2004"
    path   = "/etc/authentik"
    size   = "1G"
    backup = true
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/authentik-init.yml
    EOT
  }
}

variable "authentik_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.2.4/22"
    gateway = "10.0.0.1"
  }
}
