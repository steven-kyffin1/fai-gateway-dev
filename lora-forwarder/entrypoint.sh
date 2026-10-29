#!/bin/sh
set -eu

# Use the same gateway identity as ChirpStack registration.
: "${GATEWAY_SERIAL:?GATEWAY_SERIAL is required}"

case "$GATEWAY_SERIAL" in
    *[!0123456789abcdefABCDEF]*)
        echo "ERROR: Invalid gateway serial" >&2
        exit 1
        ;;
esac

if [ "${#GATEWAY_SERIAL}" -ne 16 ]; then
    echo "ERROR: Gateway serial must be 16 hex characters" >&2
    exit 1
fi

LORA_DEVICE="${LORA_DEVICE:-/dev/spidev0.1}"

case "$LORA_DEVICE" in
    /dev/spidev0.1) EXPECTED_I2C_DEVICE=/dev/i2c-3 ;;
    /dev/spidev1.1) EXPECTED_I2C_DEVICE=/dev/i2c-6 ;;
    *)
        echo "ERROR: Unsupported WM1302 SPI device: $LORA_DEVICE" >&2
        exit 1
        ;;
esac

LORA_I2C_DEVICE="${LORA_I2C_DEVICE:-$EXPECTED_I2C_DEVICE}"
COMPILED_I2C_DEVICE="$(cat /opt/lora/i2c-device)"

if [ "$LORA_I2C_DEVICE" != "$EXPECTED_I2C_DEVICE" ] ||
   [ "$COMPILED_I2C_DEVICE" != "$LORA_I2C_DEVICE" ]; then
    echo "ERROR: WM1302 I2C mapping mismatch: selected=$LORA_I2C_DEVICE compiled=$COMPILED_I2C_DEVICE SPI=$LORA_DEVICE" >&2
    echo "Run bootstrap to detect the carrier and rebuild lora-forwarder-spi." >&2
    exit 1
fi

CONFIG=/tmp/global_conf.json
cp /opt/lora/global_conf.json.sx1250.EU868 "$CONFIG"

sed -i -E \
        -e "s|\"com_path\"[[:space:]]*:[[:space:]]*\"[^\"]+\"|\"com_path\": \"$LORA_DEVICE\"|" \
    -e "s/\"gateway_ID\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"gateway_ID\": \"$GATEWAY_SERIAL\"/" \
    -e 's/"server_address"[[:space:]]*:[[:space:]]*"[^"]+"/"server_address": "gateway-bridge"/' \
    -e 's/"serv_port_up"[[:space:]]*:[[:space:]]*[0-9]+/"serv_port_up": 1700/' \
    -e 's/"serv_port_down"[[:space:]]*:[[:space:]]*[0-9]+/"serv_port_down": 1700/' \
    "$CONFIG"

# Verify the generated configuration before using it.
grep -Fq "\"com_path\": \"$LORA_DEVICE\"" "$CONFIG"
grep -q "\"gateway_ID\": \"$GATEWAY_SERIAL\"" "$CONFIG"
grep -q '"server_address": "gateway-bridge"' "$CONFIG"
grep -q '"serv_port_up": 1700' "$CONFIG"
grep -q '"serv_port_down": 1700' "$CONFIG"

# Read-only commissioning check; does not initialise the radio.
if [ "${1:-}" = "--check" ]; then
    grep -E \
        '"com_type"|"com_path"|"gateway_ID"|"server_address"|"serv_port_up"|"serv_port_down"' \
        "$CONFIG"
    printf 'Compiled I2C device: %s\n' "$COMPILED_I2C_DEVICE"
    exit 0
fi

# Confirm the selected hardware is visible inside the container.
for device in "$LORA_DEVICE" "$LORA_I2C_DEVICE"; do
    if [ ! -c "$device" ]; then
        echo "ERROR: Required WM1302 device is missing inside the container: $device" >&2
        exit 1
    fi
done

exec ./lora_pkt_fwd -c "$CONFIG"
