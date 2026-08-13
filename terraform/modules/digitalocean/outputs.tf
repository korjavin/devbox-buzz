output "public_ip" {
  value       = digitalocean_droplet.devbox.ipv4_address
  description = "Public IPv4 address of DigitalOcean Droplet"
}
