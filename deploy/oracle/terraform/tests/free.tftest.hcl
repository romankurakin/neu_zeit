mock_provider "oci" {
  mock_data "oci_core_services" {
    defaults = {
      services = [{ id = "ocid1.service.oc1.test", cidr_block = "all-ams-services-in-oracle-services-network", name = "All AMS Services In Oracle Services Network" }]
    }
  }
  mock_resource "oci_bastion_bastion" {
    defaults = { private_endpoint_ip_address = "10.42.1.5" }
  }
}

variables {
  region                = "eu-amsterdam-1"
  tenancy_ocid          = "ocid1.tenancy.oc1..test"
  parent_compartment_id = "ocid1.tenancy.oc1..test"
  availability_domain   = "test:EU-AMSTERDAM-1-AD-1"
  image_id              = "ocid1.image.oc1.eu-amsterdam-1.amd"
  namespace             = "test"
  deployment_id         = "test"
}

run "free_resources_and_private_ssh" {
  command = apply
  assert {
    condition     = oci_bastion_bastion.console.max_session_ttl_in_seconds == 1800 && oci_core_subnet.console.prohibit_public_ip_on_vnic && alltrue([for rule in oci_core_network_security_group_security_rule.console : rule.source == "10.42.1.5/32" && rule.tcp_options[0].destination_port_range[0].min == 22])
    error_message = "Interactive access must expire after 30 minutes and accept only the private Bastion endpoint."
  }
  assert {
    condition     = alltrue([for host in oci_core_instance.host : length(jsonencode(host.metadata)) < 32000])
    error_message = "Bootstrap metadata must fit OCI's 32,000-byte limit."
  }
  assert {
    condition     = alltrue([for host in oci_core_instance.host : host.shape == "VM.Standard.E2.1.Micro"])
    error_message = "Both hosts must use Always Free Micro instances."
  }
  assert {
    condition     = alltrue([for host in oci_core_instance.host : tonumber(host.source_details[0].boot_volume_size_in_gbs) == 50 && !host.preserve_boot_volume && !contains(keys(host.metadata), "ssh_authorized_keys")])
    error_message = "Disks must stay at 50 GB, be removed on undeploy, and have no SSH keys."
  }
  assert {
    condition     = length(oci_core_security_list.demo.ingress_security_rules) == 0 && toset(keys(oci_core_network_security_group_security_rule.web)) == toset(["80", "443"])
    error_message = "Public ingress must allow only HTTP/HTTPS."
  }
  assert {
    condition     = oci_core_network_security_group_security_rule.database.source_type == "NETWORK_SECURITY_GROUP" && oci_core_network_security_group_security_rule.database.tcp_options[0].destination_port_range[0].min == 5432
    error_message = "PostgreSQL must accept only the application security group."
  }
  assert {
    condition     = oci_objectstorage_bucket.artifacts.access_type == "NoPublicAccess" && oci_objectstorage_bucket.backups.access_type == "NoPublicAccess"
    error_message = "Sources, credentials and backups must remain private."
  }
}
