#!/bin/bash
# FAI Gateway Bootstrap Script v1.2
# Order: Hardware -> Identity -> OS -> Network -> Docker -> Config

echo "--- 🛰️ FAI GATEWAY STARTUP SEQUENCE ---"

# 1. Hardware Diagnostics
echo "[1/6] Checking Hardware..."
echo "Model: $(cat /proc/device-tree/model)"
echo "CPU Temp: $(vcgencmd measure_temp || echo 'Temp check failed')"
ls /dev/ttyUSB* /dev/ttyAMA* 2>/dev/null || echo "No serial devices found yet."

# 2. Automatic Naming (The Identity Engine)
echo "[2/6] Setting Unique Identity..."
CPUSERIAL=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2)
if [ -z "$CPUSERIAL" ] || [ "$CPUSERIAL" == "0000000000000000" ]; then 
    CPUSERIAL=$(cat /sys/firmware/devicetree/base/serial-number | tr -d '\0' || date +%s)
fi
SHORT_ID=${CPUSERIAL: -8}
NEW_HOSTNAME="fai-gw-$SHORT_ID"
CURRENT_HOSTNAME=$(hostname)

if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    echo "Renaming: $CURRENT_HOSTNAME -> $NEW_HOSTNAME"
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
    sudo sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    echo "Identity already verified: $NEW_HOSTNAME"
fi

# 3. Update System
echo "[3/6] Updating System Packages..."
sudo apt-get update && sudo apt-get upgrade -y

# 4. Install Tailscale (The Backdoor)
echo "[4/6] Installing Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
else
    echo "Tailscale already installed."
fi

# 5. Install Docker & Compose
echo "[5/6] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
else
    echo "Docker already installed."
fi

# 6. MQTT & Project Folder Structure
echo "[6/6] Finalizing Project Folders & MQTT Config..."
PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PARENT_DIR"

# Create folders
mkdir -p mosquitto/config mosquitto/data mosquitto/log node-red-data

# Write Mosquitto Config
cat <<EOF > mosquitto/config/mosquitto.conf
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
listener 1883 0.0.0.0
allow_anonymous true
EOF

echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Project Root: $PARENT_DIR"
echo "Next Step: Run 'sudo reboot' to apply hostname and Docker group changes."