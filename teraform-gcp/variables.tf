variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "zone" {
  type    = string
  default = "asia-southeast1-b"
}

variable "name_prefix" {
  type    = string
  default = "login-lab"
}

variable "vpc_name" {
  type    = string
  default = "lab-vpc"
}

variable "subnet_name" {
  type    = string
  default = "lab-subnet"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "default_image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

# Paste your own public key here to avoid generating/storing private key in TF
variable "ssh_public_key" {
  type    = string
  default = null
}

variable "write_private_key_file" {
  type    = bool
  default = true
}

variable "private_key_filename" {
  type    = string
  default = "id_rsa_lab.pem"
}

# IMPORTANT: default false to avoid Windows ACL issues and "Access is denied" on refresh/destroy
variable "enable_windows_key_acl_fix" {
  type    = bool
  default = false
}

variable "allowed_ssh_cidrs" {
  type    = list(string)
  # IMPORTANT: set to your PUBLIC IP /32 (not private IP 10.x.x.x)
  default = ["0.0.0.0/0"]
}

variable "enable_http_https" {
  type    = bool
  default = true
}

variable "allowed_web_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "common_tags" {
  type    = list(string)
  default = ["lab-node"]
}

variable "common_labels" {
  type    = map(string)
  default = {}
}

variable "common_metadata" {
  type    = map(string)
  default = {}
}

variable "common_startup_script" {
  type    = string
  default = null
}

variable "instances" {
  type = map(object({
    machine_type = string
    disk_size    = number
    tags         = list(string)

    # optional
    image      = optional(string)
    disk_type  = optional(string, "pd-balanced")

    public_ip  = optional(bool, true)
    static_ip  = optional(bool, true)

    labels   = optional(map(string), {})
    metadata = optional(map(string), {})

    startup_script = optional(string)

    service_account = optional(object({
      email  = string
      scopes = list(string)
    }))
  }))
}

