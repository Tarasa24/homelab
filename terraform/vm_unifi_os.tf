# Self-hosted UniFi OS Server, replacing the old unifi-network-application +
# mongo compose stack. A VM not an LXC (like vm_homeassistant.tf): Ubiquiti
# only support bare metal or VM, and the installer self-updates in place via
# uosserver-updater.service, so the VM's own disk is the persistent state.
resource "proxmox_virtual_environment_vm" "vm_unifi_os" {
  description = "Virtual Machine for self-hosted UniFi OS Server"

  node_name = "pve"
  # VMID matches the Lab IP's last octet, same convention as every other host.
  vm_id = 3016
  tags  = ["debian", "unifi"]
  name  = "unifi-os"

  # Sized to the tested-install minimum (2 vCPU / 4GB / 25GB), with disk headroom.
  memory {
    dedicated = 4096
  }

  cpu {
    cores = 2
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.debian_unifi_os_cloud_image.id
    interface    = "scsi0"
    size         = 32
  }

  # file_id is create-only and absent from imported state; without this it
  # forces a replace on every plan (same reasoning as vm_homeassistant.tf).
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_ids["lab"]
  }

  # mon NIC: node_exporter is scraped over VLAN 50.
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_ids["monitoring"]
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.vm_unifi_os_ip.address
        gateway = var.vm_unifi_os_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = "10.0.50.5/24" # Monitoring VLAN IP (mon)
      }
    }

    # Required: the IP is static so there's no DHCP-provided resolver.
    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    # Console password is set (not left unused like elsewhere) to keep a
    # working login path if SSH becomes unreachable after a reboot.
    user_account {
      username = "ansible"
      password = random_password.vm_unifi_os_console_password.result
      keys     = [tls_private_key.vm_unifi_os_ssh.public_key_openssh]
    }
  }

  # Disabled: the genericcloud image ships no qemu-guest-agent, so Terraform
  # would wait for the agent and fail every apply. Install it by hand for the
  # IP-in-summary display.
  agent {
    enabled = false
  }

  # No provisioner: run the install manually over SSH, or via
  #   ansible-playbook playbooks/vm/unifi-os-init.yml -e unifi_os_installer_url=...
}

variable "vm_unifi_os_ip" {
  description = "The IP address of the UniFi OS Server VM"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.30.16/24"
    gateway = "10.0.30.1"
  }
}

resource "random_password" "vm_unifi_os_console_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

output "vm_unifi_os_console_password" {
  value     = random_password.vm_unifi_os_console_password.result
  sensitive = true
}

resource "proxmox_virtual_environment_download_file" "debian_unifi_os_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "pve"
  # genericcloud, not generic: has cloud-init preinstalled for the
  # initialization block above.
  url       = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name = "debian-13-genericcloud-amd64.qcow2.img"
}

# Keypair for Ansible to reach this VM over the network (a VM has no pct exec).
# Written under secrets/ like other repo keys, so it's git-crypt encrypted
# rather than gitignored.
resource "tls_private_key" "vm_unifi_os_ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "vm_unifi_os_ssh_private_key" {
  content         = tls_private_key.vm_unifi_os_ssh.private_key_openssh
  filename        = "${path.module}/../secrets/vm_unifi_os/ssh/id_ed25519"
  file_permission = "0600"
}
