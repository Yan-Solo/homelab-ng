resource "null_resource" "get_vm_ips_execute_script" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
      echo "" > script_get_vm_ips/output.txt &&
      scp script_get_vm_ips/get_ip_addresses.sh root@${var.hypervisor01_ip}:/root/get_ip_addresses.sh &&
      sleep 30 &&
      ssh root@${var.hypervisor01_ip} bash /root/get_ip_addresses.sh > script_get_vm_ips/output.txt
    EOT
  }
  depends_on = [ proxmox_vm_qemu.talos-master-01 ]
}

data "local_file" "get_vm_ips_script_output" {
  filename = "script_get_vm_ips/output.txt"
  depends_on = [ null_resource.get_vm_ips_execute_script ]
}

output "vm_ips" {
  value = data.local_file.get_vm_ips_script_output.content
  depends_on = [ data.local_file.get_vm_ips_script_output ]
}
