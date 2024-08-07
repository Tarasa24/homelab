resource "proxmox_virtual_environment_container" "lxc_jellyfin" {
  description = "Container running Jellyfin media server"

  node_name = "pve"
  vm_id     = 10004

  tags       = ["alpine", "docker", "dmz"]
  depends_on = [proxmox_virtual_environment_container.lxc_templates_docker_template]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
  }

  initialization {
    hostname = "jellyfin"

    ip_config {
      ipv4 {
        address = var.jellyfin_ip.address
        gateway = var.jellyfin_ip.gateway
      }
    }
  }

  mount_point {
    volume = "USB-SSD:10004"
    path   = "/opt/jellyfin"
    size   = "5G"
  }

  mount_point {
    volume = "/mnt/usb-hdd/jellyfin-media"
    path   = "/media"
  }

  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dmz-jellyfin-init.yml
    EOT
  }
}

variable "jellyfin_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.1.0.4/24"
    gateway = "10.1.0.1"
  }
}
