output "public_ip" {
  value       = hcloud_server.devbox.ipv4_address
  description = "Public IPv4 address of Hetzner server"
}
