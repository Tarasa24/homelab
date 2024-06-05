terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.58.1"
    }
  }
}

variable "proxmox_config" {
  type = map(string)
}

provider "proxmox" {
  endpoint  = var.proxmox_config["endpoint"]
  api_token = var.proxmox_config["api_token"]
  insecure  = true
  ssh {
    agent    = true
    username = "terraform"
  }
}
