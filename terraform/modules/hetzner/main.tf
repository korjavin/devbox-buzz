terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
    }
  }
}

resource "hcloud_ssh_key" "devbox_key" {
  name       = "${var.server_name}-key"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "devbox_firewall" {
  name = "${var.server_name}-firewall"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.allowed_ssh_cidrs
  }

  # HTTP & HTTPS
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # MOSH UDP range
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "60000-61000"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "devbox" {
  name         = var.server_name
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.devbox_key.id]
  firewall_ids = [hcloud_firewall.devbox_firewall.id]
}
