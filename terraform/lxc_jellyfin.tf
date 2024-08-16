resource "proxmox_virtual_environment_container" "lxc_jellyfin" {
  description = "Container running Jellyfin media server"

  node_name = "pve"
  vm_id     = 10004

  tags = ["alpine", "docker", "dmz"]
  depends_on = [
    proxmox_virtual_environment_container.lxc_templates_docker_template,
    proxmox_virtual_environment_container.lxc_backup
  ]

  clone {
    vm_id = proxmox_virtual_environment_container.lxc_templates_docker_template.vm_id
  }

  initialization {
    hostname = "jellyfin"

    # dmz interface
    ip_config {
      ipv4 {
        address = var.jellyfin_ip.address
        gateway = var.jellyfin_ip.gateway
      }
    }

    # lan interface
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    dns {
      servers = ["10.1.0.1"]
    }
  }

  mount_point {
    volume = "USB-SSD:10004"
    path   = "/config"
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

  network_interface {
    name     = "lan"
    bridge   = "vmbr0"
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

resource "proxmox_virtual_environment_firewall_options" "lxc_jellyfin" {
  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_jellyfin.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}


resource "proxmox_virtual_environment_firewall_rules" "lxc_jellyfin" {
  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_jellyfin.vm_id

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to ssh backup serer"
    iface   = "lan"
    dport   = 22
    proto   = "tcp"
    log     = "notice"
  }

  rule {
    type    = "out"
    action  = "DROP"
    comment = "Drop all other output traffic to the LAN"
    iface   = "lan"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow input traffic from the DMZ to port 80"
    iface   = "dmz"
    dport   = 80
    proto   = "tcp"
  }
}
