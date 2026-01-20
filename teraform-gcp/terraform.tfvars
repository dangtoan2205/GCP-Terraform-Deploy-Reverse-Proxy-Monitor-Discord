project_id  = "ubuntu-test-prod"
name_prefix = "login-lab"

# Dùng PUBLIC IP thật của bạn, ví dụ: "203.0.113.10/32"
# Bạn đang dùng 10.0.1.23/32 (private IP) => sẽ không SSH được từ internet
allowed_ssh_cidrs = ["0.0.0.0/0"]

common_labels = {
  env = "dev"
}

common_metadata = {
  enable-oslogin = "FALSE"
}

enable_windows_key_acl_fix = true

instances = {
  lab-test = {
    machine_type = "e2-standard-2"
    disk_size    = 100
    tags         = ["lab-node"]

    public_ip = true
    static_ip = true

    metadata = {
      owner = "team-a"
    }

    startup_script = <<-EOT
      #!/bin/bash
      set -e
      apt-get update -y
      apt-get install -y nginx
      systemctl enable --now nginx
    EOT
  }
}
