# see https://registry.terraform.io/providers/bpg/proxmox/0.64.0/docs/resources/virtual_environment_file
resource "proxmox_virtual_environment_file" "talos" {
  datastore_id = "local"
  node_name    = "pve"
  content_type = "iso"
  source_file {
    path      = "tmp/talos/talos-${var.talos_version}.qcow2"
    file_name = "talos-${var.talos_version}.img"
  }
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.64.0/docs/resources/virtual_environment_vm
resource "proxmox_virtual_environment_vm" "controller" {
  count           = var.controller_count
  name            = "${var.prefix}-${local.controller_nodes[count.index].name}"
  node_name       = "pve"
  tags            = sort(["talos", "controller", "example", "terraform"])
  stop_on_destroy = true
  bios            = "ovmf"
  machine         = "q35"
  scsi_hardware   = "virtio-scsi-single"
  operating_system {
    type = "l26"
  }
  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 4 * 1024
  }
  vga {
    type = "qxl"
  }
  network_device {
    bridge = "vmbr0"
  }
  tpm_state {
    version = "v2.0"
  }
  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    type         = "4m"
  }
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 40
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_file.talos.id
  }
  agent {
    enabled = true
    trim    = true
  }
  initialization {
    ip_config {
      ipv4 {
        address = "${local.controller_nodes[count.index].address}/24"
        gateway = var.cluster_node_network_gateway
      }
    }
  }
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.64.0/docs/resources/virtual_environment_vm
resource "proxmox_virtual_environment_vm" "worker" {
  count           = var.worker_count
  name            = "${var.prefix}-${local.worker_nodes[count.index].name}"
  node_name       = "pve"
  tags            = sort(["talos", "worker", "example", "terraform"])
  stop_on_destroy = true
  bios            = "ovmf"
  machine         = "q35"
  scsi_hardware   = "virtio-scsi-single"
  operating_system {
    type = "l26"
  }
  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 4 * 1024
  }
  vga {
    type = "qxl"
  }
  network_device {
    bridge = "vmbr0"
  }
  tpm_state {
    version = "v2.0"
  }
  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    type         = "4m"
  }
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 40
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_file.talos.id
  }
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 60
    file_format  = "raw"
  }
  agent {
    enabled = true
    trim    = true
  }
  initialization {
    ip_config {
      ipv4 {
        address = "${local.worker_nodes[count.index].address}/24"
        gateway = var.cluster_node_network_gateway
      }
    }
  }
}
