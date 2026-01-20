output "vm_external_ips" {
  value = {
    for k, v in google_compute_instance.vm :
    k => try(v.network_interface[0].access_config[0].nat_ip, null)
  }
}

output "ssh_private_key_path" {
  description = "Path to PEM key if write_private_key_file=true and key is generated"
  value       = var.write_private_key_file ? "${path.module}/keys/${var.private_key_filename}" : null
}

output "ssh_examples" {
  value = {
    for k, v in google_compute_instance.vm :
    k => "ssh -i ${var.write_private_key_file ? "${path.module}/keys/${var.private_key_filename}" : "<your_key.pem>"} ${var.ssh_username}@${try(v.network_interface[0].access_config[0].nat_ip, "<no_public_ip>")}"
  }
}

output "private_key_path" {
  value       = local.private_key_path
  description = "Private key file path used for SSH"
}
