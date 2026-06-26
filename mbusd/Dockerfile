FROM alpine:latest AS builder
RUN apk add --no-cache git cmake build-base linux-headers pkgconf bash
RUN git clone https://github.com/3cky/mbusd.git /tmp/mbusd && \
    cd /tmp/mbusd && mkdir build && cd build && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr .. && \
    make && make install

FROM alpine:latest
RUN apk add --no-cache libstdc++ && \
    addgroup -S dialout || true && \
    adduser root dialout

COPY --from=builder /usr/bin/mbusd /usr/bin/mbusd

# Set a fallback, but allow docker-compose to override it
ENV RS485_PORT="/dev/ttyACM0"

# Use 'sh -c' so the environment variable expands correctly when the container boots
CMD sh -c "mbusd -d -p ${RS485_PORT} -s 9600 -m 8N1 -P 5020"