variable "provider_choice" {
  type        = string
  description = "Cloud provider to deploy to: 'hetzner' or 'digitalocean'"
  default     = "hetzner"

  validation {
    condition     = contains(["hetzner", "digitalocean"], var.provider_choice)
    error_message = "provider_choice must be 'hetzner' or 'digitalocean'."
  }
}

variable "hcloud_token" {
  type        = string
  description = "Hetzner Cloud API Token"
  sensitive   = true
  default     = ""
}

variable "digitalocean_token" {
  type        = string
  description = "DigitalOcean Personal Access Token"
  sensitive   = true
  default     = ""
}

variable "server_name" {
  type        = string
  description = "Hostname for the devbox server"
  default     = "buzzbox"
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key for server access"
}

variable "location" {
  type        = string
  description = "Datacenter location (Hetzner: nbg1, fsn1, hel1; DO: nyc1, fra1, etc.)"
  default     = "nbg1"
}

variable "server_type" {
  type        = string
  description = "Server instance type (Hetzner: cx33/cx43, nbg1 only; DO: s-2vcpu-4gb)"
  default     = "cx33"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (port 22). Defaults to the whole internet; narrow it to your own IP if you can."
  default     = ["0.0.0.0/0", "::/0"]
}
