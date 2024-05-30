terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.58.1"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
  }
}
