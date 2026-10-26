locals {
  # Fixed addresses, as on the platform side. The targets have no DNS.
  netbox_ip    = cidrhost(local.subnet_prefixes.netbox, 4)    # 10.50.0.4
  lab_ip       = cidrhost(local.subnet_prefixes.consumer, 4)  # 10.50.0.36
  rehearsal_ip = cidrhost(local.subnet_prefixes.rehearsal, 4) # 10.50.1.4

  # NetBox's database and cache come from the Ubuntu archive, and Podman runs
  # its image (ADR 0035). The lab VM runs the rehearsal copy, a second NetBox
  # with its own interface in the rehearsal subnet (platform ADR 0044), so it
  # gets the same packages.
  vms = {
    netbox = {
      subnet    = "netbox"
      address   = local.netbox_ip
      disk_gb   = 30
      packages  = "podman postgresql-18 valkey-server"
      rehearsal = ""
    }
    lab = {
      subnet    = "consumer"
      address   = local.lab_ip
      disk_gb   = 30
      packages  = "podman postgresql-18 valkey-server"
      rehearsal = local.rehearsal_ip
    }
  }

  tags = {
    project    = "ai-security-platform"
    side       = "targets"
    managed-by = "terraform-targets"
  }
}

# Trivy wants a security group on the interface. Every subnet has its own,
# ending in a deny-all, and one place for the rules is easier to audit than two.
#trivy:ignore:AZU-0068
resource "azurerm_network_interface" "vm" {
  for_each = local.vms

  name                = "nic-${var.name_prefix}-${each.key}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  # No public address, and no IP forwarding. The policy from the bootstrap
  # root refuses a public address on this side anyway.
  ip_configuration {
    name                          = "primary"
    subnet_id                     = module.network.subnet_ids[each.value.subnet]
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.address
  }
}

# The lab VM's second interface, for the rehearsal copy alone. The first
# interface stays the primary one, so the lab VM's own traffic and its route to
# the orchestrator are unchanged.
#trivy:ignore:AZU-0068
resource "azurerm_network_interface" "rehearsal" {
  name                = "nic-${var.name_prefix}-lab-rehearsal"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = module.network.subnet_ids["rehearsal"]
    private_ip_address_allocation = "Static"
    private_ip_address            = local.rehearsal_ip
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  #checkov:skip=CKV_AZURE_50:The VM agent runs extensions for run-command, which is the way in when the mesh VPN is down
  for_each = local.vms

  name                = "vm-${var.name_prefix}-${each.key}"
  computer_name       = "${var.name_prefix}-${each.key}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  zone                = var.zone
  size                = var.vm_size
  tags                = local.tags

  network_interface_ids = concat(
    [azurerm_network_interface.vm[each.key].id],
    each.value.rehearsal == "" ? [] : [azurerm_network_interface.rehearsal.id],
  )

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.operator_ssh_public_key
  }

  secure_boot_enabled = true
  vtpm_enabled        = true

  os_disk {
    name                 = "osdisk-${var.name_prefix}-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-26_04-lts"
    sku       = "server"
    version   = var.image_version
  }

  # The serial console and its boot log, on managed storage. With run-command,
  # this is the way in when the router is down.
  boot_diagnostics {}

  custom_data = base64encode(templatefile("${path.module}/cloud-init/target.yaml.tftpl", {
    admin_username              = var.admin_username
    operator_user_ca_public_key = var.operator_user_ca_public_key
    orchestrator_ip             = var.orchestrator_ip
    update_public_key           = var.update_public_key
    packages                    = each.value.packages
    rehearsal_address           = each.value.rehearsal
    rehearsal_prefix            = local.subnet_prefixes.rehearsal
    rehearsal_gateway           = cidrhost(local.subnet_prefixes.rehearsal, 1)
    first_boot                  = filebase64("${path.module}/../../host/aisec-first-boot")
    update_command              = filebase64("${path.module}/../../host/aisec-target-update")
  }))

  # Custom data only runs on first boot. The targets are rebuilt for each
  # exercise, and a changed template takes effect then.
  lifecycle {
    ignore_changes = [custom_data, admin_ssh_key]
  }
}
