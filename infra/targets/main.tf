data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  subnet_prefixes = {
    netbox     = cidrsubnet(var.address_space, 7, 0) # 10.50.0.0/27
    consumer   = cidrsubnet(var.address_space, 7, 1) # 10.50.0.32/27
    unintended = cidrsubnet(var.address_space, 7, 2) # 10.50.0.64/27
    rehearsal  = cidrsubnet(var.address_space, 7, 8) # 10.50.1.0/27
  }
}

# The shared module, pinned to a commit of the platform repository (ADR 0024).
# A change to the module reaches the targets only when this pin moves. The
# commit is the platform's main when the router and the edge VM were added.
# It moves by hand, in a signed pull request.
module "network" {
  source = "git::https://github.com/sindredg/ai-security-platform.git//infra/modules/network?ref=77803d87fc99c62687b955bd46f7731fc497cc19"

  name                = "${var.name_prefix}-targets"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  address_space       = var.address_space

  # Every subnet starts closed. The only ways in are SSH from the orchestrator
  # and SSH from the mesh VPN router, which carries operator sessions.
  # Service ports arrive with the service that listens on them.
  #
  # The two outbound denies look redundant next to the deny-all baseline. They
  # are not. The baseline does not cover Azure DNS, and the internet deny has to
  # outrank any allow rule a later service adds.
  subnets = {
    for name, prefix in local.subnet_prefixes : name => {
      address_prefix = prefix
      rules = [
        {
          name                       = "allow-ssh-from-orchestrator"
          priority                   = 1000
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_address_prefix      = var.orchestrator_address_prefix
          destination_address_prefix = prefix
          destination_port_range     = "22"
          description                = "Administration through the orchestrator."
        },
        {
          name                       = "allow-ssh-from-router"
          priority                   = 1020
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_address_prefix      = var.router_address_prefix
          destination_address_prefix = prefix
          destination_port_range     = "22"
          description                = "Operator sessions through the mesh VPN router."
        },
        {
          name                       = "deny-to-internet"
          priority                   = 110
          direction                  = "Outbound"
          access                     = "Deny"
          protocol                   = "*"
          source_address_prefix      = "*"
          destination_address_prefix = "Internet"
          destination_port_range     = "*"
          description                = "Targets have no internet egress. The orchestrator pushes what they need."
        },
        {
          name                       = "deny-to-azure-dns"
          priority                   = 120
          direction                  = "Outbound"
          access                     = "Deny"
          protocol                   = "*"
          source_address_prefix      = "*"
          destination_address_prefix = "AzurePlatformDNS"
          destination_port_range     = "*"
          description                = "Azure DNS ignores every rule that does not name this tag, and a resolver is a way out."
        },
      ]
    }
  }

  # Peering is not transitive. The edge network needs its own, so that the
  # router's sessions reach the targets.
  peerings = merge(
    var.platform_virtual_network_id == null ? {} : {
      peer-targets-to-platform = { remote_virtual_network_id = var.platform_virtual_network_id }
    },
    var.edge_virtual_network_id == null ? {} : {
      peer-targets-to-edge = { remote_virtual_network_id = var.edge_virtual_network_id }
    },
  )

  tags = {
    project    = "ai-security-platform"
    side       = "targets"
    managed-by = "terraform-targets"
  }
}

# The module held one peering in a list. It holds a map of them now.
moved {
  from = module.network.azurerm_virtual_network_peering.this[0]
  to   = module.network.azurerm_virtual_network_peering.this["peer-targets-to-platform"]
}
