#!/bin/bash

# Ensure the script is run with root privileges (Vagrant does this by default)
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Update the root user password to 'root'
echo "root:root" | chpasswd

# Update the vagrant user password to 'vagrant'
echo "vagrant:vagrant" | chpasswd

echo "Passwords for 'root' and 'vagrant' have been successfully updated."