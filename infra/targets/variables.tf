variable "name_prefix" {
  description = "Short prefix for resource names. Must match the bootstrap root."
  type        = string
  default     = "aisec"
}

variable "resource_group_name" {
  description = "Target resource group, created by the bootstrap root."
  type        = string
  default     = "rg-aisec-targets"
}

# The resource group and the state account stay in Denmark East, where the
# bootstrap root made them. Where a group's metadata lives has no effect on
# where its resources run (ADR 0020).
variable "location" {
  description = "Region of the target network."
  type        = string
  default     = "polandcentral"
}

variable "address_space" {
  description = "Target virtual network range."
  type        = string
  default     = "10.50.0.0/20"
}

variable "orchestrator_address_prefix" {
  description = "Platform orchestrator subnet. An agreed input, not read from the platform root's state."
  type        = string
  default     = "10.40.0.0/27"
}

variable "router_address_prefix" {
  description = "Mesh VPN router subnet in the edge network. An agreed input, not read from the platform root's state."
  type        = string
  default     = "10.45.0.32/27"
}

variable "platform_virtual_network_id" {
  description = "Resource ID of the platform virtual network. Leave null until the platform root has created it."
  type        = string
  default     = null
}

variable "edge_virtual_network_id" {
  description = "Resource ID of the edge virtual network. Leave null until the platform root has created it."
  type        = string
  default     = null
}
