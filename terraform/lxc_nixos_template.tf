resource "proxmox_virtual_environment_container" "lxc_nixos_template" {
  description = "Template for creating NixOS containers"

  node_name = "pve"
  vm_id     = 3002

  tags = ["template", "nixos"]

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
    name = "veth0"
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_file.nixos_template.id
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

resource "proxmox_virtual_environment_file" "nixos_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"

  source_file {
    path = "${data.external.generate_nixos_template.result["path"]}/tarball/nixos-system-x86_64-linux.tar.xz"
  }
}

data "external" "generate_nixos_template" {
  program = [
    "sh", "-c",
    "if [ ! -f /tmp/nixos-template ]; then nix run github:nix-community/nixos-generators -- --format proxmox-lxc -o /tmp/nixos-template > /dev/null 2>&1; fi; echo '{\"path\": \"/tmp/nixos-template\"}'"
  ]
}
