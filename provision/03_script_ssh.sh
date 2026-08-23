#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Accept target username as an argument (defaults to 'root' if not provided)
USER_NAME="${1:-root}"

# Determine the home directory for the target user safely using getent
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
if [ -z "$USER_HOME" ]; then
    if [ "$USER_NAME" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME="/home/$USER_NAME"
    fi
fi

# Ensure the user's .ssh directory exists with the correct permissions
SSH_DIR="${USER_HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "${SSH_DIR}/authorized_keys"

# Define the insecure public keys[cite: 2]
RSA_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== $USER_NAME insecure public key"
ED25519_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y $USER_NAME insecure public key"

# Check if the RSA key exists before appending (Idempotency check)[cite: 2]
if ! grep -q -F "$RSA_KEY" "${SSH_DIR}/authorized_keys"; then
    echo "$RSA_KEY" >> "${SSH_DIR}/authorized_keys"
    echo "RSA key added to ${USER_NAME}'s authorized_keys."
else
    echo "RSA key already exists in ${USER_NAME}'s authorized_keys. Skipping."[cite: 2]
fi

# Check if the ED25519 key exists before appending (Idempotency check)[cite: 2]
if ! grep -q -F "$ED25519_KEY" "${SSH_DIR}/authorized_keys"; then
    echo "$ED25519_KEY" >> "${SSH_DIR}/authorized_keys"
    echo "ED25519 key added to ${USER_NAME}'s authorized_keys."
else
    echo "ED25519 key already exists in ${USER_NAME}'s authorized_keys. Skipping."[cite: 2]
fi

# Ensure the authorized_keys file and .ssh directory have the correct restrictive permissions and ownership
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${USER_NAME}:${USER_NAME}" "$SSH_DIR"

echo "SSH key provisioning complete for user: ${USER_NAME}."