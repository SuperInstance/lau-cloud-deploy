# Terraform variable definitions
# =============================================================================

variable "tenancy_ocid" {
  type      = string
  sensitive = true
}

variable "user_ocid" {
  type      = string
  sensitive = true
}

variable "fingerprint" {
  type      = string
  sensitive = true
}

variable "private_key_path" {
  type    = string
  default = "~/.oci/oci_api_key.pem"
}

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "compartment_ocid" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "instance_shapes" {
  description = "Map of instance configurations"
  type = map(object({
    shape       = string
    ocpus       = number
    memory_gbs  = number
    boot_size   = number
    gpu         = bool
  }))
  default = {
    arm_free = {
      shape      = "A1.Flex"
      ocpus      = 4
      memory_gbs = 24
      boot_size  = 50
      gpu        = false
    }
  }
}
