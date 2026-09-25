#!/bin/sh
#
# FAI reComputer R1000 / WM1302 SPI reset sequence
#
# Carrier GPIO expander:
#   GPIO 578 = LoRaWAN_SX1262_CS / WM1302 power-enable mapping
#   GPIO 579 = LoRaWAN_SX1262_RST
#   GPIO 580 = LoRaWAN_SX1302_RST
#
# Based on the Semtech CoreCell reset sequence with the
# Seeed reComputer R1000 GPIO mapping.

set -eu

SX1302_RESET_PIN="${SX1302_RESET_PIN:-580}"
SX1302_POWER_EN_PIN="${SX1302_POWER_EN_PIN:-578}"
SX1261_RESET_PIN="${SX1261_RESET_PIN:-579}"

wait_gpio() {
    sleep 0.1
}

export_gpio() {
    pin="$1"

    if [ ! -d "/sys/class/gpio/gpio${pin}" ]; then
        echo "$pin" > /sys/class/gpio/export
        wait_gpio
    fi
}

set_output() {
    pin="$1"
    echo "out" > "/sys/class/gpio/gpio${pin}/direction"
    wait_gpio
}

unexport_gpio() {
    pin="$1"

    if [ -d "/sys/class/gpio/gpio${pin}" ]; then
        echo "$pin" > /sys/class/gpio/unexport
        wait_gpio
    fi
}

init_gpio() {
    export_gpio "$SX1302_RESET_PIN"
    export_gpio "$SX1261_RESET_PIN"
    export_gpio "$SX1302_POWER_EN_PIN"

    set_output "$SX1302_RESET_PIN"
    set_output "$SX1261_RESET_PIN"
    set_output "$SX1302_POWER_EN_PIN"
}

reset_radio() {
    echo "WM1302 power enable: GPIO${SX1302_POWER_EN_PIN}"
    echo "SX1302 reset:        GPIO${SX1302_RESET_PIN}"
    echo "SX126x reset:        GPIO${SX1261_RESET_PIN}"

    # Power CoreCell.
    echo 1 > "/sys/class/gpio/gpio${SX1302_POWER_EN_PIN}/value"
    wait_gpio

    # Reset SX1302.
    echo 1 > "/sys/class/gpio/gpio${SX1302_RESET_PIN}/value"
    wait_gpio
    echo 0 > "/sys/class/gpio/gpio${SX1302_RESET_PIN}/value"
    wait_gpio

    # Reset auxiliary SX126x.
    echo 0 > "/sys/class/gpio/gpio${SX1261_RESET_PIN}/value"
    wait_gpio
    echo 1 > "/sys/class/gpio/gpio${SX1261_RESET_PIN}/value"
    wait_gpio
}

cleanup_gpio() {
    unexport_gpio "$SX1302_RESET_PIN"
    unexport_gpio "$SX1261_RESET_PIN"
    unexport_gpio "$SX1302_POWER_EN_PIN"
}

case "${1:-}" in
    start)
        # Clear any state left by an earlier process.
        cleanup_gpio
        init_gpio
        reset_radio
        ;;

    stop)
        if [ -d "/sys/class/gpio/gpio${SX1302_POWER_EN_PIN}" ]; then
            echo 0 > "/sys/class/gpio/gpio${SX1302_POWER_EN_PIN}/value" || true
        fi
        cleanup_gpio
        ;;

    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
