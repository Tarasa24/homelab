resource "proxmox_virtual_environment_container" "lxc_dmz_proxy" {
  description = "Container running the reverse proxy and TLS termination for the dmz network"

  node_name = "pve"
  vm_id     = 4010

  tags = ["alpine", "dmz", "proxy"]

  initialization {
    hostname = "dmz-proxy"

    dns {
      domain  = " "
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = var.dmz_proxy_ip.address # DMZ IP (dmz)
        gateway = var.dmz_proxy_ip.gateway
      }
    }

    ip_config {
      ipv4 {
        address = "10.0.50.2/24" # Monitoring VLAN IP (mon)
      }
    }

    user_account {
      password = random_password.dmz_proxy_password.result
    }
  }
  unprivileged = true

  # NIC order is load-bearing: the firewall rules below address interfaces
  # positionally as net0/net1, not by the names given here.
  network_interface {
    name     = "dmz"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_ids["dmz"]
    firewall = true
  }
  network_interface {
    name     = "mon"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_ids["monitoring"]
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

  mount_point {
    volume = "/mnt/USB-SSD/ssl"
    path   = "/etc/letsencrypt"
  }
}

variable "dmz_proxy_ip" {
  description = "The IP address of the DMZ proxy"
  type = object({
    address = string
    gateway = string
  })

  default = {
    address = "10.0.40.10/24"
    gateway = "10.0.40.1"
  }
}

resource "random_password" "dmz_proxy_password" {
  length  = 16
  special = true
}

resource "proxmox_virtual_environment_firewall_options" "lxc_dmz_proxy" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_dmz_proxy
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_dmz_proxy.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "DROP"
}


resource "proxmox_virtual_environment_firewall_rules" "lxc_dmz_proxy" {
  depends_on = [
    proxmox_virtual_environment_container.lxc_dmz_proxy,
    proxmox_virtual_environment_firewall_options.lxc_dmz_proxy
  ]

  node_name    = "pve"
  container_id = proxmox_virtual_environment_container.lxc_dmz_proxy.vm_id

  # net0 is the dmz NIC (VLAN 40), net1 is the mon NIC (VLAN 50).

  # Mirrors the UXG port-forward list. The firewall is stateful, so replies on
  # established connections do not need their own rules. Management does not
  # need SSH here: Ansible reaches this container as `pct exec` from the PVE
  # host, not over the network.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow inbound HTTP/HTTPS, Electrum, bitcoind P2P and unifi inform"
    iface   = "net0"
    dport   = "80,443,8080,8333,50002"
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow inbound unifi STUN"
    iface   = "net0"
    dport   = "3478"
    proto   = "udp"
  }

  # Each outbound protocol needs its own rule; certbot in particular breaks
  # silently without 443 and 53. No NTP rule: unprivileged container has no
  # CAP_SYS_TIME and takes its clock from the PVE host.
  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to the internet for ACME and the DNS API"
    iface   = "net0"
    dport   = "443"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to the internet for apk and ACME HTTP"
    iface   = "net0"
    dport   = "80"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound DNS (udp)"
    iface   = "net0"
    dport   = "53"
    proto   = "udp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow outbound DNS (tcp)"
    iface   = "net0"
    dport   = "53"
    proto   = "tcp"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to backup server on ssh port"
    iface   = "net0"
    dport   = "22"
    proto   = "tcp"
    dest    = split("/", var.lxc_backup_ip.address)[0]
    log     = "notice"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to authelia"
    iface   = "net0"
    dport   = "9091"
    proto   = "tcp"
    dest    = "10.0.30.21/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to unifi controller inform port"
    iface   = "net0"
    dport   = "8080"
    proto   = "tcp"
    dest    = "10.0.30.25/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to unifi controller stun port"
    iface   = "net0"
    dport   = "3478"
    proto   = "udp"
    dest    = "10.0.30.25/32"
  }

  # nginx proxy_passes to these DMZ-internal backends, but output_policy=DROP
  # silently ate every connection attempt -- same-VLAN destinations are not
  # exempt from this container's own firewall.
  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to jellyfin"
    iface   = "net0"
    dport   = "8096"
    proto   = "tcp"
    dest    = "10.0.40.21/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to ntfy"
    iface   = "net0"
    dport   = "8080"
    proto   = "tcp"
    dest    = "10.0.40.24/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to Gatus (status page)"
    # net1, not net0: 10.0.50.4 is on the monitoring VLAN, reachable via the mon NIC.
    iface   = "net1"
    dport   = "8080"
    proto   = "tcp"
    dest    = "10.0.50.4/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to radicale"
    iface   = "net0"
    dport   = "5232"
    proto   = "tcp"
    dest    = "10.0.40.22/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to electrs"
    iface   = "net0"
    dport   = "50001"
    proto   = "tcp"
    dest    = "10.0.40.13/32"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to bitcoind P2P"
    iface   = "net0"
    dport   = "8333"
    proto   = "tcp"
    dest    = "10.0.40.13/32"
  }

  # net1 is the mon NIC; without this, input_policy=DROP blocked all scrapes.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow Prometheus to scrape node_exporter over the monitoring VLAN"
    iface   = "net1"
    source  = "10.0.50.0/24"
    dport   = "9100"
    proto   = "tcp"
  }

  # Appended at the end, not alongside the other net1 rule above: this
  # provider diffs the rule list positionally, and a mid-list insert churns
  # every rule after it as a spurious "modified".
  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "Allow output traffic to Loki"
    iface   = "net1"
    dport   = "3100"
    proto   = "tcp"
    dest    = "10.0.50.4/32"
  }
}
