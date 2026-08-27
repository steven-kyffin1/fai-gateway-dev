#!/bin/bash
# Toggle controlled EMC data-age recovery. Normal production mode does not
# treat a quiet passive receiver as a fault.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    on) VALUE=true ;;
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
    echo "ERROR: $ENV_FILE does not exist. Run install_recovery.sh first." >&2
    exit 3
fi

set_env() {
    key="$1"
    value="$2"
    temporary="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        index($0, key "=") == 1 { print key "=" value; found = 1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$ENV_FILE" > "$temporary"
    chown --reference="$ENV_FILE" "$temporary"
    chmod --reference="$ENV_FILE" "$temporary"
    mv "$temporary" "$ENV_FILE"
}

set_env EMC_TEST_MODE "$VALUE"

if [ "$VALUE" = true ]; then
    set_env AUDIOMOTH_ENABLED true
    set_env AUDIOMOTH_TEST_MODE true
    set_env AUDIOMOTH_RECORD_SECONDS 60
    set_env AUDIOMOTH_INTERVAL_SECONDS 0
else
    set_env AUDIOMOTH_TEST_MODE false
    set_env AUDIOMOTH_RECORD_SECONDS 30
    set_env AUDIOMOTH_INTERVAL_SECONDS 300
fi

(
    cd "$PROJECT_ROOT"
    docker compose up -d --no-deps --force-recreate nodered
)
systemctl try-restart fai-radio-recovery.service
systemctl try-restart fai-audiomoth.service

if [ "$VALUE" = true ]; then
    echo "EMC mode enabled. Use continuous, known TinyMesh and wM-Bus transmitters."
    echo "Data-age recovery thresholds: serial reopen 10 s, Node-RED restart 18 s, USB reset 30 s."
    echo "AudioMoth is recording consecutive 60-second WAV files throughout the sweep."
else
    echo "EMC mode disabled. Serial-error and USB reattach recovery remain active."
    echo "AudioMoth returned to 30 seconds of recording every 5 minutes."
fi
