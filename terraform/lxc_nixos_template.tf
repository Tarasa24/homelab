resource "proxmox_virtual_environment_container" "lxc_nixos_template" {
  description = "Template for creating NixOS containers"

  node_name = "pve"
  vm_id     = 3002

  tags       = ["template", "nixos"]
  depends_on = [proxmox_virtual_environment_download_file.nixos_template]

  initialization {
    hostname = "nixos-template"

    ip_config {
      ipv4 {
        address = var.nixos_template_ip.address
        gateway = var.nixos_template_ip.gateway
      }
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
    template_file_id = proxmox_virtual_environment_download_file.nixos_template.id
    type             = "nixos"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 5
  }

  console {
    type = "console"
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
      ./playbooks/lxc/nixos-template-init.yml
    EOT
  }
}

variable "nixos_template_ip" {
  description = "The IP address of the NixOS template"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.3.2/22"
    gateway = "10.0.0.1"
  }
}
