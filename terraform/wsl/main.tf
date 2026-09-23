# WSL-variant av labbet. Anropar rotmodulen i ../ som en modul, vilket ger ett eget
# state i den här katalogen utan att någon fil i ../ behöver ändras.
#
# OBS: domänerna heter mongo-node-1..N oavsett varifrån du kör. Kör därför från antingen
# ../ eller den här katalogen, aldrig båda - annars krockar de om samma libvirt-objekt.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.6"
    }
  }
}

# Provider-blocket (qemu:///system) ligger i ../main.tf och ärvs härifrån.
module "lab" {
  source = "../"

  ssh_public_key = var.ssh_public_key
  node_count     = var.node_count
  memory_mb      = var.memory_mb
  vcpu           = var.vcpu
  disk_size_gb   = var.disk_size_gb
  stopped_nodes  = var.stopped_nodes
}
