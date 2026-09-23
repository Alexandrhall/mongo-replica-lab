output "node_names" {
  value = module.lab.node_names
}

output "node_ips" {
  description = "Statiska IP:er, samma ordning som noderna - används i Ansible-inventoryt"
  value       = module.lab.node_ips
}

output "ansible_inventory" {
  description = "Skriv till ../../ansible/inventory/hosts.ini med terraform output -raw ansible_inventory"
  value       = module.lab.ansible_inventory
}
