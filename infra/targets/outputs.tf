output "virtual_network_id" {
  description = "Give this to the platform root as targets_virtual_network_id."
  value       = module.network.virtual_network_id
}

output "subnet_ids" {
  description = "Subnet resource IDs by subnet name."
  value       = module.network.subnet_ids
}

output "network_security_group_names" {
  description = "Security group names by subnet name."
  value       = module.network.network_security_group_names
}

output "peering_names" {
  description = "Names of the target side's peerings."
  value       = module.network.peering_names
}

output "vm_private_ips" {
  description = "Each target VM's address."
  value       = { for name, vm in local.vms : name => vm.address }
}
