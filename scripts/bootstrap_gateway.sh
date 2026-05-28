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

echo ""
echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Gateway Serial: $FINAL_SERIAL"
echo "Meter Configured: $METER_TYPE"
echo "Environment: .env generated successfully."
echo ""
echo "Next Step: Run 'sudo reboot'"