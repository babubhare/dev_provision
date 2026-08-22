#!/bin/bash

# Accept the role as an argument from Vagrant (defaults to 'lpic' if not provided)
SYSTEM_ROLE="${1:-lpic}"

# 1. Calculate variables
kernel_version=$(uname -r)
temp=$(lsb_release -i)
count=${#temp}
bc_distribution_id=$(lsb_release -i | cut -c 17-$count)
temp=$(lsb_release -i)
count=${#temp}
bc_release=$(lsb_release -r | cut -c 10-$count)
temp=$(lsb_release -i)
count=${#temp}
bc_codename=$(lsb_release -c | cut -c 11-$count)

# Construct system name dynamically and strip out any unwanted bracket characters or metadata
raw_systemname="v-${SYSTEM_ROLE}-${bc_distribution_id}${bc_release}${bc_codename}${kernel_version}"
bc_systemname=$(echo "$raw_systemname" | sed 's/\[.*//g' | tr -cd '[:alnum:]._-')

# Apply the system hostname cleanly
sudo hostnamectl set-hostname "${bc_systemname}"
# Apply the system hostname
sudo hostnamectl set-hostname "${bc_systemname}"

# Export system name to shared directory for host reading
echo "${bc_systemname}" > /vagrant/system_name.txt

# 2. Remove existing BABU CHANGES block from .bashrc if it exists
if grep -q "# BABU CHANGES" /home/vagrant/.bashrc; then
    # Use sed to delete lines starting from '# BABU CHANGES' up to '# END CHANGES' (inclusive)
    sed -i '/# BABU CHANGES/,/# END CHANGES/d' /home/vagrant/.bashrc
    # Also clean up any lingering trailing PS1 block associated with it if needed, or let the block handle it below
fi

# 3. Append the fresh code block to .bashrc
cat << EOF >> /home/vagrant/.bashrc

# BABU CHANGES
kernel_version=\$(uname -r)
temp=\$(lsb_release -i)
count=\${#temp}
bc_distribution_id=\$(lsb_release -i | cut -c 17-\$count)
temp=\$(lsb_release -i)
count=\${#temp}
bc_release=\$(lsb_release -r | cut -c 10-\$count)
temp=\$(lsb_release -i)
count=\${#temp}
bc_codename=\$(lsb_release -c | cut -c 11-\$count)

# Construct system name dynamically and strip out any unwanted bracket characters or metadata
raw_systemname="v-${SYSTEM_ROLE}-${bc_distribution_id}${bc_release}${bc_codename}${kernel_version}"
bc_systemname=$(echo "$raw_systemname" | sed 's/\[.*//g' | tr -cd '[:alnum:]._-')

# END CHANGES

if [ "\$color_prompt" = yes ]; then
    PS1='\${debian_chroot:+(\$debian_chroot)}\[\033[01;32m\]\u@\$bc_systemname\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\${debian_chroot:+(\$debian_chroot)}\u@\$bc_systemname:\w\$ '
fi
EOF

# Ensure proper ownership
chown vagrant:vagrant /home/vagrant/.bashrc
chown vagrant:vagrant /vagrant/system_name.txt 2>/dev/null || true