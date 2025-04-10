resource "proxmox_virtual_environment_container" "lxc_homelab_tailscale_connector" {
  description = "Tailscale container for routing traffic to and from the homelab"

  node_name = "pve"
  vm_id     = 1100
  tags      = ["alpine", "tailscale"]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_tailscale_connector_template.vm_id
  }

  initialization {
    hostname = "homelab-tailscale-connector"

    ip_config {
      ipv4 {
        address = var.homelab_tailscale_connector_ip.address
        gateway = var.homelab_tailscale_connector_ip.gateway
      }
    }
  }

  network_interface {
    name = "veth0"
  }
}

variable "homelab_tailscale_connector_ip" {
  description = "The IP address of the Tailscale connector for the homelab"
  type = object({
    address = string
    gateway = string
  })
  default = {
    address = "10.0.1.100/22"
    gateway = "10.0.0.1"
  }
}
