resource "proxmox_virtual_environment_container" "lxc_dmz_router" {
  description = "Container running a router for the dmz network"

  node_name = "pve"
  vm_id     = 1002

  tags = ["alpine", "dmz", "router"]

  depends_on = [proxmox_virtual_environment_download_file.alpine_linux_template]

  initialization {
    hostname = "dmz-router"

    ip_config {
      ipv4 {
        address = var.dmz_router_wan_ip.address
        gateway = var.dmz_router_wan_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = var.dmz_router_lan_ip.address
      }
    }

    user_account {
      password = random_password.dmz_router_password.result
    }
  }
  unprivileged = true

  network_interface {
    name     = "eth0"
    firewall = true
  }
  network_interface {
    name     = "dmz"
    bridge   = proxmox_virtual_environment_network_linux_bridge.dmz_bridge.name
    firewall = true
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.alpine_linux_template.id
    type             = "alpine"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 5
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ../ansible && \
      ansible-playbook \
      ./playbooks/lxc/dmz-router-init.yml
    EOT
  }
}

variable "dmz_router_wan_ip" {
  description = "The IP address of the DMZ router"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.2/22"
    gateway = "10.0.0.1"
  }
}

variable "dmz_router_lan_ip" {
  description = "The IP address of the DMZ router"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.1.0.1/24"
    gateway = ""
  }
}

resource "random_password" "dmz_router_password" {
  length  = 16
  special = true
}


resource "proxmox_virtual_environment_network_linux_bridge" "dmz_bridge" {
  comment = "Bridge for the DMZ network"

  node_name = "pve"
  name      = "vmbr1"

  address = "10.1.0.1/24"
}

resource "proxmox_virtual_environment_firewall_options" "lxc_dmz_router" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_dmz_router
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_dmz_router.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "DROP"
}


resource "proxmox_virtual_environment_firewall_rules" "lxc_dmz_router" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_dmz_router
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_dmz_router.vm_id

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to DMZ"
    iface   = "net1"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to WAN (Internet) only on port 51820/udp (WireGuard)"
    iface   = "net0"
    dport   = 51820
    proto   = "udp"
    log     = "notice"
  }
}
