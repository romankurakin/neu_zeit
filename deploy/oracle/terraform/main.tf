terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

# Resource Manager supplies the job caller's credentials. No private keys enter state.
provider "oci" {
  region = var.region
}

variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "parent_compartment_id" { type = string }
variable "availability_domain" { type = string }
variable "application_image_id" { type = string }
variable "database_image_id" { type = string }
variable "namespace" { type = string }
variable "deployment_id" { type = string }

locals {
  name = "neu-zeit-${var.deployment_id}"
  tags = { "neu-zeit-deployment" = var.deployment_id }
}

resource "oci_identity_compartment" "demo" {
  compartment_id = var.parent_compartment_id
  name           = local.name
  description    = "NeuZeit Always Free demonstration environment"
  enable_delete  = true
  freeform_tags  = local.tags
}

resource "oci_objectstorage_bucket" "artifacts" {
  compartment_id = oci_identity_compartment.demo.id
  namespace      = var.namespace
  name           = "${local.name}-artifacts"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
  freeform_tags  = local.tags
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = oci_identity_compartment.demo.id
  namespace      = var.namespace
  name           = "${local.name}-backups"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"
  freeform_tags  = local.tags
}

resource "oci_identity_dynamic_group" "hosts" {
  compartment_id = var.tenancy_ocid
  name           = local.name
  description    = "Run Command and bucket access for NeuZeit hosts"
  matching_rule  = "ALL {instance.compartment.id = '${oci_identity_compartment.demo.id}'}"
  freeform_tags  = local.tags
}

resource "oci_identity_policy" "hosts" {
  compartment_id = oci_identity_compartment.demo.id
  name           = local.name
  description    = "Host identities; no OCI API keys on servers"
  statements = [
    "Allow dynamic-group id ${oci_identity_dynamic_group.hosts.id} to use instance-agent-command-execution-family in compartment id ${oci_identity_compartment.demo.id} where request.instance.id = target.instance.id",
    "Allow dynamic-group id ${oci_identity_dynamic_group.hosts.id} to read objects in compartment id ${oci_identity_compartment.demo.id} where target.bucket.name = '${oci_objectstorage_bucket.artifacts.name}'",
    "Allow dynamic-group id ${oci_identity_dynamic_group.hosts.id} to manage objects in compartment id ${oci_identity_compartment.demo.id} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'"
  ]
  freeform_tags = local.tags
}

resource "oci_core_vcn" "demo" {
  compartment_id = oci_identity_compartment.demo.id
  cidr_blocks    = ["10.42.0.0/23"]
  display_name   = local.name
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "demo" {
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_route_table" "demo" {
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  route_rules {
    network_entity_id = oci_core_internet_gateway.demo.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
  freeform_tags = local.tags
}

# Replaces the VCN default security list, which permits SSH.
resource "oci_core_security_list" "demo" {
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  freeform_tags = local.tags
}

resource "oci_core_subnet" "demo" {
  compartment_id    = oci_identity_compartment.demo.id
  vcn_id            = oci_core_vcn.demo.id
  cidr_block        = "10.42.0.0/24"
  route_table_id    = oci_core_route_table.demo.id
  security_list_ids = [oci_core_security_list.demo.id]
  freeform_tags     = local.tags
}

data "oci_core_services" "regional" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "console" {
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  services { service_id = one(data.oci_core_services.regional.services).id }
  freeform_tags = local.tags
}

resource "oci_core_route_table" "console" {
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  route_rules {
    network_entity_id = oci_core_service_gateway.console.id
    destination       = one(data.oci_core_services.regional.services).cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
  }
  freeform_tags = local.tags
}

resource "oci_core_subnet" "console" {
  compartment_id             = oci_identity_compartment.demo.id
  vcn_id                     = oci_core_vcn.demo.id
  cidr_block                 = "10.42.1.0/24"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.console.id
  security_list_ids          = [oci_core_security_list.demo.id]
  freeform_tags              = local.tags
}

resource "oci_bastion_bastion" "console" {
  bastion_type                 = "STANDARD"
  compartment_id               = oci_identity_compartment.demo.id
  target_subnet_id             = oci_core_subnet.console.id
  name                         = "neuzeit${var.deployment_id}"
  max_session_ttl_in_seconds   = 1800
  client_cidr_block_allow_list = ["127.0.0.1/32"]
  freeform_tags                = local.tags
  lifecycle {
    # The console command selects the caller's single public IP when opening a session.
    ignore_changes = [client_cidr_block_allow_list]
  }
}

resource "oci_core_network_security_group" "host" {
  for_each       = toset(["application", "database"])
  compartment_id = oci_identity_compartment.demo.id
  vcn_id         = oci_core_vcn.demo.id
  display_name   = "${local.name}-${each.key}"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "web" {
  for_each                  = toset(["80", "443"])
  network_security_group_id = oci_core_network_security_group.host["application"].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "database" {
  network_security_group_id = oci_core_network_security_group.host["database"].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.host["application"].id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "console" {
  for_each                  = toset(["application", "database"])
  network_security_group_id = oci_core_network_security_group.host[each.key].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${oci_bastion_bastion.console.private_endpoint_ip_address}/32"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_instance" "host" {
  for_each             = toset(["application", "database"])
  compartment_id       = oci_identity_compartment.demo.id
  availability_domain  = var.availability_domain
  display_name         = "${local.name}-${each.key}"
  shape                = each.key == "application" ? "VM.Standard.A1.Flex" : "VM.Standard.E2.1.Micro"
  preserve_boot_volume = false
  dynamic "shape_config" {
    for_each = each.key == "application" ? [1] : []
    content {
      ocpus         = 2
      memory_in_gbs = 12
    }
  }
  source_details {
    source_type             = "image"
    source_id               = each.key == "application" ? var.application_image_id : var.database_image_id
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.demo.id
    private_ip       = each.key == "application" ? "10.42.0.10" : "10.42.0.20"
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.host[each.key].id]
  }
  instance_options { are_legacy_imds_endpoints_disabled = true }
  agent_config {
    are_all_plugins_disabled = false
    plugins_config {
      name          = "Compute Instance Run Command"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }
  metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      bootstrap     = filebase64("${path.module}/bootstrap.sh")
      runtime       = base64gzip(file("${path.module}/host.py"))
      compose_app   = filebase64("${path.module}/compose.application.yaml")
      compose_db    = filebase64("${path.module}/compose.database.yaml")
      compose_proxy = filebase64("${path.module}/compose.proxy.yaml")
      config = base64encode(jsonencode({
        role       = each.key, region = var.region, namespace = var.namespace,
        artifacts  = oci_objectstorage_bucket.artifacts.name,
        backups    = oci_objectstorage_bucket.backups.name,
        bastion_ip = oci_bastion_bastion.console.private_endpoint_ip_address
      }))
    }))
  }
  freeform_tags = merge(local.tags, { "neu-zeit-role" = each.key })
  # IAM membership exists before the agent starts polling.
  depends_on = [oci_identity_policy.hosts]
}

output "compartment_id" { value = oci_identity_compartment.demo.id }
output "application_id" { value = oci_core_instance.host["application"].id }
output "database_id" { value = oci_core_instance.host["database"].id }
output "application_ip" { value = oci_core_instance.host["application"].public_ip }
output "artifacts" { value = oci_objectstorage_bucket.artifacts.name }
output "backups" { value = oci_objectstorage_bucket.backups.name }
output "namespace" { value = var.namespace }
output "bastion_id" { value = oci_bastion_bastion.console.id }
