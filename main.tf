# Configure the Microsoft Azure Provider.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0.2" //azure version
    }
  }

  required_version = ">= 1.2.7" //terraform version
}

provider "azurerm" {
  features {
  }
}

# Create azure resource group
resource "azurerm_resource_group" "recursos" {
  name     = var.resource_group_name
  location = var.location
}
# Create virtual network for the VM
resource "azurerm_virtual_network" "Borokotroko" {
  name                = var.virtual_network_name
  location            = var.location
  address_space       = var.address_space
  resource_group_name = azurerm_resource_group.recursos.name
}


# Create subnet to the virtual network
resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}_subnet"
  virtual_network_name = azurerm_virtual_network.Borokotroko.name
  resource_group_name  = azurerm_resource_group.recursos.name
  address_prefixes     = var.subnet_prefix
}

# Create public ip
resource "azurerm_public_ip" "pip_terraform" {
  name                = "${var.prefix}-ip"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name
  allocation_method   = "Dynamic"
  domain_name_label   = var.hostname
}

# Create Network security group
resource "azurerm_network_security_group" "terraform_sg" {
  name                = "${var.prefix}-sg"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name

  security_rule {
    name                       = "HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create Network interface
resource "azurerm_network_interface" "terraform_nic" {
  name                = "${var.prefix}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name

  ip_configuration {
    name                          = "${var.prefix}-ipconfig"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip_terraform.id
  }
}


#create public loadbalancer

resource "azurerm_public_ip" "PublicIPforLB" {
  name                = "PublicIPforLB"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name
  allocation_method   = "Static"
}
resource "azurerm_lb" "BK-LoadBalancer" {
  name                = "BK-LoadBalancer"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name

  frontend_ip_configuration {
    name                 = "FrontenedIP-Loadbalancer"
    public_ip_address_id = azurerm_public_ip.PublicIPforLB.id
  }
}

resource "azurerm_lb_backend_address_pool" "BackendPool-LB" {
  name            = "BackendPool-LB"
  loadbalancer_id = azurerm_lb.BK-LoadBalancer.id
}

resource "azurerm_lb_probe" "LB-Probe" {
  loadbalancer_id     = azurerm_lb.BK-LoadBalancer.id
  name                = "LB-Probe"
  port                = 80
  protocol            = "Tcp"
  interval_in_seconds = 5
  number_of_probes    = 2

}

resource "azurerm_lb_rule" "LBRule" {
  loadbalancer_id                = azurerm_lb.BK-LoadBalancer.id
  name                           = "LBRule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "FrontenedIP-Loadbalancer"
  probe_id                       = azurerm_lb_probe.LB-Probe.id
}

# Private key for Linux VM
resource "tls_private_key" "linux_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save the private key to our machine
# Then use this key to connect to our Linux VM
resource "local_file" "linuxkey" {
  filename = "linuxkey.pem"
  content  = tls_private_key.linux_key.private_key_pem
}

# Create Linux VM
resource "azurerm_linux_virtual_machine" "danykarma-vm" {
  name                = "${var.hostname}-vm"
  location            = var.location
  resource_group_name = azurerm_resource_group.recursos.name
  size                = var.vm_size
  custom_data         = filebase64("customdata.sh")

  network_interface_ids = ["${azurerm_network_interface.terraform_nic.id}"]

  computer_name                   = var.hostname
  admin_username                  = var.admin_username
  # admin_password                  = var.admin_password
  # disable_password_authentication = false

  admin_ssh_key {
    username = var.admin_username
    public_key = tls_private_key.linux_key.public_key_openssh
  }

  os_disk {
    name                 = "${var.hostname}_osdisk"
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  depends_on = [
    tls_private_key.linux_key
  ]
}

#creating azure recovery services vault
resource "azurerm_recovery_services_vault" "tfBK-recovery-vault" {
  name                = "tfBK-recovery-vault"
  location            = azurerm_resource_group.recursos.location
  resource_group_name = azurerm_resource_group.recursos.name
  sku                 = "Standard"
}

resource "azurerm_backup_policy_vm" "tfBK-recovery-vault-policy" {
  name                = "tfBK-recovery-vault-policy"
  resource_group_name = azurerm_resource_group.recursos.name
  recovery_vault_name = azurerm_recovery_services_vault.tfBK-recovery-vault.name

  backup {
    frequency = "Daily"
    time      = "23:00"
  }

  retention_daily {
    count = 7
  }
}

data "azurerm_virtual_machine" "danykarma-vm" {
  name                = azurerm_linux_virtual_machine.danykarma-vm.name
  resource_group_name = azurerm_resource_group.recursos.name
}

#creating a backup for a vm
resource "azurerm_backup_protected_vm" "danykarma-vm" {
  resource_group_name = azurerm_resource_group.recursos.name
  recovery_vault_name = azurerm_recovery_services_vault.tfBK-recovery-vault.name
  source_vm_id        = data.azurerm_virtual_machine.danykarma-vm.id
  backup_policy_id    = azurerm_backup_policy_vm.tfBK-recovery-vault-policy.id
}
