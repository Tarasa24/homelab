resource "proxmox_virtual_environment_vm" "vm_homeassistant" {
  description = "Virtual Machine for Home Assistant and related services"

  node_name = "pve"

  # Moved to 1015 by hand on the PVE host (config rename + lvrename) and
  # reconciled into state with `terraform state rm` + `import`, ahead of this
  # apply -- vm_id is ForceNew and this VM has no borg config, so letting
  # Terraform do the move itself would have destroyed all Home Assistant state.
  vm_id   = 1015
  tags    = ["homeassistant"]
  name    = "homeassistant"
  bios    = "ovmf"
  machine = "q35"

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

  # file_id only matters for the initial clone-from-image; the imported disk
  # has no such attribute in its live state, so config wanting it set would
  # otherwise force a replace (and destroy) on every plan from now on.
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_ids["lab"]
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
    address = "10.0.30.15/24"
    gateway = "10.0.30.1"
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
