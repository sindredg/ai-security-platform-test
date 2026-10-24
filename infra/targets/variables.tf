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

variable "orchestrator_ip" {
  description = "The orchestrator's address. The update key logs in only from it (ADR 0036). An agreed input, not read from the platform root's state."
  type        = string
  default     = "10.40.0.4"
}

variable "zone" {
  description = "Availability zone for both VMs. Zones 1 and 2 are restricted for this size in Poland Central."
  type        = string
  default     = "3"
}

variable "vm_size" {
  description = "VM size for both target VMs. x64, 8 GB. Two of them fill the region's 4 vCPUs."
  type        = string
  default     = "Standard_B2as_v2"
}

# az vm image list can name versions the region does not serve yet. Take the
# newest one that az vm image show finds in Poland Central.
variable "image_version" {
  description = "Ubuntu 26.04 LTS image version of both VMs."
  type        = string
  default     = "26.04.202610210"
}

variable "admin_username" {
  description = "Administrator account on both VMs. Certificate authentication only (ADR 0022)."
  type        = string
  default     = "aisec"
}

variable "operator_ssh_public_key" {
  description = "The operator's SSH public key, in OpenSSH format. Azure requires one. First boot removes it: the administrator account takes only a certificate (ADR 0022)."
  type        = string
}

variable "operator_user_ca_public_key" {
  description = "Public half of the operator's SSH certificate authority, in OpenSSH format (ADR 0022). The same key as the platform's."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [A-Za-z0-9@._-]+)?$", var.operator_user_ca_public_key))
    error_message = "One Ed25519 public key on one line, in OpenSSH format."
  }
}

variable "update_public_key" {
  description = "Public half of the orchestrator's update key (ADR 0036). It logs in to aisec-update, whose only command is the update. The private half stays on the orchestrator."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [A-Za-z0-9@._-]+)?$", var.update_public_key))
    error_message = "One Ed25519 public key on one line, in OpenSSH format."
  }
}
