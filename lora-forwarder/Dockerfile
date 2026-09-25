# FAI WM1302 LoRaWAN packet forwarder
#
# Semtech SX1302 HAL:
#   v2.1.0 / commit 4b42025
#
# Base image is pinned to a dated Debian Bookworm image and digest.
# The Semtech source is also pinned rather than following master.

FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS builder

ARG SX1302_HAL_COMMIT=4b42025

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        build-essential \
        pkg-config \
        libusb-1.0-0-dev \
        libi2c-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/Lora-net/sx1302_hal.git /src/sx1302_hal && \
    cd /src/sx1302_hal && \
    git checkout "${SX1302_HAL_COMMIT}" && \
    echo "Building sx1302_hal commit $(git rev-parse HEAD)"

WORKDIR /src/sx1302_hal

# reComputer R1000 carrier mapping:
# WM1302 auxiliary I2C is exposed on /dev/i2c-3.
RUN set -eux; \
    echo "I2C definition before patch:"; \
    grep -n 'I2C_DEVICE' libloragw/inc/loragw_i2c.h; \
    sed -E -i \
        's|^([[:space:]]*#define[[:space:]]+I2C_DEVICE[[:space:]]+)"[^"]+"|\1"/dev/i2c-3"|' \
        libloragw/inc/loragw_i2c.h; \
    echo "I2C definition after patch:"; \
    grep -n 'I2C_DEVICE' libloragw/inc/loragw_i2c.h; \
    grep -Eq \
        '^[[:space:]]*#define[[:space:]]+I2C_DEVICE[[:space:]]+"/dev/i2c-3"' \
        libloragw/inc/loragw_i2c.h

RUN make clean all

# Prepare runtime payload.
RUN mkdir -p /out && \
    cp packet_forwarder/lora_pkt_fwd /out/ && \
    cp packet_forwarder/global_conf.json.sx1250.EU868 /out/global_conf.json.sx1250.EU868 && \
    cp util_chip_id/chip_id /out/ && \
    cp LICENSE.TXT /out/

# Patch SPI device to match the reComputer R1000 LoRa slot.
RUN sed -i \
        's|"/dev/spidev0.0"|"\/dev\/spidev0.1"|' \
        /out/global_conf.json.sx1250.EU868 && \
    grep -n '"com_type"\|"com_path"' \
        /out/global_conf.json.sx1250.EU868 | head


FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/lora

COPY --from=builder /out/ /opt/lora/
COPY reset_lgw.sh /opt/lora/reset_lgw.sh
COPY entrypoint.sh /opt/lora/entrypoint.sh

RUN chmod 0755 \
    /opt/lora/lora_pkt_fwd \
    /opt/lora/chip_id \
    /opt/lora/reset_lgw.sh \
    /opt/lora/entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
