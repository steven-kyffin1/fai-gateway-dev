#!/bin/bash
# FAI Gateway Bootstrap Script v2.1 - Production Zero-Touch Edition

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
echo "[2/10] Setting Unique Identity via MAC..."
RAW_MAC=$(cat /sys/class/net/eth0/address | sed 's/://g')

if [ -z "$RAW_MAC" ]; then
    RAW_MAC=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2 | tr -d '0')
fi

# Zero-pad the 12-char MAC to reach the 16-char EUI requirement
ETH_MAC="0000$RAW_MAC"

# Generate hostname from the final eight characters of the Ethernet MAC
NEW_HOSTNAME="fai-gw-${RAW_MAC: -8}"

echo "Setting hostname to: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# 3. Update System
echo "[3/10] Updating System Packages..."
apt-get update && apt-get upgrade -y

# Destroy default Linux drivers that hijack the RS485 and USB radios
echo "Banning ModemManager and BRLTTY..."
systemctl stop ModemManager || true
systemctl disable ModemManager || true
apt-get remove --purge brltty -y || true

# 4. Install Tailscale
echo "[4/10] Installing Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
else
    echo "Tailscale already installed."
fi

# 5. Install Docker & Compose
echo "[5/10] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker "$REAL_USER"
else
    echo "Docker already installed."
fi

# 6. MQTT, LoRaWAN & Project Folder Structure
echo "[6/10] Finalizing Project Folders & Environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Project Root detected at: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# Interactive Power Meter Selection
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

# Interactive LoRaWAN Selection
echo ""
echo "----------------------------------------"
echo "Does this gateway have a LoRaWAN Module installed?"
echo "1) YES"
echo "2) NO [Default]"
echo "----------------------------------------"
read -p "Enter 1 or 2 [Default: 2]: " LORA_CHOICE

if [ "$LORA_CHOICE" == "1" ]; then
    ACTIVE_PROFILES="lorawan"
    echo "LoRaWAN Stack ENABLED."
else
    ACTIVE_PROFILES=""
    echo "LoRaWAN Stack DISABLED."
fi

FINAL_SERIAL=${GATEWAY_SERIAL:-$ETH_MAC}

echo "Writing environment variables to $PROJECT_ROOT/.env..."
cat <<EOF > .env
GATEWAY_SERIAL=$FINAL_SERIAL
GATEWAY_HOSTNAME=$NEW_HOSTNAME
POWER_METER_TYPE=$METER_TYPE
COMPOSE_PROFILES=$ACTIVE_PROFILES
EMC_TEST_MODE=false
NODE_RED_HEALTH_STALE_SECONDS=25
NODE_RED_HEALTH_STARTUP_GRACE_SECONDS=30
RECOVERY_STARTUP_GRACE_SECONDS=30
RECOVERY_DATA_STALE_SECONDS=10
RECOVERY_NODERED_RESTART_SECONDS=18
RECOVERY_USB_RESET_SECONDS=30
RECOVERY_ACTION_COOLDOWN_SECONDS=60
ALLOW_HOST_REBOOT=false
EMC_RF_DWELL_SECONDS=3
EMC_TINYMESH_STALE_SECONDS=10
EMC_WMBUS_STALE_SECONDS=6
EMC_POWER_STALE_SECONDS=3
EMC_SILO_STALE_SECONDS=3
EMC_MONITOR_REQUIRED_FLOWS=tinymesh,wmbus,power,silo1,silo2
AUDIOMOTH_ENABLED=true
AUDIOMOTH_TEST_MODE=false
AUDIOMOTH_ALSA_DEVICE=plughw:CARD=AudioMoth,DEV=0
AUDIOMOTH_SAMPLE_RATE=48000
AUDIOMOTH_CHANNELS=1
AUDIOMOTH_FORMAT=S16_LE
AUDIOMOTH_RECORD_SECONDS=30
AUDIOMOTH_INTERVAL_SECONDS=300
EOF

chown "$REAL_USER":"$REAL_USER" .env

# Permissions
chown -R 1883:1883 mosquitto/data mosquitto/log
chown -R 1000:1000 node-red-data
usermod -aG dialout "$REAL_USER"

# Generate Secure Mosquitto Cloud Bridge
echo "Generating Secure Mosquitto Cloud Bridge..."
mkdir -p mosquitto/config/conf.d

cat <<EOF > mosquitto/config/mosquitto.conf
# ==========================================
# 1. LOCAL EDGE SETTINGS (The "Store")
# ==========================================
persistence true
persistence_location /mosquitto/data/
autosave_interval 30
log_dest stdout
listener 1883 0.0.0.0
allow_anonymous true
include_dir /mosquitto/config/conf.d
EOF

cat <<EOF > mosquitto/config/conf.d/bridge.conf
connection cloud-backend-bridge
address mqtt.birdbox.faifarms.com:8883
remote_clientid ${FINAL_SERIAL}
remote_username ${FINAL_SERIAL}
bridge_protocol_version mqttv311
bridge_cafile /etc/ssl/certs/ca-certificates.crt
bridge_insecure true
cleansession false
try_private false
topic gateway/${FINAL_SERIAL}/# out 1 "" ""
EOF

# Scaffold ChirpStack Offline Server
echo "Scaffolding Private LoRaWAN Network Server..."
mkdir -p chirpstack/configuration/chirpstack
mkdir -p chirpstack/postgres
mkdir -p chirpstack/postgres-init  # <--- ADD THIS LINE!
mkdir -p chirpstack/redis

echo "Generating PostgreSQL extension initializers..."
cat <<EOF > chirpstack/postgres-init/01-extensions.sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS hstore;
EOF
# --------------------------

# Set strict Docker UID permissions for Alpine containers
chown -R "$REAL_USER":"$REAL_USER" chirpstack/configuration
chown -R 70:70 chirpstack/postgres
chown -R 70:70 chirpstack/postgres-init
chown -R 999:999 chirpstack/redis

REGION_CONFIG="$PROJECT_ROOT/chirpstack/configuration/chirpstack/region_eu868.toml"

if [ ! -f "$REGION_CONFIG" ]; then
    echo "ERROR: Could not find $REGION_CONFIG"
    exit 1
fi

echo "Using EU868 region configuration: $REGION_CONFIG"

cat <<EOF > chirpstack/configuration/chirpstack/chirpstack.toml
[network]
net_id="000000"
enabled_regions=["eu868"]

[postgresql]
dsn="postgres://postgres:root@chirpstack-postgres/postgres?sslmode=disable"

[redis]
servers=["redis://chirpstack-redis/"]

[api]
bind="0.0.0.0:8080"
secret="fai-offline-secret-key-12345"

[integration]
  [integration.mqtt]
  server="tcp://mqtt:1883/"
  json=true
EOF

# 7. Systemd Service & Persistence
echo "[7/10] Installing Systemd Service..."

SERVICE_SOURCE=""

for candidate in \
    "$PROJECT_ROOT/fai-gateway.service" \
    "$SCRIPT_DIR/fai-gateway.service" \
    "$PROJECT_ROOT/scripts/fai-gateway.service" \
    "$PROJECT_ROOT/systemd/fai-gateway.service"
do
    if [ -f "$candidate" ]; then
        SERVICE_SOURCE="$candidate"
        break
    fi
done

if [ -z "$SERVICE_SOURCE" ]; then
    echo "ERROR: fai-gateway.service could not be found."
    echo "Searched:"
    echo "  $PROJECT_ROOT/fai-gateway.service"
    echo "  $SCRIPT_DIR/fai-gateway.service"
    echo "  $PROJECT_ROOT/scripts/fai-gateway.service"
    exit 1
fi

echo "Installing service from: $SERVICE_SOURCE"

cp "$SERVICE_SOURCE" /etc/systemd/system/fai-gateway.service

sed -i \
    -e "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" \
    -e "s|^WorkingDirectory=.*|WorkingDirectory=$PROJECT_ROOT|" \
    /etc/systemd/system/fai-gateway.service

systemctl daemon-reload
systemctl enable fai-gateway.service

if ! systemctl cat fai-gateway.service >/dev/null 2>&1; then
    echo "ERROR: fai-gateway.service was not installed correctly."
    exit 1
fi

echo "Persistence enabled."

# 8. SSD Setup
echo "[8/10] Configuring NVMe SSD for Store-and-Forward..."
MOUNT_POINT="/opt/fai-storage"
NVME_DRIVE="/dev/nvme0n1"

mkdir -p $MOUNT_POINT
if blkid $NVME_DRIVE | grep -q "ext4"; then
    echo "Drive $NVME_DRIVE is already formatted."
else
    echo "Formatting $NVME_DRIVE to ext4..."
    parted -s $NVME_DRIVE mklabel gpt
    parted -s $NVME_DRIVE mkpart primary ext4 0% 100%
    mkfs.ext4 -F ${NVME_DRIVE}p1
fi

if ! grep -q "${NVME_DRIVE}p1" /etc/fstab; then
    echo "${NVME_DRIVE}p1 $MOUNT_POINT ext4 defaults 0 2" | tee -a /etc/fstab
fi

mount -a
chown -R $REAL_USER:$REAL_USER $MOUNT_POINT

# 9. SuperCAP UPS Setup
echo "[9/10] Configuring I2C for SuperCAP UPS..."

apt-get update
apt-get install -y i2c-tools python3-smbus

if ! groups $REAL_USER | grep &>/dev/null '\bi2c\b'; then
    usermod -aG i2c $REAL_USER
fi

if [ ! -f /etc/udev/rules.d/50-disable-usb-autosuspend.rules ]; then
    cat <<'EOF' > /etc/udev/rules.d/50-disable-usb-autosuspend.rules
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
EOF
    udevadm control --reload-rules
    udevadm trigger
fi

if ! grep -q "usbcore.quirks=2109:2817:k" /boot/firmware/cmdline.txt; then
    sed -i 's/usbcore.autosuspend=-1//g' /boot/firmware/cmdline.txt
    sed -i '$ s/$/ usbcore.autosuspend=-1 usbcore.quirks=2109:2817:k/' /boot/firmware/cmdline.txt
fi

# 10. Hardware Udev Rules (Zero-Touch RS485 Mapping)
echo "[10/10] Generating Hardware Device Mappings..."

cat <<EOF > /etc/udev/rules.d/99-rs485-wch.rules
# WCH Quad Serial (4 RS485 Ports) - Mapped by Interface Number
SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="1a86", ENV{ID_MODEL_ID}=="55d5", ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="RS485_QUAD_1"
SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="1a86", ENV{ID_MODEL_ID}=="55d5", ENV{ID_USB_INTERFACE_NUM}=="02", SYMLINK+="RS485_QUAD_2"
SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="1a86", ENV{ID_MODEL_ID}=="55d5", ENV{ID_USB_INTERFACE_NUM}=="04", SYMLINK+="RS485_QUAD_3"
SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="1a86", ENV{ID_MODEL_ID}=="55d5", ENV{ID_USB_INTERFACE_NUM}=="06", SYMLINK+="RS485_QUAD_4"
EOF

udevadm control --reload-rules
udevadm trigger

# Install the focused recovery supervisor, stable FT2232 device mappings and
# restricted radio USB recovery helper. This does not restart the stack.
RECOVERY_INSTALLER="$PROJECT_ROOT/scripts/install_recovery.sh"
if [ ! -f "$RECOVERY_INSTALLER" ]; then
    echo "ERROR: recovery installer missing: $RECOVERY_INSTALLER"
    exit 1
fi
chmod +x "$RECOVERY_INSTALLER"
bash "$RECOVERY_INSTALLER" --install-only

# =================================================================
# 11. ZERO-TOUCH CHIRPSTACK AUTO-PROVISIONING
# =================================================================

if [ "$ACTIVE_PROFILES" = "lorawan" ]; then
    echo "[11/11] Booting Stack & Auto-Provisioning ChirpStack..."

    if ! systemctl start fai-gateway.service; then
        echo "ERROR: Failed to start fai-gateway.service."
        systemctl status fai-gateway.service --no-pager || true
        journalctl -u fai-gateway.service -n 100 --no-pager || true
        exit 1
    fi

    echo -n "Waiting for ChirpStack to come online"

    CHIRPSTACK_READY=false

    for attempt in $(seq 1 60); do
        if curl -fsS -o /dev/null "http://127.0.0.1:8080/"; then
            CHIRPSTACK_READY=true
            break
        fi

        printf '.'
        sleep 2
    done

    echo ""

    if [ "$CHIRPSTACK_READY" != "true" ]; then
        echo "ERROR: ChirpStack did not become ready within 120 seconds."
        docker compose ps || true
        docker compose logs --tail=100 chirpstack || true
        exit 1
    fi

    echo "ChirpStack is UP! Executing Ghost Admin..."

    SETUP_SCRIPT="$PROJECT_ROOT/scripts/chirpstack_setup.sh"

    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo "ERROR: Could not find $SETUP_SCRIPT."
        exit 1
    fi

    chmod +x "$SETUP_SCRIPT"

    # The bootstrap is already running as root, so sudo is unnecessary.
    if ! (
        cd "$PROJECT_ROOT"
        bash "$SETUP_SCRIPT"
    ); then
        echo "ERROR: ChirpStack auto-provisioning failed."
        exit 1
    fi
else
    echo "[11/11] LoRaWAN Disabled. Skipping ChirpStack Auto-Provisioning."
fi
# =================================================================

echo ""
echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Gateway Serial: $FINAL_SERIAL"
echo "Meter Configured: $METER_TYPE"
echo "Hardware: LoRaWAN and Modbus are now fully Zero-Touch."
echo "Next Step: Run 'sudo reboot'"
