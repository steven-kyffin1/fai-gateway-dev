FROM nodered/node-red:4.1.11-22

# Pin the nodes required by the authoritative flow. In particular, the serial
# package version contains the serial-control node used for automatic reopen.
RUN npm install --unsafe-perm --no-update-notifier --no-fund \
        node-red-dashboard@3.6.6 \
        node-red-contrib-modbus@5.60.1 \
        node-red-node-serialport@2.0.3
