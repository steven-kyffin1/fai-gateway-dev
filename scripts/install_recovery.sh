#!/bin/bash
# Install the EMC recovery additions without re-running the destructive/full
# zero-touch bootstrap. Use --activate only after reviewing .env and hardware.
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: run with sudo: sudo $0 [--activate]" >&2
    exit 1
fi

ACTIVATE=false
case "${1:-}" in
    "") ;;
    --activate) ACTIVATE=true ;;
    --install-only) ;;
    *)
        echo "Usage: $0 [--install-only|--activate]" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
UDEV_SOURCE="$PROJECT_ROOT/udev/99-fai-gateway-devices.rules"
HELPER_SOURCE="$PROJECT_ROOT/scripts/fai-usb-recover"
GATEWAY_UNIT_SOURCE="$PROJECT_ROOT/systemd/fai-gateway.service"
RECOVERY_UNIT_SOURCE="$PROJECT_ROOT/systemd/fai-radio-recovery.service"
AUDIOMOTH_UNIT_SOURCE="$PROJECT_ROOT/systemd/fai-audiomoth.service"

for required in "$UDEV_SOURCE" "$HELPER_SOURCE" "$GATEWAY_UNIT_SOURCE" "$RECOVERY_UNIT_SOURCE" "$AUDIOMOTH_UNIT_SOURCE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: required file is missing: $required" >&2
        exit 3
    fi
done

echo "Installing host dependencies for monitoring and recovery..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-paho-mqtt python3-docker alsa-utils

mkdir -p /opt/fai-storage/emc
mkdir -p /opt/fai-storage/audio
touch "$ENV_FILE"

ensure_env() {
    key="$1"
    value="$2"
    if ! grep -q "^$key=" "$ENV_FILE"; then
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

ensure_env EMC_TEST_MODE false
ensure_env NODE_RED_HEALTH_STALE_SECONDS 25
ensure_env NODE_RED_HEALTH_STARTUP_GRACE_SECONDS 30
ensure_env RECOVERY_STARTUP_GRACE_SECONDS 30
ensure_env RECOVERY_DATA_STALE_SECONDS 10
ensure_env RECOVERY_NODERED_RESTART_SECONDS 18
ensure_env RECOVERY_USB_RESET_SECONDS 30
ensure_env RECOVERY_ACTION_COOLDOWN_SECONDS 60
ensure_env RECOVERY_SERIAL_VERIFY_SECONDS 12
ensure_env RECOVERY_SERIAL_VERIFY_MAX_WAIT_SECONDS 45
ensure_env ALLOW_HOST_REBOOT false
ensure_env TINY_SERIAL_DEVICE /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B401GJOI-if00-port0
ensure_env WMBUS_SERIAL_DEVICE /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B400T7S7-if00-port0
ensure_env RS485_METER_DEVICE /dev/RS485_ISO_1
ensure_env RS485_SILO_DEVICE /dev/RS485_ISO_2
ensure_env EMC_RF_DWELL_SECONDS 3
ensure_env EMC_TINYMESH_STALE_SECONDS 10
ensure_env EMC_WMBUS_STALE_SECONDS 6
ensure_env EMC_POWER_STALE_SECONDS 3
ensure_env EMC_SILO_STALE_SECONDS 3
ensure_env EMC_MONITOR_REQUIRED_FLOWS tinymesh,wmbus,power,silo1,silo2
ensure_env AUDIOMOTH_ENABLED true
ensure_env AUDIOMOTH_TEST_MODE false
ensure_env AUDIOMOTH_ALSA_DEVICE plughw:CARD=AudioMoth,DEV=0
ensure_env AUDIOMOTH_SAMPLE_RATE 48000
ensure_env AUDIOMOTH_CHANNELS 1
ensure_env AUDIOMOTH_FORMAT S16_LE
ensure_env AUDIOMOTH_RECORD_SECONDS 30
ensure_env AUDIOMOTH_INTERVAL_SECONDS 300

install -m 0644 "$UDEV_SOURCE" /etc/udev/rules.d/99-fai-gateway-devices.rules
install -m 0755 "$HELPER_SOURCE" /usr/local/sbin/fai-usb-recover

install_unit() {
    source_file="$1"
    target_file="$2"
    sed "s|__PROJECT_ROOT__|$PROJECT_ROOT|g" "$source_file" > "$target_file"
    chmod 0644 "$target_file"
}

install_unit "$GATEWAY_UNIT_SOURCE" /etc/systemd/system/fai-gateway.service
install_unit "$RECOVERY_UNIT_SOURCE" /etc/systemd/system/fai-radio-recovery.service
install_unit "$AUDIOMOTH_UNIT_SOURCE" /etc/systemd/system/fai-audiomoth.service

chmod 0755 \
    "$PROJECT_ROOT/scripts/radio_recovery_watchdog.py" \
    "$PROJECT_ROOT/scripts/audiomoth_recorder.py" \
    "$PROJECT_ROOT/scripts/set_emc_mode.sh"

udevadm control --reload-rules
udevadm trigger
systemctl daemon-reload
systemctl enable fai-gateway.service fai-radio-recovery.service fai-audiomoth.service

echo
echo "Installed recovery files. Stable device links expected:"
echo "  /dev/RS485_ISO_1  power-meter channel"
echo "  /dev/RS485_ISO_2  shared silo channel"
echo "  TinyMesh and wM-Bus retain their serial-number based /dev/serial/by-id paths."
echo "  AudioMoth is included as a USB microphone and records to /opt/fai-storage/audio."

if [ "$ACTIVATE" = true ]; then
    echo "Validating and activating the revised stack..."
    if ! arecord -l 2>/dev/null | grep -qi 'AudioMoth'; then
        echo "ERROR: AudioMoth USB microphone was not found by ALSA." >&2
        echo "Flash the USB Microphone firmware, connect the final cable chain, and run: arecord -l" >&2
        exit 4
    fi
    (
        cd "$PROJECT_ROOT"
        docker compose config >/dev/null
        docker compose build
    )
    systemctl restart fai-gateway.service
    systemctl restart fai-radio-recovery.service
    systemctl restart fai-audiomoth.service
    echo "Activation complete."
else
    echo
    echo "No containers were restarted. After the hardware and .env checks, activate with:"
    echo "  sudo $PROJECT_ROOT/scripts/install_recovery.sh --activate"
fi
