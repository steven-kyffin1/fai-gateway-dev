#!/bin/bash
# FAI Gateway Bootstrap Script v1.5 - Production Edition

echo "--- 🛰️ FAI GATEWAY STARTUP SEQUENCE ---"

# Check if script is run as root (required for systemd/hostname changes)
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run this script with sudo:"
  echo "sudo $0"
  exit 1
fi

# Determine the actual non-root user who invoked sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_HOMEDIR=$(eval echo ~$REAL_USER)

# 1. Hardware Diagnostics
# ... (Diagnostics code here) ...

# 2. Automatic Naming (MAC Identity Engine)
echo "[2/7] Setting Unique Identity via MAC..."
ETH_MAC=$(cat /sys/class/net/eth0/address | sed 's/://g')

if [ -z "$ETH_MAC" ]; then
    echo "ERROR: Could not find Ethernet MAC. Falling back to CPU Serial."
    ETH_MAC=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2 | tr -d '0')
fi

SHORT_ID=${ETH_MAC: -8}
NEW_HOSTNAME="fai-gw-$SHORT_ID"
CURRENT_HOSTNAME=$(hostname)

if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    echo "Renaming: $CURRENT_HOSTNAME -> $NEW_HOSTNAME"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    echo "Identity verified: $NEW_HOSTNAME"
fi

# 3. Update System
echo "[3/7] Updating System Packages..."
apt-get update && apt-get upgrade -y

# 4. Install Tailscale
echo "[4/7] Installing Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
else
    echo "Tailscale already installed."
fi

# 5. Install Docker & Compose
echo "[5/7] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker "$REAL_USER"
else
    echo "Docker already installed."
fi

# 6. MQTT & Project Folder Structure
echo "[6/7] Finalizing Project Folders & Environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Project Root detected at: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# Interactive Power Meter Selection for Assembly Tech
echo ""
echo "----------------------------------------"
echo "Select the Power Meter Type for this install:"
echo "1) GAVAZZI (Carlo Gavazzi EM330) [Default]"
echo "2) TIP_SINUS"
echo "----------------------------------------"
read -p "Enter 1 or 2 [Default: 1]: " METER_CHOICE

if [ "$METER_CHOICE" == "2" ]; then
    METER_TYPE="TIP_SINUS"
else
    METER_TYPE="GAVAZZI"
fi

FINAL_SERIAL=${GATEWAY_SERIAL:-$ETH_MAC}

echo "Writing environment variables to $PROJECT_ROOT/.env..."
cat <<EOF > .env
GATEWAY_SERIAL=$FINAL_SERIAL
GATEWAY_HOSTNAME=$NEW_HOSTNAME
POWER_METER_TYPE=$METER_TYPE
EOF

# Ensure the .env file belongs to the deployment user, not root
chown "$REAL_USER":"$REAL_USER" .env

# Permissions
chown -R 1883:1883 mosquitto/data mosquitto/log
chown -R 1000:1000 node-red-data
usermod -aG dialout "$REAL_USER"

# 7. Systemd Service & Persistence
echo "[7/7] Installing Systemd Service..."

if [ -f "./fai-gateway.service" ]; then
    cp ./fai-gateway.service /etc/systemd/system/fai-gateway.service
    
    # Fix working directory in systemd service to match this machine's actual folder
    sed -i "s|WorkingDirectory=.*|WorkingDirectory=$PROJECT_ROOT|g" /etc/systemd/system/fai-gateway.service
    
    systemctl daemon-reload
    systemctl enable fai-gateway.service
    echo "Persistence enabled."
else
    echo "ERROR: Could not find fai-gateway.service in $PROJECT_ROOT"
fi

# 8. SSD Setup
echo "[8/8] Configuring NVMe SSD for Store-and-Forward..."
MOUNT_POINT="/opt/fai-storage"
NVME_DRIVE="/dev/nvme0n1"

# Create the mount folder if it doesn't exist
mkdir -p $MOUNT_POINT

# Check if the drive is already formatted with ext4
if blkid $NVME_DRIVE | grep -q "ext4"; then
    echo "Drive $NVME_DRIVE is already formatted."
else
    echo "Formatting $NVME_DRIVE to ext4... (This wipes the drive!)"
    parted -s $NVME_DRIVE mklabel gpt
    parted -s $NVME_DRIVE mkpart primary ext4 0% 100%
    mkfs.ext4 -F ${NVME_DRIVE}p1
fi

# Add to /etc/fstab so it mounts automatically on every reboot
if ! grep -q "${NVME_DRIVE}p1" /etc/fstab; then
    echo "Adding drive to /etc/fstab for auto-mounting..."
    echo "${NVME_DRIVE}p1 $MOUNT_POINT ext4 defaults 0 2" | tee -a /etc/fstab
fi

# Mount it and assign ownership to the REAL deployment user
mount -a
chown -R $REAL_USER:$REAL_USER $MOUNT_POINT
echo "SSD configured and mounted at $MOUNT_POINT"

# 9. SuperCAP UPS Setup
echo "[9/9] Configuring I2C for SuperCAP UPS..."

# Install the I2C diagnostic tools
apt-get update
apt-get install -y i2c-tools python3-smbus

# Add the REAL user to the i2c hardware group
if groups $REAL_USER | grep &>/dev/null '\bi2c\b'; then
    echo "User $REAL_USER is already in the i2c group."
else
    echo "Adding $REAL_USER to the i2c group..."
    usermod -aG i2c $REAL_USER
fi

echo "I2C configured. (Note: group changes take effect on next login or reboot)"
echo ""
echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Gateway Serial: $FINAL_SERIAL"
echo "Meter Configured: $METER_TYPE"
echo "Environment: .env generated successfully."
echo ""
echo "Next Step: Run 'sudo reboot'"