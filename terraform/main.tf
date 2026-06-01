# =============================================================================
# Oracle Cloud Infrastructure — Terraform Configuration
# Provisions: VCN, compute instances, GPU shapes, networking, OKE
# =============================================================================

# --- Backend configuration (uncomment for remote state) ---
# terraform {
#   backend "s3" {
#     bucket   = "lau-terraform-state"
#     key      = "oracle/terraform.tfstate"
#     region   = "us-ashburn-1"
#     endpoint = "https://<namespace>.compat.objectstorage.us-ashburn-1.oraclecloud.com"
#     shared_credentials_file = "~/.oci/s3_credentials"
#   }
# }

terraform {
  required_version = ">= 1.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider Configuration
# ---------------------------------------------------------------------------
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
  sensitive   = true
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
  sensitive   = true
}

variable "fingerprint" {
  description = "API key fingerprint"
  type        = string
  sensitive   = true
}

variable "private_key_path" {
  description = "Path to OCI API private key"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "us-ashburn-1"
}

variable "compartment_ocid" {
  description = "Compartment OCID for resources"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "vcn_cidr" {
  description = "VCN CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oracle_linux" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = "VM.Standard.E4.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------
# Networking — VCN, Subnets, Security Lists, Internet Gateway
# ---------------------------------------------------------------------------
resource "oci_core_vcn" "lau_vcn" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "lau-stack-vcn"
  dns_label      = "laustack"

  freeform_tags = {
    "Project"     = "SuperInstance"
    "Environment" = "production"
  }
}

resource "oci_core_internet_gateway" "lau_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lau_vcn.id
  display_name   = "lau-internet-gateway"
  enabled        = true
}

resource "oci_core_route_table" "lau_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lau_vcn.id
  display_name   = "lau-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.lau_igw.id
  }
}

resource "oci_core_security_list" "lau_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lau_vcn.id
  display_name   = "lau-security-list"

  # Allow SSH
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow HTTP
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Allow HTTPS
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow internal VCN traffic
  ingress_security_rules {
    protocol  = "all"
    source    = var.vcn_cidr
    stateless = false
  }

  # Allow all egress
  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    stateless        = false
  }
}

resource "oci_core_subnet" "lau_public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.lau_vcn.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "lau-public-subnet"
  dns_label         = "laupublic"
  route_table_id    = oci_core_route_table.lau_rt.id
  security_list_ids = [oci_core_security_list.lau_sl.id]
}

resource "oci_core_subnet" "lau_private" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.lau_vcn.id
  cidr_block        = "10.0.2.0/24"
  display_name      = "lau-private-subnet"
  dns_label         = "lauprivate"
  route_table_id    = oci_core_route_table.lau_rt.id
  security_list_ids = [oci_core_security_list.lau_sl.id]

  prohibit_public_ip_on_vnic = true
}

# ---------------------------------------------------------------------------
# Compute Instances
# ---------------------------------------------------------------------------

# Free Tier ARM Instance — A1.Flex
resource "oci_core_instance" "lau_arm_free" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "lau-arm-free"
  shape               = "A1.Flex"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.oracle_linux.images[0].id
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id    = oci_core_subnet.lau_public.id
    display_name = "lau-arm-vnic"
    hostname_label = "lau-arm"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(<<-EOF
      #!/bin/bash
      apt-get update && apt-get install -y docker.io
      systemctl enable docker && systemctl start docker
      docker pull lau-stack:cpu-arm64
    EOF
    )
  }

  freeform_tags = {
    "Project"     = "SuperInstance"
    "Environment" = "production"
    "Tier"        = "free"
    "Architecture" = "arm64"
  }
}

# GPU Instance — VM.GPU.A10.1 (uncomment to provision)
# resource "oci_core_instance" "lau_gpu" {
#   compartment_id      = var.compartment_ocid
#   availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
#   display_name        = "lau-gpu"
#   shape               = "VM.GPU.A10.1"
#
#   source_details {
#     source_type             = "image"
#     source_id               = data.oci_core_images.oracle_linux.images[0].id
#     boot_volume_size_in_gbs = 200
#   }
#
#   create_vnic_details {
#     subnet_id      = oci_core_subnet.lau_private.id
#     display_name   = "lau-gpu-vnic"
#     hostname_label = "lau-gpu"
#   }
#
#   metadata = {
#     ssh_authorized_keys = var.ssh_public_key
#   }
#
#   # GPU driver installation via cloud-init
#   metadata = {
#     ssh_authorized_keys = var.ssh_public_key
#     user_data = base64encode(<<-EOF
#       #!/bin/bash
#       # Install NVIDIA drivers and container toolkit
#       dnf install -y kernel-devel
#       curl -fsSL https://download.nvidia.com/opensource/Linux-x86_64/550.54.14/NVIDIA-Linux-x86_64-550.54.14.run -o /tmp/nvidia.run
#       sh /tmp/nvidia.run --silent
#       distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
#       curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.repo | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
#       dnf install -y nvidia-container-toolkit
#       systemctl restart docker
#     EOF
#     )
#   }
# }

# Bare Metal — BM.Standard.E4.128 (uncomment to provision)
# resource "oci_core_instance" "lau_baremetal" {
#   compartment_id      = var.compartment_ocid
#   availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
#   display_name        = "lau-baremetal"
#   shape               = "BM.Standard.E4.128"
#
#   source_details {
#     source_type             = "image"
#     source_id               = data.oci_core_images.oracle_linux.images[0].id
#     boot_volume_size_in_gbs = 500
#   }
#
#   create_vnic_details {
#     subnet_id      = oci_core_subnet.lau_private.id
#     display_name   = "lau-bm-vnic"
#     hostname_label = "lau-bm"
#   }
#
#   metadata = {
#     ssh_authorized_keys = var.ssh_public_key
#   }
# }

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "vcn_id" {
  value = oci_core_vcn.lau_vcn.id
}

output "public_subnet_id" {
  value = oci_core_subnet.lau_public.id
}

output "arm_instance_public_ip" {
  value = oci_core_instance.lau_arm_free.public_ip
}

output "arm_instance_id" {
  value = oci_core_instance.lau_arm_free.id
}
