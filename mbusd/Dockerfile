FROM alpine:3.22 AS builder
RUN apk add --no-cache git cmake build-base linux-headers pkgconf bash
RUN git clone https://github.com/3cky/mbusd.git /tmp/mbusd && \
    cd /tmp/mbusd && mkdir build && cd build && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr .. && \
    make && make install

FROM alpine:3.22
RUN apk add --no-cache libstdc++ netcat-openbsd && \
    addgroup -S dialout || true && \
    adduser root dialout

COPY --from=builder /usr/bin/mbusd /usr/bin/mbusd

# Set a fallback, but allow docker-compose to override it
ENV RS485_PORT="/dev/ttyACM0"
ENV RS485_BAUD="9600"
ENV MBUSD_TCP_PORT="5020"

# Use 'sh -c' so the environment variable expands correctly when the container boots
CMD sh -c "mbusd -d -p ${RS485_PORT} -s ${RS485_BAUD} -m 8N1 -P ${MBUSD_TCP_PORT}"
