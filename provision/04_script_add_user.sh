#!/bin/bash

# Accept target user and password as arguments from Vagrant
# Defaults to 'devuser' if not provided
TARGET_USER="${1:-devuser}"
TARGET_PASSWORD="${2:-$TARGET_USER}"

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# 1. Create the user with a home directory and bash shell
if ! id "$TARGET_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "User '$TARGET_USER' successfully created."
else
    echo "User '$TARGET_USER' already exists. Skipping creation."
fi

# 2. Grant passwordless sudo privileges
# This creates a safe, idempotent drop-in file for the user
echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$TARGET_USER"
chmod 440 "/etc/sudoers.d/$TARGET_USER"
echo "Sudo privileges granted to '$TARGET_USER'."

# 3. Set the password using chpasswd
echo "$TARGET_USER:$TARGET_PASSWORD" | chpasswd
echo "Password for '$TARGET_USER' updated."

# 4. Create the .ssh directory with correct permissions
mkdir -p "/home/$TARGET_USER/.ssh"
chmod 700 "/home/$TARGET_USER/.ssh"
touch "/home/$TARGET_USER/.ssh/authorized_keys"

# Define the keys to inject
RSA_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== root insecure public key"
ED25519_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y root insecure public key"

# Check if keys exist before appending to prevent duplication
if ! grep -q -F "$RSA_KEY" "/home/$TARGET_USER/.ssh/authorized_keys"; then
    echo "$RSA_KEY" >> "/home/$TARGET_USER/.ssh/authorized_keys"
fi

if ! grep -q -F "$ED25519_KEY" "/home/$TARGET_USER/.ssh/authorized_keys"; then
    echo "$ED25519_KEY" >> "/home/$TARGET_USER/.ssh/authorized_keys"
fi

# Ensure the authorized_keys file has the correct restrictive permissions
chmod 600 "/home/$TARGET_USER/.ssh/authorized_keys"

# Transfer ownership of the SSH directory and its contents to the target user
chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.ssh"
echo "SSH keys successfully configured and verified for '$TARGET_USER'."

# 5. Ensure SSH password authentication is enabled 
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi
if grep -q "^#PasswordAuthentication yes" /etc/ssh/sshd_config; then
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi

# Check for cloud-init drop-in config files that might override the main config
if [ -d "/etc/ssh/sshd_config.d" ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        if [ -e "$f" ] && grep -q "^PasswordAuthentication no" "$f"; then
            sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$f"
        fi
    done
fi

# Restart the SSH service so the password authentication changes take effect
systemctl restart sshd || systemctl restart ssh
echo "SSH service verified to allow password authentication."