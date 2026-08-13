terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
    }
  }
}

resource "digitalocean_ssh_key" "devbox_key" {
  name       = "${var.server_name}-key"
  public_key = var.ssh_public_key
}

resource "digitalocean_droplet" "devbox" {
  image    = "ubuntu-24-04-x64"
  name     = var.server_name
  region   = var.region
  size     = var.size
  ssh_keys = [digitalocean_ssh_key.devbox_key.fingerprint]
}

resource "digitalocean_firewall" "devbox_firewall" {
  name        = "${var.server_name}-firewall"
  droplet_ids = [digitalocean_droplet.devbox.id]

  # SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.allowed_ssh_cidrs
  }

  # HTTP & HTTPS
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # MOSH UDP range
  inbound_rule {
    protocol         = "udp"
    port_range       = "60000-61000"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # DO firewalls deny all egress unless outbound rules are present; keep it open
  # so apt, docker pull and Let's Encrypt keep working.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
