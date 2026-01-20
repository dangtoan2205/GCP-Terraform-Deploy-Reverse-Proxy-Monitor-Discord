terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  keys_dir         = "${path.module}/keys"
  private_key_path = "${local.keys_dir}/${var.private_key_filename}"

  # If user provides ssh_public_key => use it; else use generated key
  effective_public_key = (
    var.ssh_public_key != null && trimspace(var.ssh_public_key) != ""
  ) ? trimspace(var.ssh_public_key) : tls_private_key.ssh_key[0].public_key_openssh

  ssh_metadata_value = "${var.ssh_username}:${local.effective_public_key}"

  # Reserve STATIC external IP only for instances that need public_ip + static_ip
  static_ip_instances = {
    for name, cfg in var.instances :
    name => cfg
    if cfg.public_ip && cfg.static_ip
  }
}

########################################
# SSH Key (only generate when ssh_public_key not provided)
########################################
resource "tls_private_key" "ssh_key" {
  count     = (var.ssh_public_key == null || trimspace(var.ssh_public_key) == "") ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

########################################
# Write private key to file (optional)
# NOTE: This writes private key into local filesystem and state contains the sensitive material.
########################################
resource "local_sensitive_file" "private_key" {
  count = var.write_private_key_file && (var.ssh_public_key == null || trimspace(var.ssh_public_key) == "") ? 1 : 0

  filename        = local.private_key_path
  content         = tls_private_key.ssh_key[0].private_key_pem
  file_permission = "0600"
}

########################################
# Optional: best-effort fix permissions (DO NOT BLOCK APPLY)
# Default: disabled to avoid Windows ACL issues and "Access is denied" on refresh/destroy
########################################
resource "null_resource" "keys_prepare_windows" {
  count      = var.write_private_key_file && var.enable_windows_key_acl_fix ? 1 : 0
  depends_on = [local_sensitive_file.private_key]

  triggers = {
    key_path = local.private_key_path
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    command = <<-EOT
      $ErrorActionPreference = "Continue"
      $dir = "${local.keys_dir}"
      $key = "${local.private_key_path}"

      if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

      if (!(Test-Path $key)) {
        Write-Warning "Private key not found: $key (skip ACL)"
        exit 0
      }

      try {
        # Remove inheritance (best-effort)
        icacls "$key" /inheritance:r | Out-Null

        # Remove common principals (ignore errors)
        icacls "$key" /remove:g "Users" "Authenticated Users" "BUILTIN\\Users" "Everyone" 2>$null | Out-Null

        # Grant current user read-only (use /grant for compatibility)
        icacls "$key" /grant "$env:USERNAME:R" | Out-Null

        Write-Host "ACL updated for: $key"
      } catch {
        Write-Warning ("ACL step failed but will not block apply: " + $_.Exception.Message)
        exit 0
      }
    EOT
  }
}

########################################
# Network
########################################
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
}

########################################
# Firewalls
########################################
resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_cidrs
  target_tags   = var.common_tags
}

resource "google_compute_firewall" "allow_web" {
  count   = var.enable_http_https ? 1 : 0
  name    = "${var.name_prefix}-allow-http-https"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.allowed_web_cidrs
  target_tags   = var.common_tags
}

########################################
# Static External IPs (reserve)
########################################
resource "google_compute_address" "vm_ip" {
  for_each = local.static_ip_instances

  name   = "${var.name_prefix}-${each.key}-static-ip"
  region = var.region
}

########################################
# VM Instances
########################################
resource "google_compute_instance" "vm" {
  for_each = var.instances

  name         = "${var.name_prefix}-${each.key}"
  machine_type = each.value.machine_type
  zone         = var.zone

  allow_stopping_for_update = true

  tags = distinct(concat(var.common_tags, each.value.tags))

  labels = merge(
    var.common_labels,
    try(each.value.labels, {})
  )

  boot_disk {
    initialize_params {
      image = try(each.value.image, null) != null ? each.value.image : var.default_image
      size  = each.value.disk_size
      type  = try(each.value.disk_type, "pd-balanced")
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id

    # Public IP: if enabled
    dynamic "access_config" {
      for_each = try(each.value.public_ip, true) ? [1] : []
      content {
        # If static_ip=true => use reserved address; else ephemeral
        nat_ip = try(each.value.static_ip, true) ? google_compute_address.vm_ip[each.key].address : null
      }
    }
  }

  # Startup script: per instance overrides common
  metadata_startup_script = (
    try(each.value.startup_script, null) != null && trimspace(each.value.startup_script) != ""
  ) ? each.value.startup_script : var.common_startup_script

  # Metadata merge: include ssh-keys + common + per-instance
  metadata = merge(
    var.common_metadata,
    try(each.value.metadata, {}),
    {
      "ssh-keys" = local.ssh_metadata_value
    }
  )

  # Optional service account per instance
  dynamic "service_account" {
    for_each = try(each.value.service_account, null) != null ? [each.value.service_account] : []
    content {
      email  = service_account.value.email
      scopes = service_account.value.scopes
    }
  }
}
