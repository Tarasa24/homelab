terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.58.1"
    }
    linode = {
      source  = "linode/linode"
      version = "2.22.0"
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
    agent    = true
    username = "terraform"
  }
}

variable "linode_token" {
  type = string
}

provider "linode" {
  token = var.linode_token
}
