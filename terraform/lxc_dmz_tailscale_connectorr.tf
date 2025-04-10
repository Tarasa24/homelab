resource "proxmox_virtual_environment_container" "lxc_dmz_tailscale_connector" {
  description = "Tailscale container for routing traffic to and from the dmz"

  node_name = "pve"
  vm_id     = 1000100
  tags      = ["alpine", "tailscale"]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_tailscale_connector_template.vm_id
  }

  initialization {
    hostname = "dmz-tailscale-connector"

    ip_config {
      ipv4 {
        address = var.dmz_tailscale_connector_ip.address
        gateway = var.dmz_tailscale_connector_ip.gateway
      }
    }
  }

  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
  }
}

variable "dmz_tailscale_connector_ip" {
  description = "The IP address of the Tailscale connector for the dmz"
  type = object({
    address = string
    gateway = string
  })
  default = {
    address = "10.1.0.100/22"
    gateway = "10.1.0.1"
  }
}
