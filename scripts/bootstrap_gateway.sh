#!/bin/bash
# FAI Gateway Bootstrap - Production Zero-Touch Edition

GATEWAY_VERSION="2.4.3"
echo "--- 🛰️ FAI GATEWAY v${GATEWAY_VERSION} STARTUP SEQUENCE ---"

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
else
    echo "Docker already installed."
fi

# Always ensure the commissioning user can access Docker,
# including gateways where Docker was pre-installed.
usermod -aG docker "$REAL_USER"

# 6. MQTT, LoRaWAN & Project Folder Structure
echo "[6/10] Finalizing Project Folders & Environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Project Root detected at: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# Preserve commissioned configuration on subsequent runs.
if [ -f .env ]; then
    echo "Loading existing gateway configuration..."
    set -a
    . ./.env
    set +a
fi

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
echo "Select LoRaWAN hardware:"
echo "1) WM1302 SPI EU868"
echo "2) Legacy USB EU868"
echo "3) No LoRaWAN"
echo "----------------------------------------"

# Reuse a previously commissioned selection.
DEFAULT_LORA=1

case "${LORA_HARDWARE:-${COMPOSE_PROFILES:-}}" in
    USB|*lorawan-usb*) DEFAULT_LORA=2 ;;
    NONE) DEFAULT_LORA=3 ;;
esac

read -r -p "Select [Default: $DEFAULT_LORA]: " LORA_CHOICE
LORA_CHOICE="${LORA_CHOICE:-$DEFAULT_LORA}"

PREVIOUS_LORA_INTERFACE="${LORA_INTERFACE:-}"
PREVIOUS_LORA_DEVICE="${LORA_DEVICE:-}"

case "$LORA_CHOICE" in
    1)
        LORA_HARDWARE=SPI
        LORA_INTERFACE=SPI
        LORA_DEVICE=/dev/spidev0.1
        ACTIVE_PROFILES="lorawan,lorawan-spi"
        ;;
    2)
        LORA_HARDWARE=USB
        LORA_INTERFACE=USB
        LORA_DEVICE=/dev/ttyACM0

        if [ "$PREVIOUS_LORA_INTERFACE" = USB ] &&
           [ -n "$PREVIOUS_LORA_DEVICE" ]; then
            LORA_DEVICE="$PREVIOUS_LORA_DEVICE"
        fi

        ACTIVE_PROFILES="lorawan,lorawan-usb"
        ;;
    3)
        LORA_HARDWARE=NONE
        LORA_INTERFACE=""
        LORA_DEVICE=""
        ACTIVE_PROFILES=""
        ;;
    *)
        echo "ERROR: Invalid LoRaWAN selection" >&2
        exit 1
        ;;
esac

LORAWAN_WATER_METERS="${LORAWAN_WATER_METERS:-true}"

if [ "$LORA_HARDWARE" != NONE ]; then
    WATER_DEFAULT=2
    [ "$LORAWAN_WATER_METERS" = true ] && WATER_DEFAULT=1

    echo "Will this gateway receive LoRaWAN water meters?"
    echo "1) YES"
    echo "2) NO"

    read -r -p "Select [Default: $WATER_DEFAULT]: " WATER_CHOICE
    WATER_CHOICE="${WATER_CHOICE:-$WATER_DEFAULT}"

    case "$WATER_CHOICE" in
        1) LORAWAN_WATER_METERS=true ;;
        2) LORAWAN_WATER_METERS=false ;;
        *)
            echo "ERROR: Invalid water-meter selection" >&2
            exit 1
            ;;
    esac
else
    LORAWAN_WATER_METERS=false
fi

echo "Selected LoRaWAN hardware: $LORA_HARDWARE"
echo "Compose profiles: ${ACTIVE_PROFILES:-none}"

# Isolated two-port RS485 is standard on new production gateways.
RS485_DEFAULT=1

case "${RS485_HARDWARE:-${COMPOSE_PROFILES:-}}" in
    NONE) RS485_DEFAULT=2 ;;
    ISOLATED|*rs485-isolated*) RS485_DEFAULT=1 ;;
esac

echo ""
echo "Select RS485 hardware:"
echo "1) Waveshare isolated two-port [Default]"
echo "2) No external RS485 adapter"

read -r -p "Select [Default: $RS485_DEFAULT]: " RS485_CHOICE
RS485_CHOICE="${RS485_CHOICE:-$RS485_DEFAULT}"

case "$RS485_CHOICE" in
    1)
        RS485_HARDWARE=ISOLATED
        if [ -n "$ACTIVE_PROFILES" ]; then
            ACTIVE_PROFILES="$ACTIVE_PROFILES,rs485-isolated"
        else
            ACTIVE_PROFILES="rs485-isolated"
        fi
        ;;
    2)
        RS485_HARDWARE=NONE
        ;;
    *)
        echo "ERROR: Invalid RS485 selection" >&2
        exit 1
        ;;
esac

echo "RS485 hardware: $RS485_HARDWARE"
echo "Final Compose profiles: ${ACTIVE_PROFILES:-none}"

# RS485 adapter presence preflight.
# Detect the FT2232 USB device before storage setup or Docker startup.
if [[ "$RS485_HARDWARE" == "ISOLATED" ]]; then
    rs485_found=false

    for usb_device in /sys/bus/usb/devices/*; do
        [[ -f "$usb_device/idVendor" &&
           -f "$usb_device/idProduct" ]] || continue

        if [[ "$(<"$usb_device/idVendor")" == "0403" &&
              "$(<"$usb_device/idProduct")" == "6010" ]]; then
            rs485_found=true
            break
        fi
    done

    if [[ "$rs485_found" != true ]]; then
        echo "ERROR: Isolated RS485 selected, but FT2232 adapter not detected." >&2
        echo "Connect the adapter or rerun bootstrap and select option 2." >&2
        exit 1
    fi
fi



FINAL_SERIAL=${GATEWAY_SERIAL:-$ETH_MAC}
DEFAULT_HOSTNAME="fai-gw-${FINAL_SERIAL: -8}"
NEW_HOSTNAME="${NEW_HOSTNAME:-${GATEWAY_HOSTNAME:-$DEFAULT_HOSTNAME}}"

echo "Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME" || true

# Keep /etc/hosts aligned with hostname so sudo does not warn:
# "unable to resolve host"
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "127.0.1.1   $NEW_HOSTNAME" >> /etc/hosts

echo "Updating environment variables in $PROJECT_ROOT/.env..."

touch .env

set_env() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

ensure_env() {
    local key="$1"
    local value="$2"

    if ! grep -q "^${key}=" .env; then
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

# The selected profiles must override any value loaded earlier.
export COMPOSE_PROFILES="$ACTIVE_PROFILES"

set_env GATEWAY_SERIAL "$FINAL_SERIAL"
set_env GATEWAY_HOSTNAME "$NEW_HOSTNAME"
set_env POWER_METER_TYPE "$METER_TYPE"
set_env COMPOSE_PROFILES "$ACTIVE_PROFILES"
set_env RS485_HARDWARE "$RS485_HARDWARE"
set_env LORA_HARDWARE "$LORA_HARDWARE"
set_env LORA_INTERFACE "$LORA_INTERFACE"
set_env LORA_DEVICE "$LORA_DEVICE"
set_env LORAWAN_WATER_METERS "$LORAWAN_WATER_METERS"

# Supply ADS301 defaults without erasing commissioned values.
ensure_env ADS301_SILO_1_ACCESS_UNIT_ID 1
ensure_env ADS301_SILO_2_ACCESS_UNIT_ID 2
ensure_env ADS301_SILO_1_CHANNELS 4
ensure_env ADS301_SILO_2_CHANNELS 4

chown "$REAL_USER":"$REAL_USER" .env

# Permissions
# Runtime directories are gitignored, so create them on every fresh install.
mkdir -p "$PROJECT_ROOT/mosquitto/data" "$PROJECT_ROOT/mosquitto/log"
chown -R 1883:1883 "$PROJECT_ROOT/mosquitto/data" "$PROJECT_ROOT/mosquitto/log"
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
local_clientid local.${FINAL_SERIAL}.cloud-backend-bridge
remote_username ${FINAL_SERIAL}

bridge_protocol_version mqttv311
bridge_cafile /etc/ssl/certs/ca-certificates.crt
bridge_insecure false

cleansession false
try_private false
start_type automatic
restart_timeout 5 30

topic gateway/${FINAL_SERIAL}/# out 1 "" ""
EOF

# Allow the deployment user to maintain the Mosquitto configuration
chown -R "$REAL_USER:$REAL_USER" mosquitto/config
find mosquitto/config -type d -exec chmod 755 {} \;
find mosquitto/config -type f -exec chmod 644 {} \;

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

# 1. Copy our verified local template to the config folder
if [ -f "$PROJECT_ROOT/chirpstack/configuration/chirpstack/region_eu868.toml" ]; then
    cp "$PROJECT_ROOT/chirpstack/configuration//chirpstack/region_eu868.toml" chirpstack/configuration/chirpstack/region_eu868.toml
else
    echo "⚠️ ERROR: Could not find chirpstack/configuration/chirpstack/region_eu868.toml. Please ensure it exists in your repo."
    exit 1
fi

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
enabled=["mqtt"]
  [integration.mqtt]
  server="tcp://mqtt:1883/"
  json=true
EOF

# 7. Systemd Service & Persistence
echo "[7/10] Installing Systemd Service..."

cat > /etc/systemd/system/fai-gateway.service <<EOF
[Unit]
Description=FAI Gateway Docker Stack
Requires=docker.service
RequiresMountsFor=/opt/fai-storage
Wants=network-online.target tailscaled.service
After=docker.service network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_ROOT
EnvironmentFile=$PROJECT_ROOT/.env
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fai-gateway.service
echo "Persistence enabled."

# Install all dependencies before configuring SSD and UPS.
# Required on every freshly imaged production gateway.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    parted util-linux e2fsprogs curl \
    i2c-tools python3-smbus python3-paho-mqtt

# 8. SSD Setup
echo "[8/10] Configuring NVMe SSD for Store-and-Forward..."

MOUNT_POINT="/opt/fai-storage"
NVME_DRIVE="/dev/nvme0n1"
NVME_PARTITION="${NVME_DRIVE}p1"

mkdir -p "$MOUNT_POINT"

if [ ! -b "$NVME_DRIVE" ]; then
    echo "ERROR: Expected NVMe drive $NVME_DRIVE was not found."
    exit 1
fi

if [ -b "$NVME_PARTITION" ]; then
    EXISTING_FSTYPE="$(blkid -s TYPE -o value "$NVME_PARTITION" 2>/dev/null || true)"

    if [ "$EXISTING_FSTYPE" = "ext4" ]; then
        echo "Existing ext4 filesystem found on $NVME_PARTITION. Reusing it."
    else
        echo "ERROR: $NVME_PARTITION already exists but is not ext4."
        echo "Refusing to format an existing partition automatically."
        lsblk -f "$NVME_DRIVE" || true
        exit 1
    fi
else
    # Refuse to repartition a disk that already contains unexpected partitions.
    CHILD_COUNT="$(
        lsblk -nrpo TYPE "$NVME_DRIVE" 2>/dev/null |
        grep -c '^part$' || true
    )"

    if [ "$CHILD_COUNT" -ne 0 ]; then
        echo "ERROR: $NVME_DRIVE contains existing partitions, but $NVME_PARTITION was not found."
        echo "Refusing to repartition automatically."
        lsblk -f "$NVME_DRIVE" || true
        exit 1
    fi

    # A disk can contain data or a partition table even if lsblk
    # does not show any recognised partitions.
    if ! SIGNATURES="$(wipefs --no-act "$NVME_DRIVE")"; then
        echo "ERROR: Cannot inspect NVMe signatures."
        exit 1
    fi

    if [ -n "$SIGNATURES" ]; then
        echo "ERROR: Existing NVMe signatures detected."
        echo "$SIGNATURES"
        echo "Refusing automatic formatting."
        exit 1
    fi

    echo "Blank NVMe detected. Creating GPT and ext4 filesystem..."
    parted -s "$NVME_DRIVE" mklabel gpt
    parted -s "$NVME_DRIVE" mkpart primary ext4 0% 100%

    partprobe "$NVME_DRIVE"

    for _ in $(seq 1 10); do
        [ -b "$NVME_PARTITION" ] && break
        sleep 1
    done

    if [ ! -b "$NVME_PARTITION" ]; then
        echo "ERROR: $NVME_PARTITION did not appear after partitioning."
        exit 1
    fi

    mkfs.ext4 -F "$NVME_PARTITION"
fi

NVME_UUID="$(blkid -s UUID -o value "$NVME_PARTITION")"

if [ -z "$NVME_UUID" ]; then
    echo "ERROR: Could not determine filesystem UUID for $NVME_PARTITION."
    exit 1
fi

# Preserve any existing mount configuration. Never silently
# replace a different filesystem assigned to this mount point.
FSTAB_SOURCE="$(
    awk '$1 !~ /^#/ && $2 == "/opt/fai-storage" {print $1}' /etc/fstab
)"

if [ -z "$FSTAB_SOURCE" ]; then
    echo "UUID=$NVME_UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
elif [ "$FSTAB_SOURCE" != "UUID=$NVME_UUID" ]; then
    echo "ERROR: Existing fstab entry requires review: $FSTAB_SOURCE"
    exit 1
fi

# Mount the expected filesystem without invoking mount -a.
if ! mountpoint -q "$MOUNT_POINT"; then
    if ! mount "$MOUNT_POINT"; then
        echo "ERROR: Failed to mount $MOUNT_POINT."
        exit 1
    fi
fi

MOUNTED_UUID="$(findmnt -n -o UUID --mountpoint "$MOUNT_POINT")"

if [ "$MOUNTED_UUID" != "$NVME_UUID" ]; then
    echo "ERROR: Wrong filesystem mounted at $MOUNT_POINT."
    echo "Expected UUID: $NVME_UUID"
    echo "Actual UUID: $MOUNTED_UUID"
    exit 1
fi

# The mount root is Mosquitto's persistent data directory.
# Do not recursively alter the ownership of existing SSD contents.
chown 1883:1883 "$MOUNT_POINT"
chmod 0755 "$MOUNT_POINT"

echo "NVMe storage ready:"
findmnt "$MOUNT_POINT"

# 9. SuperCAP UPS Setup
echo "[9/10] Configuring I2C for SuperCAP UPS..."



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

# 10. Persistent isolated RS485 device mappings
echo "[10/10] Installing isolated RS485 device mappings..."

install -m 0644     "$PROJECT_ROOT/udev/99-fai-rs485-isolated.rules"     /etc/udev/rules.d/99-fai-rs485-isolated.rules

install -m 0644     "$PROJECT_ROOT/udev/99-fai-radio-ports.rules"     /etc/udev/rules.d/99-fai-radio-ports.rules

udevadm control --reload-rules
udevadm trigger --subsystem-match=tty

# Verify that udev has created both isolated RS485 interfaces.
if [[ "$RS485_HARDWARE" == "ISOLATED" ]]; then
    udevadm settle --timeout=15

    for rs485_device in /dev/RS485_ISO_1 /dev/RS485_ISO_2; do
        if [[ ! -c "$rs485_device" ]]; then
            echo "ERROR: Missing RS485 device: $rs485_device" >&2
            echo "Check the adapter and udev mapping before starting Docker." >&2
            exit 1
        fi
    done
fi


# =================================================================
# 10b. RECOVERY & DIAGNOSTIC SERVICES
# =================================================================
echo "[10b/10] Installing recovery and diagnostic services..."

# Restricted helper used by the radio recovery supervisor to re-enumerate
# only explicitly recognised USB interfaces.
install -m 0755 \
    "$PROJECT_ROOT/scripts/fai-usb-recover" \
    /usr/local/sbin/fai-usb-recover

# EMC/diagnostic log directory service. This also guarantees that
# /opt/fai-storage/emc exists after the storage mount is available.
install -m 0644 \
    "$PROJECT_ROOT/systemd/fai-emc-logdir.service" \
    /etc/systemd/system/fai-emc-logdir.service

# Install the radio recovery service while substituting the actual project path.
sed "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" \
    "$PROJECT_ROOT/systemd/fai-radio-recovery.service" \
    > /etc/systemd/system/fai-radio-recovery.service

chmod 0644 /etc/systemd/system/fai-radio-recovery.service

systemctl daemon-reload

systemctl enable fai-emc-logdir.service
systemctl enable fai-radio-recovery.service

# Create the persistent recovery log location now as well as at boot.
systemctl start fai-emc-logdir.service

echo "Recovery services installed and enabled."

# =================================================================
# 11. START GATEWAY & OPTIONAL LORAWAN PROVISIONING
# =================================================================
# Build the selected SPI forwarder on every new installation.
# Reuses Docker's build cache on subsequent installations.
if [[ ",$ACTIVE_PROFILES," == *,lorawan-spi,* ]]; then
    echo "Preparing WM1302 SPI forwarder..."

    for device in /dev/spidev0.1 /dev/i2c-3; do
        if [ ! -c "$device" ]; then
            echo "ERROR: Required SPI hardware missing: $device"
            exit 1
        fi
    done

    if ! docker compose build lora-forwarder-spi; then
        echo "ERROR: WM1302 SPI image build failed."
        exit 1
    fi
fi

echo "[11/11] Starting FAI Gateway stack..."

# 'start' is a no-op if the oneshot service is already active.
# Restart an existing installation to apply its selected profiles.
if systemctl is-active --quiet fai-gateway.service; then
    GATEWAY_ACTION=restart
else
    GATEWAY_ACTION=start
fi

echo "Gateway service action: $GATEWAY_ACTION"

if ! systemctl "$GATEWAY_ACTION" fai-gateway.service; then
    echo "ERROR: Failed to start fai-gateway.service."
    systemctl status fai-gateway.service --no-pager || true
    journalctl -u fai-gateway.service -n 100 --no-pager || true
    exit 1
fi

if [[ ",$ACTIVE_PROFILES," == *,lorawan,* ]]; then
    echo "[11/11] Booting Stack & Auto-Provisioning ChirpStack..."
    echo -n "Waiting for ChirpStack to come online (takes ~15-20s)"
    
    # Ping the Web UI on 8080 to see if the container has finished booting
    CHIRPSTACK_READY=false

    for attempt in {1..60}; do
        if curl -s -f -o /dev/null "http://localhost:8080/"; then
            CHIRPSTACK_READY=true
            break
        fi
        printf '.'
        sleep 2
    done

    if [ "$CHIRPSTACK_READY" != true ]; then
        echo
        echo "ERROR: ChirpStack did not become ready."
        docker compose logs --tail=50 chirpstack || true
        exit 1
    fi
    
    echo ""
    echo "ChirpStack is UP! Executing Ghost Admin..."
    
    
    # 3. Make the provision script executable and run it
    SETUP_SCRIPT="$PROJECT_ROOT/scripts/chirpstack_setup.sh"
    
    if [ -f "$SETUP_SCRIPT" ]; then
        chmod +x "$SETUP_SCRIPT"
        # Execute from the project root so it can find .env
        (cd "$PROJECT_ROOT" && bash "$SETUP_SCRIPT")
    else
        echo "⚠️ WARNING: Could not find $SETUP_SCRIPT. Skipping auto-provisioning."
    fi
else
    echo "[11/11] LoRaWAN Disabled. Skipping ChirpStack Auto-Provisioning."
fi

echo "Starting radio recovery supervisor..."
if ! systemctl start fai-radio-recovery.service; then
    echo "ERROR: Failed to start fai-radio-recovery.service."
    systemctl status fai-radio-recovery.service --no-pager || true
    journalctl -u fai-radio-recovery.service -n 100 --no-pager || true
    exit 1
fi

# =================================================================

echo ""
echo "--- ✅ BOOTSTRAP COMPLETE ---"
echo "Identity: $NEW_HOSTNAME"
echo "Gateway Serial: $FINAL_SERIAL"
echo "Meter Configured: $METER_TYPE"
echo "LoRaWAN Profile: ${ACTIVE_PROFILES:-disabled}"
echo "Gateway stack and recovery services are running."
echo "Recommended verification: run 'sudo reboot' and confirm automatic recovery."