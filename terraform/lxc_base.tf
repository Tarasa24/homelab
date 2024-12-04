resource "proxmox_virtual_environment_download_file" "alpine_linux_template" {
  content_type = "vztmpl"
  datastore_id = "USB-HDD"
  node_name    = "pve"
  url          = "http://download.proxmox.com/images/system/alpine-3.18-default_20230607_amd64.tar.xz"
}
