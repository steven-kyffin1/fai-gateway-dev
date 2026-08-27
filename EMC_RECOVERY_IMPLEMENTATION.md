# FAI Birdbox Gateway GEN 2 — focused EMC recovery integration

## Purpose and limits

This revision applies the recovery-critical changes to the complete branch supplied on 10 August 2026. It preserves the existing gateway application and is intended for the hardware-remediation build and EMC pre-compliance/retest work.

Software recovery is important for the ESD transient criterion because the system must resume without operator intervention. It does not erase an interruption during radiated RF immunity: where Criterion A applies, loss of TinyMesh communication during the continuous RF field is still a performance deviation even if software restores it quickly. Hardware shielding, bonding, isolation and transient protection remain necessary, and the laboratory determines compliance.

## What changed

### TinyMesh and wM-Bus recovery

The existing serial inputs and all existing parsers remain in place. Added Node-RED nodes:

1. Observe the status of each serial input.
2. On a serial error, close only the affected port, wait one second and reopen it.
3. Publish a timestamped event to `gateway/<gateway-id>/health/recovery`.
4. Record the most recent valid input for functional health reporting.
5. During controlled EMC mode only, request serial recovery after ten seconds without expected test data.

A new `GET /healthz` endpoint returns HTTP 200 when the radio interfaces are healthy and HTTP 503 when a persistent serial fault is present. During EMC mode, continuous-test-data freshness is included in this assessment. Outside EMC mode, a quiet passive receiver is not incorrectly treated as failed.

### Independent host escalation

`fai-radio-recovery.service` operates outside Docker and Node-RED. It:

- verifies whether a Node-RED serial reopen actually cleared the fault;
- restarts only Node-RED if continuous EMC test data remains stale for 18 seconds;
- re-enumerates only the identity-checked affected FTDI radio after 30 seconds and restarts Node-RED;
- restarts Node-RED when a detached radio returns;
- restarts the relevant Modbus service after an isolated RS485 USB channel returns;
- restarts the local MQTT broker if the independent subscriber remains disconnected;
- writes evidence to `/opt/fai-storage/emc/recovery.log`.

Host reboot remains disabled with `ALLOW_HOST_REBOOT=false`. Do not enable it for radiated RF testing: rebooting during a continuous Criterion A test would itself be a failure.

### Isolated two-channel RS485 converter

The software now uses:

| Physical function | Device link | Container/TCP |
|---|---|---|
| Converter channel 1 — power meters | `/dev/RS485_ISO_1` | `fai-mbusd`, port 5020, 9600 8N1 |
| Converter channel 2 — shared silo bus | `/dev/RS485_ISO_2` | `fai-mbusd-silo`, port 5021, 19200 8N1 |

The previous separate silo-1 and silo-2 USB services have been replaced by one shared silo service. Node-RED uses silo 1 as Modbus unit 1 and silo 2 as Modbus unit 2.

Do not connect both silos to channel 2 until silo 2 has been configured and proved as address 2. If the devices cannot have unique addresses, they cannot share this bus.

The udev rule assumes FT2232 interface `00` is converter channel 1 and interface `01` is channel 2. Confirm this once on the actual unit. If the terminal labels enumerate in the opposite order, swap only the two `RS485_ISO_*` names in `udev/99-fai-gateway-devices.rules`.

### Three-second radiated-RF dwell coverage

The original Node-RED branch was already faster than 2.5 seconds:

- power-meter polling is triggered every 1 second;
- the normal silo-1 and silo-2 reads are each triggered every 1 second;
- the dedicated Silo 1 EMC flow is also triggered every 1 second.

This provides nominally three Modbus polling opportunities during each 3-second RF dwell. Actual responses still share and queue on their respective RS485 bus, so the evidence monitor records the received-message time rather than assuming every request succeeded.

The EMC monitor samples once per second, records message age both in seconds and equivalent 3-second dwell periods, and treats a 3-second loss of power or silo telemetry as stale. TinyMesh and wM-Bus retain 10-second and 6-second stale thresholds because those receivers depend on the real transmitter cadence. To identify susceptibility against an individual 3-second frequency step, use controlled TinyMesh and wM-Bus transmitters sending at least once per second if their firmware permits it. If they cannot transmit that frequently, exact single-step attribution must use the laboratory's applied-frequency timestamps.

The 10/18/30-second recovery stages are not the dwell-time detector. They exist to restore a persistently stuck interface after a disturbance. A communication loss during even one 3-second dwell remains a Criterion A deviation where continuous operation is required.

### Minimal AudioMoth function included in the EUT

AudioMoth is included through the final USB hub, female panel bulkhead and production USB extension. It must be flashed with the official AudioMoth USB Microphone firmware so Linux sees it as a USB microphone.

The minimum implemented function is intentionally small:

- 48 kHz, 16-bit, mono WAV recording using ALSA `arecord`;
- normal operation: 30 seconds of recording every 5 minutes;
- EMC mode: consecutive 60-second recordings throughout the complete sweep;
- completed recordings stored in `/opt/fai-storage/audio`;
- an in-progress recording uses a temporary filename and is published only after its duration and size are validated;
- USB/audio errors are logged and retried automatically after 5 seconds;
- health and latest-file information are exposed to the EMC monitor.

There is no cloud upload, sound analysis or user interface in this test implementation. Continuous EMC-mode recording is needed so every 3-second dwell actually exercises the AudioMoth, bulkhead, extension, USB hub and storage path.

### UPS watchdog

The UPS dependencies are built into a local image instead of being downloaded at every container start. Repeated I2C errors reopen the bus, the RTC wake-alarm and halt request are checked, and a health file allows Autoheal to restart a wedged watchdog.

### EMC evidence monitor

The supplied monitor now records:

- container state, health and restart count;
- TCP endpoints;
- MQTT message age and count;
- required USB device presence;
- Node-RED functional health;
- AudioMoth recording state, completed-file details and errors;
- message age expressed in both seconds and 3-second RF dwell periods;
- every published recovery event.

The main test log remains `/opt/fai-storage/emc/emc_test.log`.

## Deliberately unchanged

This focused revision does not alter:

- TinyMesh or wM-Bus parsing and outgoing payloads;
- application/dashboard logic;
- ChirpStack EU868 configuration or LoRaWAN provisioning;
- Mosquitto cloud-bridge topics or credentials;
- RUT140 configuration;
- radio frequencies or permitted laboratory exclusion bands.

## PC review before transfer

Review the focused diff and retain the original archive:

```bash
diff -ru --exclude=flows_cred.json zero-touch-emc-lvd-original zero-touch-emc-lvd-recovery
```

The credential file has not been changed or displayed by this work.

## Installation on the gateway

Do not rerun the complete bootstrap merely to add recovery to an existing gateway. The complete bootstrap includes operating-system, network and storage provisioning. Use the focused installer:

```bash
cd /path/to/zero-touch-emc-lvd-recovery
sudo ./scripts/install_recovery.sh --install-only
```

This installs dependencies, systemd units, udev rules and the restricted USB helper. It preserves existing `.env` values, appending only missing recovery defaults, and does not restart the stack.

Flash the AudioMoth USB Microphone firmware and connect it through the exact final hub, panel bulkhead and USB extension. With the converter, radios and AudioMoth connected, check:

```bash
lsusb -d 0403:6010
ls -l /dev/RS485_ISO_1 /dev/RS485_ISO_2
readlink -f /dev/RS485_ISO_1
readlink -f /dev/RS485_ISO_2
readlink -f /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B401GJOI-if00-port0
readlink -f /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B400T7S7-if00-port0
arecord -l
arecord -L | grep -i -A2 -B2 AudioMoth
```

Prove which converter terminal channel corresponds to each Linux link. Confirm the meter bus is 9600 8N1, the silo bus is 19200 8N1, silo 1 is unit 1 and silo 2 is unit 2.

Then validate and activate:

```bash
docker compose config
sudo ./scripts/install_recovery.sh --activate
docker compose ps
systemctl status fai-radio-recovery.service --no-pager
systemctl status fai-audiomoth.service --no-pager
curl -sS -i http://127.0.0.1:1880/healthz
```

Expected normal result: all core containers running/healthy, both host services active, a valid WAV appearing under `/opt/fai-storage/audio`, and `/healthz` HTTP 200.

## Controlled dry-run and EMC mode

Use active TinyMesh and wM-Bus test transmitters at no more than 1-second intervals if their firmware supports this. Otherwise document their actual intervals for the laboratory. Then enable the silence-based checks and continuous AudioMoth recording:

```bash
sudo ./scripts/set_emc_mode.sh on
set -a
. ./.env
set +a
sudo -E ./emc_monitor.py --no-colour
```

Confirm before starting the sweep:

```bash
systemctl status fai-audiomoth.service --no-pager
tail -n 20 /opt/fai-storage/emc/audiomoth.log
find /opt/fai-storage/audio -maxdepth 1 -name 'audiomoth_*.wav' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | tail
```

In another terminal, perform controlled recovery checks one at a time:

```bash
sudo /usr/local/sbin/fai-usb-recover tinymesh
sudo /usr/local/sbin/fai-usb-recover wmbus
docker restart fai-nodered
docker restart fai-mqtt
```

For each event, verify that:

- no person uses the Node-RED editor or power-cycles the gateway;
- the affected data stream resumes;
- `/healthz` returns HTTP 200 again;
- `recovery.log` contains the action and result;
- `emc_test.log` contains the outage and recovery timestamps;
- no restart loop occurs;
- AudioMoth returns to `recording` automatically and later completes a valid WAV;
- previously completed WAV files remain unchanged;
- stored configuration and earlier data remain intact.

Also disconnect/reconnect the isolated converter once in a controlled bench test. Both stable RS485 links must return and both Modbus TCP services must become healthy. Prove both silo unit IDs separately.

After the dry run or laboratory session:

```bash
sudo ./scripts/set_emc_mode.sh off
```

Serial-error, USB reattach, MQTT and container recovery remain enabled in normal mode; only silence-based assumptions are disabled. AudioMoth returns to its minimal 30-second-every-5-minutes schedule.

## Retest acceptance targets

Agree the exact performance criteria with the laboratory before testing. Engineering targets for the dry run are:

- ESD: temporary degradation only if permitted; automatic recovery with no operator intervention and no persistent state/data loss.
- Radiated RF: no loss of required communication during the applied field where Criterion A applies. Recovery logs are diagnostic evidence, not a substitute for continuous operation.
- AudioMoth radiated RF: uninterrupted recording throughout the sweep, with consecutive valid files. AudioMoth ESD: completed files preserved and recording resumes automatically; agree beforehand whether loss of only the in-progress segment is permissible.
- No gateway host reboot during either official immunity test.
- All applied-frequency, discharge-polarity and test-time markers supplied by the laboratory are recorded against the gateway logs.

If TinyMesh is again affected far outside 868 MHz, investigate cable/common-mode, enclosure bonding, connector-shell current and power/USB coupling. Do not ask the laboratory to discount all non-868 MHz failures merely because the intended radio is EU868.

Official AudioMoth references:

- https://www.openacousticdevices.info/live
- https://www.openacousticdevices.info/support/announcements/audiomoth-flash-app-1-5-0
