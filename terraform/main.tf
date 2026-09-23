terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.6"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

locals {
  # Prefixlängd (t.ex. 24) hämtad ur network_cidr så att den inte kan komma ur synk med variabeln.
  prefix = split("/", var.network_cidr)[1]
}

# Basimage: Ubuntu cloud image, laddas ner en gång och klonas per nod.
resource "libvirt_volume" "base" {
  name   = "ubuntu-base.qcow2"
  pool   = "default"
  source = var.base_image_path
  format = "qcow2"
}

# En disk per nod, cow-klonad från basimagen (snabbt, tar lite plats).
resource "libvirt_volume" "node" {
  count          = var.node_count
  name           = "mongo-node-${count.index + 1}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base.id
  size           = var.disk_size_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

# cloud-init: SSH-nyckel, hostname och statisk IP per nod, så Ansible-inventoryt blir förutsägbart.
resource "libvirt_cloudinit_disk" "node" {
  count = var.node_count
  name  = "mongo-node-${count.index + 1}-cloudinit.iso"
  pool  = "default"

  user_data = templatefile("${path.module}/cloud_init/user_data.tpl", {
    hostname = "mongo-node-${count.index + 1}"
    ssh_key  = var.ssh_public_key
  })

  network_config = templatefile("${path.module}/cloud_init/network_config.tpl", {
    ip_address = cidrhost(var.network_cidr, var.node_ip_start + count.index)
    prefix     = local.prefix
    gateway    = cidrhost(var.network_cidr, 1)
  })
}

resource "libvirt_domain" "node" {
  count  = var.node_count
  name   = "mongo-node-${count.index + 1}"
  memory = var.memory_mb
  vcpu   = var.vcpu

  cloudinit = libvirt_cloudinit_disk.node[count.index].id

  # Nodnummer i var.stopped_nodes hålls avstängda; resten körs. VM:en och disken finns kvar.
  # Providern (0.7.x) kan bara starta via running = true; avstängningen görs av terraform_data.power nedan.
  running = !contains(var.stopped_nodes, count.index + 1)

  # MongoDB 5.0+ kräver AVX. Libvirts default-CPU (qemu64) exponerar inte AVX och mongod
  # dör då med SIGILL. host-passthrough släpper igenom värdens CPU-features.
  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_name   = var.libvirt_network_name
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.node[count.index].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

# dmacvicar/libvirt 0.7.x ignorerar running = false (sparar det bara i state), så avstängningen
# görs här med virsh: ACPI-shutdown så Docker/Mongo stoppas snyggt, hård destroy efter 120 s.
# Byts ut när nodens läge i var.stopped_nodes ändras; för en nod som ska köra gör den ingenting.
resource "terraform_data" "power" {
  count            = var.node_count
  triggers_replace = [contains(var.stopped_nodes, count.index + 1)]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -eu
      [ "${contains(var.stopped_nodes, count.index + 1)}" = "true" ] || exit 0
      d=mongo-node-${count.index + 1}
      v="virsh -c qemu:///system"
      [ "$($v domstate $d)" = "shut off" ] && exit 0
      $v shutdown $d --mode acpi
      for i in $(seq 1 60); do
        [ "$($v domstate $d)" = "shut off" ] && exit 0
        sleep 2
      done
      echo "$d stängdes inte av inom 120 s, gör hård avstängning" >&2
      $v destroy $d
    EOT
  }

  depends_on = [libvirt_domain.node]
}
