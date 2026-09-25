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

CONFIG=/tmp/global_conf.json
cp /opt/lora/global_conf.json.sx1250.EU868 "$CONFIG"

sed -i -E \
    -e "s/\"gateway_ID\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"gateway_ID\": \"$GATEWAY_SERIAL\"/" \
    -e 's/"server_address"[[:space:]]*:[[:space:]]*"[^"]+"/"server_address": "gateway-bridge"/' \
    -e 's/"serv_port_up"[[:space:]]*:[[:space:]]*[0-9]+/"serv_port_up": 1700/' \
    -e 's/"serv_port_down"[[:space:]]*:[[:space:]]*[0-9]+/"serv_port_down": 1700/' \
    "$CONFIG"

# Verify the generated configuration before using it.
grep -q "\"gateway_ID\": \"$GATEWAY_SERIAL\"" "$CONFIG"
grep -q '"server_address": "gateway-bridge"' "$CONFIG"
grep -q '"serv_port_up": 1700' "$CONFIG"
grep -q '"serv_port_down": 1700' "$CONFIG"

# Read-only commissioning check; does not initialise the radio.
if [ "${1:-}" = "--check" ]; then
    grep -E \
        '"com_type"|"com_path"|"gateway_ID"|"server_address"|"serv_port_up"|"serv_port_down"' \
        "$CONFIG"
    exit 0
fi

exec ./lora_pkt_fwd -c "$CONFIG"
