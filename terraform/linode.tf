resource "linode_instance" "bastion-host" {
  label  = "bastion-host"
  region = "eu-central"
  type   = "g6-nanode-1"
}
