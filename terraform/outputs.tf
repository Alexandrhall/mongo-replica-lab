output "node_names" {
  value = libvirt_domain.node[*].name
}

output "node_ips" {
  description = "Statiska IP:er, samma ordning som noderna - använd i Ansible-inventoryt"
  value       = [for i in range(var.node_count) : cidrhost(var.network_cidr, var.node_ip_start + i)]
}

output "ansible_inventory" {
  description = "Klistra in i ett Ansible inventory-fil (ini-format)"
  value = join("\n", [
    "[mongo_replica]"
    ], [
    for i in range(var.node_count) :
    "mongo-node-${i + 1} ansible_host=${cidrhost(var.network_cidr, var.node_ip_start + i)} ansible_user=ubuntu"
  ])
}
