terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

provider "oci" { region = var.region }
variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "public_key" { type = string }

# Persistent deployment access; contains no application data or billable resources.
resource "oci_identity_compartment" "deployments" {
  compartment_id = var.tenancy_ocid
  name           = "neu-zeit-deployments"
  description    = "Parent for NeuZeit demo environments"
  enable_delete  = true
}

resource "oci_identity_user" "github" {
  compartment_id = var.tenancy_ocid
  name           = "neu-zeit-github"
  description    = "GitHub Actions deployment identity"
}

resource "oci_identity_user_capabilities_management" "github" {
  user_id                      = oci_identity_user.github.id
  can_use_api_keys             = true
  can_use_console_password     = false
  can_use_auth_tokens          = false
  can_use_customer_secret_keys = false
  can_use_smtp_credentials     = false
}

resource "oci_identity_api_key" "github" {
  user_id   = oci_identity_user.github.id
  key_value = var.public_key
}

resource "oci_identity_group" "github" {
  compartment_id = var.tenancy_ocid
  name           = "neu-zeit-github"
  description    = "NeuZeit deployment operators"
}

resource "oci_identity_user_group_membership" "github" {
  user_id  = oci_identity_user.github.id
  group_id = oci_identity_group.github.id
}

resource "oci_identity_policy" "github" {
  compartment_id = var.tenancy_ocid
  name           = "neu-zeit-github"
  description    = "Demo management and account allocation inspection"
  statements = [
    "Allow group id ${oci_identity_group.github.id} to manage all-resources in compartment id ${oci_identity_compartment.deployments.id}",
    "Allow group id ${oci_identity_group.github.id} to manage dynamic-groups in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect tenancies in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect compartments in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect instance-family in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect volume-family in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect buckets in tenancy",
    "Allow group id ${oci_identity_group.github.id} to inspect objects in tenancy",
    "Allow group id ${oci_identity_group.github.id} to read objectstorage-namespaces in tenancy"
  ]
}

output "compartment_id" { value = oci_identity_compartment.deployments.id }
output "config" {
  value = "[DEFAULT]\nuser=${oci_identity_user.github.id}\nfingerprint=${oci_identity_api_key.github.fingerprint}\ntenancy=${var.tenancy_ocid}\nregion=${var.region}\n"
}
