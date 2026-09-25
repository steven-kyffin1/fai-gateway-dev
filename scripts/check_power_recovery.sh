#!/bin/bash

LABEL="${1:-power-test}"
LOG="/opt/fai-storage/emc/power_cycle_test.log"

{
    echo
    echo "========================================"
    echo "POWER RECOVERY CHECK: $LABEL"
    echo "UTC:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "LOCAL: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "BOOT:  $(cat /proc/sys/kernel/random/boot_id)"
    echo "========================================"

    echo
    echo "===== UPTIME ====="
    uptime

    echo
    echo "===== CONTAINERS ====="
    cd /home/recomputer/fai-gateway-dev
    docker compose --profile lorawan ps -a

    echo
    echo "===== NODE-RED ====="
    docker inspect -f \
    'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} started={{.State.StartedAt}} restarts={{.RestartCount}}' \
    fai-nodered 2>&1

    echo
    echo "===== NODE-RED HEALTH ====="
    curl -s http://localhost:1880/healthz
    echo

    echo
    echo "===== RECOVERY SUPERVISOR THIS BOOT ====="
    journalctl -b -u fai-radio-recovery.service --no-pager | tail -100

    echo
    echo "===== AUTOHEAL THIS BOOT ====="
    docker logs fai-watchdog 2>&1 | tail -100

    echo
    echo "===== USB / FTDI THIS BOOT ====="
    dmesg -T 2>/dev/null | \
      grep -Ei 'FTDI|ttyUSB|USB disconnect' | tail -80

    echo
    echo "===== REQUIRED TRAFFIC ====="
    timeout 12s docker exec fai-mqtt mosquitto_sub \
      -h localhost \
      -t 'gateway/+/tinymesh/rx' \
      -t 'gateway/+/wmbus/out' \
      -t 'gateway/+/power/out' \
      -t 'gateway/+/modbus/silo1/emc' \
      -v

    echo
    echo "===== END $LABEL ====="

} 2>&1 | tee -a "$LOG"
