resource "proxmox_virtual_environment_container" "lxc_dns" {
  description = "Container for T-DNS server"

  node_name = "pve"
  vm_id     = 1001

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
        address = var.dns_ip.address
        gateway = var.dns_ip.gateway
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

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dns-init.yml
    EOT
  }
}

variable "dns_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.1/22"
    gateway = "10.0.0.1"
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
