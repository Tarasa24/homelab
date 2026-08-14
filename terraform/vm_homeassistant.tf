resource "proxmox_virtual_environment_vm" "vm_homeassistant" {
  description = "Virtual Machine for Home Assistant and related services"

  node_name = "pve"
  vm_id     = 1005
  tags      = ["homeassistant"]
  name      = "homeassistant"
  bios      = "ovmf"
  machine   = "q35"

  memory {
    dedicated = 4096
    floating  = 4096
  }

  cpu {
    cores = 2
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.homeassistant_qcow2_template.id
    interface    = "scsi0"
    size         = 32
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.homeassistant_ip.address
        gateway = var.homeassistant_ip.gateway
      }
    }
  }

  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
}

variable "homeassistant_ip" {
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.1.5/22"
    gateway = "10.0.0.1"
  }
}

resource "proxmox_virtual_environment_download_file" "homeassistant_qcow2_template" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = "pve"
  url                     = "https://github.com/home-assistant/operating-system/releases/download/16.3/haos_ova-16.3.qcow2.xz"
  file_name               = "haos_ova-16.3.qcow2.xz.img"
  decompression_algorithm = "zst"
}
