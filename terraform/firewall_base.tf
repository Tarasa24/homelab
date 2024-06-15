resource "proxmox_virtual_environment_firewall_rules" "cluster_level_firewall_rules" {
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
