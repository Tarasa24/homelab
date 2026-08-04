resource "proxmox_virtual_environment_firewall_alias" "dmz_network" {
  name = "dmz_network"
  cidr = "10.1.0.0/24"
}

resource "proxmox_virtual_environment_firewall_rules" "cluster_level_firewall_rules" {
  rule {
    type    = "in"
    action  = "ACCEPT"
    macro   = "Ping"
    comment = "Allow ICMP traffic for monitoring and diagnostics"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow inter-DMZ traffic"
    source  = proxmox_virtual_environment_firewall_alias.dmz_network.name
    dest    = proxmox_virtual_environment_firewall_alias.dmz_network.name
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow PVE web interface"
    dport   = 8006
    proto   = "tcp"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow SSH"
    dport   = 22
    proto   = "tcp"
  }

  # Scoped to the monitoring container only; input_policy is DROP so without
  # this the PVE host's node_exporter is unreachable.
  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Allow Prometheus to scrape node_exporter on the PVE host"
    source  = "10.0.1.4"
    dport   = 9100
    proto   = "tcp"
  }
}

resource "proxmox_virtual_environment_cluster_firewall" "cluster_level_firewall_options" {
  depends_on = [
    proxmox_virtual_environment_firewall_rules.cluster_level_firewall_rules
  ]

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  log_ratelimit {
    enabled = false
    burst   = 10
    rate    = "5/second"
  }
}
