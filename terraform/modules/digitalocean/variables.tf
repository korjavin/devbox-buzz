variable "server_name" { type = string }
variable "ssh_public_key" { type = string }

variable "size" {
  type    = string
  default = "s-2vcpu-4gb"
}

variable "region" {
  type    = string
  default = "fra1"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (port 22). Defaults to the whole internet."
  default     = ["0.0.0.0/0", "::/0"]
}
