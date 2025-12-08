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

provider "proxmox" {
  endpoint = var.proxmox_config["endpoint"]
  username = var.proxmox_config["username"]
  password = var.proxmox_config["password"]
  insecure = true
  ssh {
    agent    = false
    private_key = file("~/.ssh/homelab_proxmox")
  }
}
