#!/bin/bash

# Accept the role and user name as arguments (defaults to 'default' and 'vagrant' if not provided)
SYSTEM_ROLE="${1:-default}"
USER_NAME="${2:-vagrant}"

# Determine the home directory for the target user safely
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
if [ -z "$USER_HOME" ]; then
    USER_HOME="/home/$USER_NAME"
fi

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

# Construct system name dynamically using USER_NAME instead of the hardcoded 'v' string
raw_systemname="v-${SYSTEM_ROLE}-${bc_distribution_id}${bc_release}${bc_codename}${kernel_version}"
bc_systemname=$(echo "$raw_systemname" | sed 's/\[.*//g' | tr -cd '[:alnum:]._-')

# Apply the system hostname cleanly
sudo hostnamectl set-hostname "${bc_systemname}"

# 2. Remove existing BABU CHANGES block from .bashrc if it exists
if [ -f "${USER_HOME}/.bashrc" ] && grep -q "# BABU CHANGES" "${USER_HOME}/.bashrc"; then
    # Use sed to delete lines starting from '# BABU CHANGES' up to '# END CHANGES' (inclusive)
    sed -i '/# BABU CHANGES/,/# END CHANGES/d' "${USER_HOME}/.bashrc"
fi

# 3. Append the fresh code block to .bashrc
cat << EOF >> "${USER_HOME}/.bashrc"

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

# Construct system name dynamically using USER_NAME instead of the hardcoded 'v' string
raw_systemname="$v-${SYSTEM_ROLE}-\${bc_distribution_id}\${bc_release}\${bc_codename}\${kernel_version}"
bc_systemname=\$(echo "\$raw_systemname" | sed 's/\[.*//g' | tr -cd '[:alnum:]._-')

# END CHANGES

if [ "\$color_prompt" = yes ]; then
    PS1='\${debian_chroot:+(\$debian_chroot)}\[\033[01;32m\]\u@\$bc_systemname\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\${debian_chroot:+(\$debian_chroot)}\u@\$bc_systemname:\w\$ '
fi
EOF

# Ensure proper ownership applied dynamically based on the passed username
chown ${USER_NAME}:${USER_NAME} "${USER_HOME}/.bashrc"