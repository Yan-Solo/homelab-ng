variable "iso_url" {
  type = string
}

variable "destination_path" {
  type = string
  default = "/var/lib/vz/template/iso/"
}

variable "destination_name" {
  type = string
}

variable "remote_user" {
  type = string
  default = "root"
}

variable "remote_private_key" {
  type = string
  default = "~/.ssh/id_rsa"
}

 variable "remote_host" {
  type = string
}
