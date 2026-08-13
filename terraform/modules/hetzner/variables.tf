variable "server_name" { type = string }
variable "ssh_public_key" { type = string }

variable "server_type" {
  type    = string
  default = "cx33"
}

variable "location" {
  type    = string
  default = "nbg1"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (port 22). Defaults to the whole internet."
  default     = ["0.0.0.0/0", "::/0"]
}
