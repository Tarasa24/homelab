resource "proxmox_virtual_environment_container" "lxc_dmz-docker-host" {
  description = "Container for hosting containized external services"

  node_name = "pve"
  vm_id     = 100020

  tags = ["alpine", "docker", "dmz"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_backup,
    proxmox_virtual_environment_container.lxc_dmz_router
  ]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
  }

  memory {
    dedicated = 2048
    swap      = 2048
  }

  cpu {
    cores = 2
  }

  initialization {
    hostname = "dmz-docker-host"

    dns {
      servers = [split("/", var.dmz_router_lan_ip.address)[0]]
    }

    ip_config {
      ipv4 {
        address = var.dmz-docker-host_ip.address
        gateway = var.dmz-docker-host_ip.gateway
      }
    }
  }

  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
  }

  mount_point {
    volume    = "/mnt/usb-ssd/ssl"
    path      = "/etc/letsencrypt"
    read_only = true
  }

  disk {
    datastore_id = "local-lvm"
  }

  provisioner "local-exec" {
    when    = create
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dmz-docker-host-init.yml
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/all/borg-backup-all.yml --extra-vars "variable_host=lxc_dmz_docker-host"
    EOT
  }
}

variable "dmz-docker-host_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.1.0.20/22"
    gateway = "10.1.0.1"
  }
}
