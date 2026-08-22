#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Ensure the root .ssh directory exists with the correct permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys

# Define the insecure public keys
RSA_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== root insecure public key"
ED25519_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y root insecure public key"

# Check if the RSA key exists before appending
if ! grep -q -F "$RSA_KEY" /root/.ssh/authorized_keys; then
    echo "$RSA_KEY" >> /root/.ssh/authorized_keys
    echo "RSA key added to root's authorized_keys."
else
    echo "RSA key already exists in root's authorized_keys. Skipping."
fi

# Check if the ED25519 key exists before appending
if ! grep -q -F "$ED25519_KEY" /root/.ssh/authorized_keys; then
    echo "$ED25519_KEY" >> /root/.ssh/authorized_keys
    echo "ED25519 key added to root's authorized_keys."
else
    echo "ED25519 key already exists in root's authorized_keys. Skipping."
fi

# Ensure the authorized_keys file has the correct restrictive permissions
chmod 600 /root/.ssh/authorized_keys

echo "Root SSH key provisioning complete."