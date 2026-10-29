#!/bin/bash
# Supported reComputer R1000 carrier mappings.

fai_lora_device_present() {
    [[ -c "$1" ]]
}

fai_select_lora_spi() {
    local previous_device="${1:-}"
    local selected_device=""
    local i2c_device
    local candidate
    local -a candidates=()

    # Preserve an available, previously selected SPI device.
    case "$previous_device" in
        ""|auto) ;;
        /dev/spidev0.1|/dev/spidev1.1)
            if fai_lora_device_present "$previous_device"; then
                selected_device="$previous_device"
            else
                echo "Saved SPI device $previous_device is unavailable; detecting the carrier mapping." >&2
            fi
            ;;
        *)
            echo "ERROR: Unsupported saved SPI device: $previous_device" >&2
            echo "Set LORA_DEVICE=auto, /dev/spidev0.1 or /dev/spidev1.1 in .env." >&2
            return 1
            ;;
    esac

    # Detect the available SPI device when no saved choice is usable.
    if [[ -z "$selected_device" ]]; then
        for candidate in /dev/spidev0.1 /dev/spidev1.1; do
            if fai_lora_device_present "$candidate"; then
                candidates+=("$candidate")
            fi
        done

        case "${#candidates[@]}" in
            1) selected_device="${candidates[0]}" ;;
            0)
                echo "ERROR: No supported WM1302 SPI device found." >&2
                return 1
                ;;
            *)
                echo "ERROR: Both supported SPI devices are present. Select the LoRa slot using LORA_DEVICE in .env." >&2
                return 1
                ;;
        esac
    fi

    # Select and verify the corresponding auxiliary I2C bus.
    case "$selected_device" in
        /dev/spidev0.1) i2c_device=/dev/i2c-3 ;;
        /dev/spidev1.1) i2c_device=/dev/i2c-6 ;;
    esac

    if ! fai_lora_device_present "$i2c_device"; then
        echo "ERROR: $selected_device requires $i2c_device, but that I2C device is missing." >&2
        return 1
    fi

    LORA_DEVICE="$selected_device"
    LORA_I2C_DEVICE="$i2c_device"
    echo "WM1302 carrier mapping: SPI=$LORA_DEVICE I2C=$LORA_I2C_DEVICE"
}
