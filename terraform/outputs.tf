output "server_ip" {
  description = "Public IPv4 address of the devbox server"
  value = var.provider_choice == "hetzner" ? (
    length(module.hetzner_devbox) > 0 ? module.hetzner_devbox[0].public_ip : ""
    ) : (
    length(module.digitalocean_devbox) > 0 ? module.digitalocean_devbox[0].public_ip : ""
  )
}

output "ssh_command" {
  description = "SSH connection command"
  value       = "ssh root@${var.provider_choice == "hetzner" ? (length(module.hetzner_devbox) > 0 ? module.hetzner_devbox[0].public_ip : "") : (length(module.digitalocean_devbox) > 0 ? module.digitalocean_devbox[0].public_ip : "")}"
}
