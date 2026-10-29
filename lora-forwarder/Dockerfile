# FAI WM1302 LoRaWAN packet forwarder
#
# Semtech SX1302 HAL:
#   v2.1.0 / commit 4b42025
#
# Base image is pinned to a dated Debian Bookworm image and digest.
# The Semtech source is also pinned rather than following master.

FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS builder

ARG SX1302_HAL_COMMIT=4b42025
ARG LORA_I2C_DEVICE=/dev/i2c-3

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

# Compile the auxiliary I2C path selected for this carrier.
# Original mapping: /dev/i2c-3; alternative mapping: /dev/i2c-6.
RUN set -eux; \
    case "$LORA_I2C_DEVICE" in /dev/i2c-3|/dev/i2c-6) ;; *) exit 1 ;; esac; \
    echo "I2C definition before patch:"; \
    grep -n 'I2C_DEVICE' libloragw/inc/loragw_i2c.h; \
    sed -E -i \
        "s|^([[:space:]]*#define[[:space:]]+I2C_DEVICE[[:space:]]+)\"[^\"]+\"|\\1\"${LORA_I2C_DEVICE}\"|" \
        libloragw/inc/loragw_i2c.h; \
    echo "I2C definition after patch:"; \
    grep -n 'I2C_DEVICE' libloragw/inc/loragw_i2c.h; \
    grep -Eq \
        "^[[:space:]]*#define[[:space:]]+I2C_DEVICE[[:space:]]+\"${LORA_I2C_DEVICE}\"" \
        libloragw/inc/loragw_i2c.h

RUN make clean all

# Prepare runtime payload.
RUN mkdir -p /out && \
    cp packet_forwarder/lora_pkt_fwd /out/ && \
    cp packet_forwarder/global_conf.json.sx1250.EU868 /out/global_conf.json.sx1250.EU868 && \
    cp util_chip_id/chip_id /out/ && \
    cp LICENSE.TXT /out/ && \
    printf '%s\n' "$LORA_I2C_DEVICE" > /out/i2c-device

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
