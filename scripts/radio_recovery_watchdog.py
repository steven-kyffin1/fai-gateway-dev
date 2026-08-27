#!/usr/bin/env python3
"""FAI gateway host-level radio recovery supervisor.

Node-RED performs the first recovery stage by closing and reopening the
affected serial port.  This host service provides the independent escalation
path that still works if Node-RED is alive but its flows are wedged:

1. Wait for Node-RED's serial reopen stage.
2. Restart only the Node-RED container.
3. Re-enumerate only the affected USB receiver, then restart Node-RED.
4. Optionally reboot the host as a deliberately disabled last resort.

Data-age recovery is enabled only in EMC_TEST_MODE, where continuous test
transmitters are a controlled part of the test setup.  Production recovery is
still triggered by serial errors inside Node-RED and by USB detach/reattach
events observed here.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Any
import urllib.error
import urllib.request

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: install python3-paho-mqtt", file=sys.stderr)
    raise


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default


MQTT_HOST = os.getenv("RECOVERY_MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.getenv("RECOVERY_MQTT_PORT", "1883"))
MQTT_RESTART_AFTER = env_float("RECOVERY_MQTT_RESTART_AFTER", 15.0)
MQTT_RESTART_COOLDOWN = env_float("RECOVERY_MQTT_RESTART_COOLDOWN", 60.0)

EMC_TEST_MODE = env_bool("EMC_TEST_MODE", False)
STARTUP_GRACE = env_float("RECOVERY_STARTUP_GRACE_SECONDS", 30.0)
DATA_STALE_AFTER = env_float("RECOVERY_DATA_STALE_SECONDS", 10.0)
NODERED_RESTART_AFTER = env_float("RECOVERY_NODERED_RESTART_SECONDS", 18.0)
USB_RESET_AFTER = env_float("RECOVERY_USB_RESET_SECONDS", 30.0)
HOST_REBOOT_AFTER = env_float("RECOVERY_HOST_REBOOT_SECONDS", 60.0)
ACTION_COOLDOWN = env_float("RECOVERY_ACTION_COOLDOWN_SECONDS", 60.0)
ALLOW_HOST_REBOOT = env_bool("ALLOW_HOST_REBOOT", False)
SERIAL_VERIFY_AFTER = env_float("RECOVERY_SERIAL_VERIFY_SECONDS", 12.0)
SERIAL_VERIFY_MAX_WAIT = env_float("RECOVERY_SERIAL_VERIFY_MAX_WAIT_SECONDS", 45.0)
NODERED_HEALTH_URL = os.getenv(
    "NODERED_HEALTH_URL", "http://127.0.0.1:1880/healthz"
)

NODERED_CONTAINER = os.getenv("NODERED_CONTAINER", "fai-nodered")
MQTT_CONTAINER = os.getenv("MQTT_CONTAINER", "fai-mqtt")
USB_HELPER = os.getenv("USB_RECOVERY_HELPER", "/usr/local/sbin/fai-usb-recover")
LOG_PATH = Path(
    os.getenv(
        "RECOVERY_LOG_PATH",
        "/opt/fai-storage/emc/recovery.log",
    )
)

INTERFACES = {
    "tinymesh": {
        "topic": "gateway/+/tinymesh/out",
        "device": os.getenv(
            "TINY_SERIAL_DEVICE",
            "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B401GJOI-if00-port0",
        ),
        "usb_target": "tinymesh",
    },
    "wmbus": {
        "topic": "gateway/+/wmbus/out",
        "device": os.getenv(
            "WMBUS_SERIAL_DEVICE",
            "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B400T7S7-if00-port0",
        ),
        "usb_target": "wmbus",
    },
}

AUXILIARY_USB_DEVICES = {
    "rs485-meter": {
        "device": os.getenv("RS485_METER_DEVICE", "/dev/RS485_ISO_1"),
        "container": os.getenv("RS485_METER_CONTAINER", "fai-mbusd"),
    },
    "rs485-silo": {
        "device": os.getenv("RS485_SILO_DEVICE", "/dev/RS485_ISO_2"),
        "container": os.getenv("RS485_SILO_CONTAINER", "fai-mbusd-silo"),
    },
}


LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)sZ %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
    ],
)
logging.Formatter.converter = time.gmtime
LOGGER = logging.getLogger("fai-radio-recovery")


class RecoveryState:
    def __init__(self, started: float) -> None:
        self.last_seen: float | None = None
        self.incident_anchor = started
        self.stage = 0
        self.was_present: bool | None = None
        self.missing_since: float | None = None

    def mark_seen(self, now: float) -> bool:
        recovered = self.stage > 0
        self.last_seen = now
        self.incident_anchor = now
        self.stage = 0
        return recovered

    def age(self, now: float) -> float:
        return now - (self.last_seen or self.incident_anchor)


STARTED_MONOTONIC = time.monotonic()
STATES = {name: RecoveryState(STARTED_MONOTONIC) for name in INTERFACES}
AUXILIARY_STATES = {
    name: RecoveryState(STARTED_MONOTONIC) for name in AUXILIARY_USB_DEVICES
}
LOCK = threading.Lock()
STOP = threading.Event()
MQTT_CONNECTED = False
MQTT_DISCONNECTED_SINCE: float | None = STARTED_MONOTONIC
LAST_MQTT_RESTART = 0.0
LAST_NODERED_RESTART = 0.0
LAST_USB_RESET = 0.0
PENDING_SERIAL_VERIFY: dict[str, float] = {}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def topic_matches(pattern: str, topic: str) -> bool:
    try:
        return mqtt.topic_matches_sub(pattern, topic)
    except AttributeError:
        pattern_parts = pattern.split("/")
        topic_parts = topic.split("/")
        if len(pattern_parts) != len(topic_parts):
            return False
        return all(p == "+" or p == t for p, t in zip(pattern_parts, topic_parts))


def run_command(command: list[str], timeout: float = 30.0) -> bool:
    LOGGER.info("ACTION command=%s", json.dumps(command))
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        LOGGER.error("ACTION_FAILED command=%s error=%s", command, exc)
        return False

    if completed.returncode != 0:
        LOGGER.error(
            "ACTION_FAILED command=%s rc=%s stdout=%r stderr=%r",
            command,
            completed.returncode,
            completed.stdout[-500:],
            completed.stderr[-500:],
        )
        return False

    LOGGER.info("ACTION_OK command=%s", json.dumps(command))
    return True


def tcp_ready(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_for_tcp(host: str, port: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline and not STOP.is_set():
        if tcp_ready(host, port):
            return True
        STOP.wait(1.0)
    return False


def restart_container(name: str) -> bool:
    return run_command(["/usr/bin/docker", "restart", "-t", "10", name], timeout=30.0)


def restart_mqtt(now: float) -> None:
    global LAST_MQTT_RESTART
    if now - LAST_MQTT_RESTART < MQTT_RESTART_COOLDOWN:
        return
    LAST_MQTT_RESTART = now
    LOGGER.warning("RECOVERY mqtt_restart reason=subscriber_disconnected")
    if restart_container(MQTT_CONTAINER):
        wait_for_tcp(MQTT_HOST, MQTT_PORT, 15.0)


def restart_nodered(reason: str, stale_names: list[str], now: float) -> bool:
    global LAST_NODERED_RESTART
    if now - LAST_NODERED_RESTART < ACTION_COOLDOWN:
        LOGGER.warning(
            "RECOVERY_SKIPPED action=nodered_restart reason=cooldown interfaces=%s",
            ",".join(stale_names),
        )
        return False

    LAST_NODERED_RESTART = now
    LOGGER.warning(
        "RECOVERY action=nodered_restart reason=%s interfaces=%s",
        reason,
        ",".join(stale_names),
    )
    return restart_container(NODERED_CONTAINER)


def reset_usb(stale_names: list[str], now: float) -> set[str]:
    global LAST_USB_RESET, LAST_NODERED_RESTART
    if now - LAST_USB_RESET < ACTION_COOLDOWN:
        return set()

    helper = Path(USB_HELPER)
    if not helper.is_file():
        LOGGER.error("USB_HELPER_MISSING path=%s", helper)
        return set()

    LAST_USB_RESET = now
    successful: set[str] = set()
    for name in stale_names:
        target = str(INTERFACES[name]["usb_target"])
        LOGGER.warning("RECOVERY action=usb_reset interface=%s", name)
        if run_command([str(helper), target], timeout=20.0):
            successful.add(name)

    if successful:
        # Do not let the previous restart cooldown prevent the restart required
        # after a USB device has been re-enumerated.
        LAST_NODERED_RESTART = 0.0
        restart_nodered("usb_reenumerated", sorted(successful), time.monotonic())
    return successful


def read_nodered_health() -> tuple[int | None, dict[str, Any] | None]:
    try:
        with urllib.request.urlopen(NODERED_HEALTH_URL, timeout=2.0) as response:
            status = response.status
            body = response.read(100_000)
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = exc.read(100_000)
    except (OSError, urllib.error.URLError):
        return None, None

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = None
    return status, payload if isinstance(payload, dict) else None


def verify_serial_recovery(now: float) -> None:
    with LOCK:
        due = {
            name: started
            for name, started in PENDING_SERIAL_VERIFY.items()
            if now - started >= SERIAL_VERIFY_AFTER
        }

    if not due:
        return

    status, health = read_nodered_health()
    escalate: list[str] = []
    for name, started in due.items():
        age = now - started
        interface_health = health.get(name) if health else None
        startup_grace = bool(health and health.get("startup_grace"))
        serial_bad = bool(
            isinstance(interface_health, dict)
            and interface_health.get("serial_bad") is True
        )

        if health and not startup_grace and not serial_bad:
            with LOCK:
                PENDING_SERIAL_VERIFY.pop(name, None)
            LOGGER.info("SERIAL_RECOVERY_VERIFIED interface=%s status=%s", name, status)
            continue

        if age < SERIAL_VERIFY_MAX_WAIT and (startup_grace or status is None):
            continue

        LOGGER.warning(
            "SERIAL_RECOVERY_ESCALATION interface=%s status=%s serial_bad=%s age=%.1f",
            name,
            status,
            serial_bad,
            age,
        )
        escalate.append(name)

    successful = reset_usb(escalate, now) if escalate else set()
    if successful:
        with LOCK:
            for name in successful:
                PENDING_SERIAL_VERIFY.pop(name, None)


def request_host_reboot(stale_names: list[str]) -> bool:
    LOGGER.critical(
        "RECOVERY action=host_reboot interfaces=%s enabled=%s",
        ",".join(stale_names),
        ALLOW_HOST_REBOOT,
    )
    if ALLOW_HOST_REBOOT:
        return run_command(["/usr/bin/systemctl", "reboot"], timeout=10.0)
    return False


def on_connect(
    client: mqtt.Client,
    userdata: Any,
    flags: Any,
    reason_code: Any,
    properties: Any = None,
) -> None:
    del userdata, flags, properties
    global MQTT_CONNECTED, MQTT_DISCONNECTED_SINCE
    try:
        success = int(reason_code) == 0
    except (TypeError, ValueError):
        success = str(reason_code).lower() in {"0", "success"}

    with LOCK:
        MQTT_CONNECTED = success
        MQTT_DISCONNECTED_SINCE = None if success else time.monotonic()

    if success:
        for config in INTERFACES.values():
            client.subscribe(str(config["topic"]), qos=0)
        client.subscribe("gateway/+/health/recovery", qos=1)
        LOGGER.info("MQTT_CONNECTED host=%s port=%s", MQTT_HOST, MQTT_PORT)
    else:
        LOGGER.error("MQTT_CONNECT_FAILED reason=%s", reason_code)


def on_disconnect(client: mqtt.Client, userdata: Any, *args: Any) -> None:
    del client, userdata, args
    global MQTT_CONNECTED, MQTT_DISCONNECTED_SINCE
    with LOCK:
        MQTT_CONNECTED = False
        if MQTT_DISCONNECTED_SINCE is None:
            MQTT_DISCONNECTED_SINCE = time.monotonic()
    LOGGER.warning("MQTT_DISCONNECTED")


def on_message(client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
    del client, userdata
    now = time.monotonic()

    if topic_matches("gateway/+/health/recovery", msg.topic):
        decoded = msg.payload.decode("utf-8", errors="replace")
        LOGGER.warning(
            "NODERED_RECOVERY_EVENT topic=%s payload=%s",
            msg.topic,
            decoded[:1000],
        )
        try:
            event = json.loads(decoded)
        except json.JSONDecodeError:
            event = {}
        if (
            isinstance(event, dict)
            and event.get("interface") in INTERFACES
            and event.get("source") == "serial_status"
            and event.get("action") == "serial_reopen"
        ):
            with LOCK:
                PENDING_SERIAL_VERIFY[str(event["interface"])] = now
        return

    with LOCK:
        for name, config in INTERFACES.items():
            if topic_matches(str(config["topic"]), msg.topic):
                recovered = STATES[name].mark_seen(now)
                if recovered:
                    LOGGER.info("RECOVERED interface=%s timestamp=%s", name, utc_now())
                break


def create_mqtt_client() -> mqtt.Client:
    try:
        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id="fai-radio-recovery",
        )
    except AttributeError:
        client = mqtt.Client(client_id="fai-radio-recovery")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=10)
    return client


def check_usb_presence(now: float) -> None:
    restart_required: list[str] = []
    with LOCK:
        for name, config in INTERFACES.items():
            state = STATES[name]
            present = Path(str(config["device"])).exists()

            if state.was_present is None:
                state.was_present = present
                if not present:
                    state.missing_since = now
                    LOGGER.warning("USB_MISSING interface=%s device=%s", name, config["device"])
                continue

            if state.was_present and not present:
                state.missing_since = now
                LOGGER.warning("USB_DETACHED interface=%s device=%s", name, config["device"])
            elif not state.was_present and present:
                missing_for = now - (state.missing_since or now)
                LOGGER.warning(
                    "USB_REATTACHED interface=%s missing_seconds=%.1f",
                    name,
                    missing_for,
                )
                restart_required.append(name)
                state.missing_since = None

            state.was_present = present

    if restart_required:
        restart_nodered("usb_reattached", restart_required, now)

    auxiliary_restarts: list[tuple[str, str]] = []
    with LOCK:
        for name, config in AUXILIARY_USB_DEVICES.items():
            state = AUXILIARY_STATES[name]
            present = Path(str(config["device"])).exists()

            if state.was_present is None:
                state.was_present = present
                if not present:
                    state.missing_since = now
                    LOGGER.warning(
                        "USB_MISSING interface=%s device=%s", name, config["device"]
                    )
                continue

            if state.was_present and not present:
                state.missing_since = now
                LOGGER.warning("USB_DETACHED interface=%s device=%s", name, config["device"])
            elif not state.was_present and present:
                missing_for = now - (state.missing_since or now)
                LOGGER.warning(
                    "USB_REATTACHED interface=%s missing_seconds=%.1f",
                    name,
                    missing_for,
                )
                auxiliary_restarts.append((name, str(config["container"])))
                state.missing_since = None

            state.was_present = present

    for name, container in auxiliary_restarts:
        LOGGER.warning(
            "RECOVERY action=container_restart reason=usb_reattached interface=%s container=%s",
            name,
            container,
        )
        restart_container(container)


def evaluate_recovery(now: float) -> None:
    global MQTT_DISCONNECTED_SINCE

    with LOCK:
        connected = MQTT_CONNECTED
        disconnected_since = MQTT_DISCONNECTED_SINCE

    if not connected:
        if disconnected_since is None:
            with LOCK:
                MQTT_DISCONNECTED_SINCE = now
            disconnected_since = now
        if now - disconnected_since >= MQTT_RESTART_AFTER:
            restart_mqtt(now)
        return

    verify_serial_recovery(now)

    if not EMC_TEST_MODE or now - STARTED_MONOTONIC < STARTUP_GRACE:
        return

    with LOCK:
        stale_names = [
            name
            for name, state in STATES.items()
            if state.age(now) >= DATA_STALE_AFTER
        ]
        ages = {name: STATES[name].age(now) for name in stale_names}

    if not stale_names:
        return

    oldest_age = max(ages.values())
    LOGGER.warning(
        "DATA_STALE interfaces=%s ages=%s",
        ",".join(stale_names),
        json.dumps({name: round(age, 1) for name, age in ages.items()}),
    )

    with LOCK:
        minimum_stage = min(STATES[name].stage for name in stale_names)

    if (
        ALLOW_HOST_REBOOT
        and oldest_age >= HOST_REBOOT_AFTER
        and minimum_stage >= 2
        and minimum_stage < 3
    ):
        reboot_requested = request_host_reboot(stale_names)
        with LOCK:
            for name in stale_names:
                STATES[name].stage = 3 if reboot_requested else 1
        return

    if oldest_age >= USB_RESET_AFTER:
        with LOCK:
            reset_targets = [
                name for name in stale_names if STATES[name].stage < 2
            ]
        # With host reboot disabled, a still-stale receiver gets another
        # restricted reset after the action cooldown rather than becoming
        # permanently stuck at the last escalation stage.
        if not reset_targets and not ALLOW_HOST_REBOOT:
            reset_targets = stale_names
        successful = reset_usb(reset_targets, now) if reset_targets else set()
        if successful:
            with LOCK:
                for name in successful:
                    STATES[name].stage = max(STATES[name].stage, 2)
        return

    if oldest_age >= NODERED_RESTART_AFTER and minimum_stage < 1:
        if restart_nodered("radio_data_stale", stale_names, now):
            with LOCK:
                for name in stale_names:
                    STATES[name].stage = max(STATES[name].stage, 1)


def main() -> int:
    LOGGER.info(
        "START emc_test_mode=%s stale=%.1fs nodered_restart=%.1fs usb_reset=%.1fs "
        "host_reboot=%.1fs allow_host_reboot=%s",
        EMC_TEST_MODE,
        DATA_STALE_AFTER,
        NODERED_RESTART_AFTER,
        USB_RESET_AFTER,
        HOST_REBOOT_AFTER,
        ALLOW_HOST_REBOOT,
    )

    def stop_handler(signum: int, frame: Any) -> None:
        del signum, frame
        STOP.set()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    client = create_mqtt_client()
    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=10)
    client.loop_start()

    try:
        while not STOP.wait(1.0):
            now = time.monotonic()
            check_usb_presence(now)
            evaluate_recovery(now)
    finally:
        client.loop_stop()
        try:
            client.disconnect()
        except Exception:
            pass
        LOGGER.info("STOP")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
