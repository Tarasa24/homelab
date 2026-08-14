terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.89.0"
    }
  }
}

variable "proxmox_config" {
  type = map(string)
}

# Network VLAN IDs
variable "vlan_ids" {
  type = map(number)
  default = {
    monitoring = 50
    dmz        = 40 # Future VLAN for DMZ when migrated from bridge
  }
  description = "VLAN IDs for different network segments"
}

provider "proxmox" {
  endpoint = var.proxmox_config["endpoint"]
  username = var.proxmox_config["username"]
  password = var.proxmox_config["password"]
  insecure = true
  ssh {
    agent       = false
    private_key = file("~/.ssh/homelab_proxmox")
  }
}
