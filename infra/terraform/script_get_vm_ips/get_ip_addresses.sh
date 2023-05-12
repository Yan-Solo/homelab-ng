#!/bin/bash

# Check if arp-scan is installed and install it if necessary
pkg="arp-scan"
if ! dpkg-query -W --showformat='${db:Status-Status}' "$pkg" 2>&1 | grep -q "installed"; then
  apt install "$pkg" > /dev/null
fi

# Get MAC addresses from configuration files
mac_addresses=$(grep -hR "net0:" /etc/pve/qemu-server/* | awk -F= '{ print $2 }' | awk -F, '{ print $1 }')

# Variables for storing output
id_plus_ip=""
output=""

# Iterate over MAC addresses
for mac_address in $mac_addresses; do
    # Get IP address and VM ID
    ip_address=$(arp-scan -q -l --interface vmbr0 | grep -i "$mac_address" | awk '{ print $1 }')
    vm_id=$(grep -rnw /etc/pve/qemu-server -e "$mac_address" | awk -F: '{ print $1 }' | awk -F/ '{ print $NF}' | awk -F. '{ print $1 }')
    
    # Append VM ID and IP address to the output
    id_plus_ip+="\"${vm_id}\": \"${ip_address}\", "
done

# Remove trailing comma and spaces from the output
output=$(echo "$id_plus_ip" | sed 's/\(.*\),/\1/')

# Print the formatted output
echo "{ $output }"
