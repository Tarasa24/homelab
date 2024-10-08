resource "proxmox_virtual_environment_container" "lxc_templates_docker_template" {
  description = "Alpine linux container containing Docker installation meant for cloning and running Docker in specific environments"

  node_name = "pve"
  vm_id     = 3001

  tags = ["template", "docker", "alpine"]

  initialization {
    hostname = "docker-template"

    ip_config {
      ipv4 {
        address = var.docker_template_ip.address
        gateway = var.docker_template_ip.gateway
      }
    }

    user_account {
      password = random_password.docker_template_password.result
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
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 10
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
      ./playbooks/lxc/docker-template-init.yml
    EOT
  }
}

variable "docker_template_ip" {
  description = "The IP address of the Docker template"
  type = object({
    address = string
    gateway = string
  })
  default = {
    address = "10.0.3.1/22"
    gateway = "10.0.0.1"
  }
}

resource "proxmox_virtual_environment_download_file" "alpine_linux_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"
  url          = "http://download.proxmox.com/images/system/alpine-3.18-default_20230607_amd64.tar.xz"
}

resource "random_password" "docker_template_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "docker_template_password" {
  value     = random_password.docker_template_password.result
  sensitive = true
}
