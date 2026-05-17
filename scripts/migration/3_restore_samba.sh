#!/bin/bash
set -euo pipefail

###########################
# Load secrets from .env file
###########################

# Load environment variables and validate
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/env_loader.sh"; then
    exit 1
fi

SMB_CRED_FILE="/home/$USER/.smbcred"
SMB_CONF="/etc/samba/smb.conf"

###########################
# Create Samba configuration
###########################
echo "📂 Generating Samba configuration at $SMB_CONF..."
sudo mkdir -p /etc/samba

sudo tee "$SMB_CONF" >/dev/null <<EOF
[global]
client min protocol = SMB2
client max protocol = SMB3
vfs objects = catia fruit streams_xattr
fruit:metadata = stream
fruit:model = RackMac
fruit:posix_rename = yes
fruit:veto_appledouble = no
fruit:wipe_intentionally_left_blank_rfork = yes
fruit:delete_empty_adfiles = yes
security = user
encrypt passwords = yes
workgroup = WORKGROUP
server role = standalone server
obey pam restrictions = no
map to guest = never

[$USERNAME]
comment = Home Directories
browseable = yes
path = /home/$PICFRAME_USER
read only = no
create mask = 0775
directory mask = 0775
EOF

echo "✅ Samba configuration written to $SMB_CONF"

###########################
# Create system user
###########################
echo "👤 Ensuring system user '$USERNAME' exists..."
if ! id "$USERNAME" &>/dev/null; then
    sudo adduser --disabled-password --gecos "" --allow-bad-names "$USERNAME"
    echo "✅ System user '$USERNAME' created"
else
    echo "ℹ️ System user '$USERNAME' already exists"
fi

echo "🔗 Granting '$USERNAME' access to '$PICFRAME_USER' home directory..."
sudo usermod -aG "$PICFRAME_USER" "$USERNAME"
echo "✅ '$USERNAME' added to group '$PICFRAME_USER'"

###########################
# Add Samba user
###########################
echo "🔐 Creating Samba user '$USERNAME'..."
if sudo pdbedit -L | grep -q "^$USERNAME:"; then
    echo "ℹ️ Samba user '$USERNAME' already exists, skipping"
else
    echo -e "$PASSWORD\n$PASSWORD" | sudo smbpasswd -a "$USERNAME" -s
    sudo smbpasswd -e "$USERNAME"
    echo "✅ Samba user '$USERNAME' created and enabled"
fi

###########################
# Create SMB credentials file for mounting
###########################
echo "📄 Creating SMB credentials file at $SMB_CRED_FILE..."
cat > "$SMB_CRED_FILE" <<EOF
username=$SMB_CRED_USER
password=$SMB_CRED_PASS
EOF
chmod 600 "$SMB_CRED_FILE"
echo "✅ SMB credentials file created for user '$SMB_CRED_USER'"

###########################
# Restart Samba
###########################
echo "🔄 Restarting Samba services..."
if systemctl list-unit-files | grep -q '^nmbd\.service'; then
  sudo systemctl restart nmbd
fi
sudo systemctl restart smbd
echo "✅ Samba services restarted"

echo ""
echo "🎉 Samba configuration and user setup complete!"
echo "You can test the share with:"
echo "smbclient -L //localhost -U $USERNAME"