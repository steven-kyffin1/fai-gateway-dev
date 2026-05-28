#!/bin/bash
# FAI Gateway Bootstrap Script v1.4 - Production Edition

echo "--- 🛰️ FAI GATEWAY STARTUP SEQUENCE ---"

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
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
    sudo sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    echo "Identity verified: $NEW_HOSTNAME"
fi

# 3. Update System
echo "[3/7] Updating System Packages..."
sudo apt-get update && sudo apt-get upgrade -y

# 4. Install Tailscale (The Backdoor)
echo "[4/7] Installing Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
else
    echo "Tailscale already installed."
fi

# 5. Install Docker & Compose
echo "[5/7] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
else
    echo "Docker already installed."
fi

# 6. MQTT & Project Folder Structure
echo "[6/7] Finalizing Project Folders & Environment..."

# NEW LOGIC: Identify the script directory AND the project root (one level up)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Project Root detected at: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# Now all paths are relative to the root, not the scripts folder!
FINAL_SERIAL=${GATEWAY_SERIAL:-$ETH_MAC}

echo "Writing environment variables to $PROJECT_ROOT/.env..."
cat <<EOF > .env
GATEWAY_SERIAL=$FINAL_SERIAL
GATEWAY_HOSTNAME=$NEW_HOSTNAME
EOF

# Permissions (Paths are now correct because we are in PROJECT_ROOT)
sudo chown -R 1883:1883 mosquitto/data mosquitto/log
sudo chown -R 1000:1000 node-red-data
sudo usermod -aG dialout $USER

# 7. Systemd Service & Persistence
echo "[7/7] Installing Systemd Service..."

# Look for the service file in the PROJECT_ROOT
if [ -f "./fai-gateway.service" ]; then
    sudo cp ./fai-gateway.service /etc/systemd/system/fai-gateway.service
    sudo systemctl daemon-reload
    sudo systemctl enable fai-gateway.service
    echo "Persistence enabled."
else
    echo "ERROR: Could not find fai-gateway.service in $PROJECT_ROOT"
fi

echo ""
echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Gateway Serial: $FINAL_SERIAL"
echo "Environment: .env generated successfully."
echo ""
echo "Next Step: Run 'sudo reboot'"
echo "The gateway stack will start automatically once the system is back up."