#!/bin/bash
# Enable or disable controlled EMC data-age diagnostics/recovery.
# Normal production mode does not treat radio silence as a fault.

set -euo pipefail

MODE="${1:-}"

case "$MODE" in
    on)  VALUE=true ;;
    off) VALUE=false ;;
    *)
        echo "Usage: $0 {on|off}" >&2
        exit 2
        ;;
esac

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: run with sudo: sudo $0 {on|off}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE does not exist. Run bootstrap_gateway.sh first." >&2
    exit 3
fi

set_env() {
    key="$1"
    value="$2"
    temporary="$(mktemp)"

    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        index($0, key "=") == 1 {
            print key "=" value
            found = 1
            next
        }
        { print }
        END {
            if (!found) print key "=" value
        }
    ' "$ENV_FILE" > "$temporary"

    chown --reference="$ENV_FILE" "$temporary"
    chmod --reference="$ENV_FILE" "$temporary"
    mv "$temporary" "$ENV_FILE"
}

set_env EMC_TEST_MODE "$VALUE"

(
    cd "$PROJECT_ROOT"
    docker compose up -d --no-deps --force-recreate nodered
)

systemctl try-restart fai-radio-recovery.service

if [ "$VALUE" = true ]; then
    echo "EMC diagnostic mode enabled."
    echo "Use continuous, known TinyMesh and wM-Bus transmitters."
    echo "Data-age policy: serial reopen at ~10 s; 18 s escalation is logged only; targeted USB reset at ~30 s."
else
    echo "EMC diagnostic mode disabled."
    echo "Normal serial-error, USB-presence and MQTT recovery remain active."
    echo "Radio silence alone will not trigger recovery."
fi
