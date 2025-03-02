resource "proxmox_virtual_environment_download_file" "alpine_linux_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"
  url          = "http://download.proxmox.com/images/system/alpine-3.20-default_20240908_amd64.tar.xz"
}

resource "proxmox_virtual_environment_download_file" "nixos_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"
  url          = "https://hydra.nixos.org/build/280671319/download/1/nixos-system-x86_64-linux.tar.xz"
}

resource "proxmox_virtual_environment_download_file" "debian_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"
  url          = "http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
}
