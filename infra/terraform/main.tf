module "talos_iso" {
  source = "./modules/iso_manager"

  remote_host      = var.hypervisor01_ip
  iso_url          = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/talos-amd64.iso"
  destination_name = "talos-amd64-${var.talos_version}.iso"
}

resource "proxmox_vm_qemu" "talos-master-01" {
  depends_on = [
    module.talos_iso
  ]

  name        = "talos-master-01"
  target_node = "hypervisor"
  os_type     = "ubuntu"
  onboot      = true
  iso         = "local:iso/talos-amd64-${var.talos_version}.iso"
  cores       = 12
  memory      = 11264
  qemu_os     = "other"

  network {
    bridge    = "vmbr0"
    firewall  = false
    link_down = false
    model     = "virtio"
  }

  scsihw = "virtio-scsi-single"
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "64G"
  }
}
