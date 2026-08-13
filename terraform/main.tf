module "hetzner_devbox" {
  count             = var.provider_choice == "hetzner" ? 1 : 0
  source            = "./modules/hetzner"
  server_name       = var.server_name
  server_type       = var.server_type
  location          = var.location
  ssh_public_key    = var.ssh_public_key
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
}

module "digitalocean_devbox" {
  count             = var.provider_choice == "digitalocean" ? 1 : 0
  source            = "./modules/digitalocean"
  server_name       = var.server_name
  size              = var.server_type
  region            = var.location
  ssh_public_key    = var.ssh_public_key
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
}
