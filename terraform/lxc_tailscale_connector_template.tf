resource "proxmox_virtual_environment_container" "lxc_tailscale_connector_template" {
  description = "Template for creating Tailscale connector containers"

  node_name = "pve"
  vm_id     = 3003

  tags       = ["template", "alpine", "tailscale"]
  unprivileged = true

  initialization {
    hostname = "tailscale-connector-template"

    ip_config {
      ipv4 {
        address = var.tailscale_connector_template_ip.address
        gateway = var.tailscale_connector_template_ip.gateway
      }
    }

    user_account {
      password = random_password.lxc_tailscale_connector_template_password.result
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

  device_passthrough {
    path = "/dev/net/tun"
    mode = "0777"
  }

  lifecycle {
    ignore_changes = [
      template
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/tailscale-connector-template-init.yml
    EOT
  }
}

variable "tailscale_connector_template_ip" {
  description = "The IP address of the Tailscale connector template"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.3.3/22"
    gateway = "10.0.0.1"
  }
}

resource "random_password" "lxc_tailscale_connector_template_password" {
  length  = 16
  special = true
}
