resource "null_resource" "download_iso" {
  connection {
    type        = "ssh"
    host        = var.remote_host
    user        = var.remote_user
    private_key = file("${var.remote_private_key}")
  }

  provisioner "remote-exec" {
    inline = [
      "wget ${var.iso_url} -O ${var.destination_path}/${var.destination_name}",
    ]
  }
}

# resource "null_resource" "remove_iso" {
#   connection {
#     type        = "ssh"
#     host        = var.remote_host
#     user        = var.remote_user
#     private_key = file("${var.remote_private_key}")
#   }
#
#   provisioner "remote-exec" {
#     when       = destroy
#     on_failure = continue
#
#     inline = [
#       "rm -f ${var.destination_path}/${var.destination_name}",
#     ]
#   }
# }
