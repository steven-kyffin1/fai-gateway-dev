#!/usr/bin/env python3
"""Host-side EMC liveness and automatic-recovery evidence logger."""

from __future__ import annotations

import argparse
from collections import deque
import datetime as dt
import json
import os
from pathlib import Path
import socket
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

try:
    import docker
except ImportError:
    print("ERROR: install python3-docker", file=sys.stderr)
    raise


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


DEFAULT_LOG_PATH = "/opt/fai-storage/emc/emc_test.log"
POLL_INTERVAL = 1.0
LORAWAN_ENABLED = "lorawan" in os.getenv("COMPOSE_PROFILES", "").split(",")
RF_DWELL_SECONDS = float(os.getenv("EMC_RF_DWELL_SECONDS", "3"))
AUDIOMOTH_ENABLED = env_bool("AUDIOMOTH_ENABLED", True)
AUDIOMOTH_TEST_MODE = env_bool("AUDIOMOTH_TEST_MODE", False)

REQUIRED_CONTAINERS = {
    "fai-mqtt",
    "fai-watchdog",
    "ups-watchdog",
    "fai-mbusd",
    "fai-mbusd-silo",
    "fai-nodered",
}
OPTIONAL_CONTAINERS = {
    "lora-forwarder",
    "gateway-bridge",
    "chirpstack",
    "chirpstack-postgres",
    "chirpstack-redis",
}
if LORAWAN_ENABLED:
    REQUIRED_CONTAINERS |= OPTIONAL_CONTAINERS
    OPTIONAL_CONTAINERS = set()

TCP_PROBES = {
    "mqtt:1883": ("127.0.0.1", 1883),
    "nodered:1880": ("127.0.0.1", 1880),
    "modbus-meter:5020": ("127.0.0.1", 5020),
    "modbus-silo:5021": ("127.0.0.1", 5021),
}
if LORAWAN_ENABLED:
    TCP_PROBES["chirpstack:8080"] = ("127.0.0.1", 8080)

MQTT_FLOWS = {
    "lorawan": ("application/+/device/+/event/up", float(os.getenv("EMC_LORAWAN_STALE_SECONDS", "6"))),
    "tinymesh": ("gateway/+/tinymesh/out", float(os.getenv("EMC_TINYMESH_STALE_SECONDS", "10"))),
    "wmbus": ("gateway/+/wmbus/out", float(os.getenv("EMC_WMBUS_STALE_SECONDS", "6"))),
    "power": ("gateway/+/power/out", float(os.getenv("EMC_POWER_STALE_SECONDS", "3"))),
    "silo1": ("gateway/+/modbus/silo1/emc", float(os.getenv("EMC_SILO_STALE_SECONDS", "3"))),
    "silo2": ("gateway/+/silo/+/telemetry", float(os.getenv("EMC_SILO_STALE_SECONDS", "3"))),
}
required_flow_default = "tinymesh,wmbus,power,silo1,silo2" + (",lorawan" if LORAWAN_ENABLED else "")
REQUIRED_FLOWS = {
    name.strip()
    for name in os.getenv("EMC_MONITOR_REQUIRED_FLOWS", required_flow_default).split(",")
    if name.strip()
}

DEVICE_PATHS = {
    "tinymesh-usb": Path(
        os.getenv(
            "TINY_SERIAL_DEVICE",
            "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B401GJOI-if00-port0",
        )
    ),
    "wmbus-usb": Path(
        os.getenv(
            "WMBUS_SERIAL_DEVICE",
            "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_B400T7S7-if00-port0",
        )
    ),
    "rs485-meter": Path(os.getenv("RS485_METER_DEVICE", "/dev/RS485_ISO_1")),
    "rs485-silo": Path(os.getenv("RS485_SILO_DEVICE", "/dev/RS485_ISO_2")),
}

NODERED_HEALTH_URL = os.getenv(
    "NODERED_HEALTH_URL", "http://127.0.0.1:1880/healthz"
)
AUDIOMOTH_HEALTH_PATH = Path(
    os.getenv("AUDIOMOTH_HEALTH_PATH", "/run/fai-audiomoth/health.json")
)


class C:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    CYAN = "\033[96m"
    GREY = "\033[90m"


USE_COLOUR = True


def colour(value: str, code: str) -> str:
    return f"{code}{value}{C.RESET}" if USE_COLOUR else value


LOCK = threading.Lock()
LAST_SEEN: dict[str, dt.datetime | None] = {name: None for name in MQTT_FLOWS}
MESSAGE_COUNTS = {name: 0 for name in MQTT_FLOWS}
MQTT_CONNECTED = False
RECOVERY_COUNT = 0
LAST_RECOVERY: dict[str, Any] | None = None
RECOVERY_EVENTS: deque[str] = deque()


def topic_matches(pattern: str, topic: str) -> bool:
    try:
        return mqtt.topic_matches_sub(pattern, topic)
    except AttributeError:
        patterns = pattern.split("/")
        actual = topic.split("/")
        return len(patterns) == len(actual) and all(
            expected == "+" or expected == observed
            for expected, observed in zip(patterns, actual)
        )


def reason_success(reason_code: Any) -> bool:
    try:
        return int(reason_code) == 0
    except (TypeError, ValueError):
        return str(reason_code).lower() in {"0", "success"}


def on_connect(
    client: mqtt.Client,
    userdata: Any,
    flags: Any,
    reason_code: Any,
    properties: Any = None,
) -> None:
    del userdata, flags, properties
    global MQTT_CONNECTED
    connected = reason_success(reason_code)
    with LOCK:
        MQTT_CONNECTED = connected
    if connected:
        for topic, _ in MQTT_FLOWS.values():
            client.subscribe(topic, qos=0)
        client.subscribe("gateway/+/health/recovery", qos=1)


def on_disconnect(client: mqtt.Client, userdata: Any, *args: Any) -> None:
    del client, userdata, args
    global MQTT_CONNECTED
    with LOCK:
        MQTT_CONNECTED = False


def on_message(client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
    del client, userdata
    global RECOVERY_COUNT, LAST_RECOVERY
    now = dt.datetime.now(dt.timezone.utc)

    if topic_matches("gateway/+/health/recovery", msg.topic):
        decoded = msg.payload.decode("utf-8", errors="replace")
        try:
            payload: Any = json.loads(decoded)
        except json.JSONDecodeError:
            payload = {"raw": decoded[:1000]}
        event = {
            "observed_at": now.isoformat(),
            "topic": msg.topic,
            "payload": payload,
        }
        with LOCK:
            RECOVERY_COUNT += 1
            LAST_RECOVERY = event
            RECOVERY_EVENTS.append("EVENT recovery=" + json.dumps(event, separators=(",", ":")))
        return

    with LOCK:
        for name, (pattern, _) in MQTT_FLOWS.items():
            if topic_matches(pattern, msg.topic):
                LAST_SEEN[name] = now
                MESSAGE_COUNTS[name] += 1
                break


def create_mqtt_client(host: str, port: int) -> mqtt.Client:
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="emc-monitor")
    except AttributeError:
        client = mqtt.Client(client_id="emc-monitor")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=10)
    client.connect_async(host, port, keepalive=10)
    client.loop_start()
    return client


def check_containers(client: Any) -> dict[str, dict[str, Any]]:
    names = REQUIRED_CONTAINERS | OPTIONAL_CONTAINERS
    results: dict[str, dict[str, Any]] = {}
    try:
        available = {item.name: item for item in client.containers.list(all=True)}
        for name in sorted(names):
            if name not in available:
                results[name] = {
                    "state": "optional-missing" if name in OPTIONAL_CONTAINERS else "missing",
                    "health": None,
                    "restarts": None,
                    "ok": name in OPTIONAL_CONTAINERS,
                }
                continue
            container = available[name]
            container.reload()
            health = container.attrs.get("State", {}).get("Health", {}).get("Status")
            state = container.status
            results[name] = {
                "state": state,
                "health": health,
                "restarts": int(container.attrs.get("RestartCount", 0)),
                "ok": state == "running" and health != "unhealthy",
            }
    except Exception as exc:
        for name in names:
            results[name] = {
                "state": "error",
                "health": str(exc),
                "restarts": None,
                "ok": False,
            }
    return results


def check_tcp(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def check_flows() -> dict[str, dict[str, Any]]:
    now = dt.datetime.now(dt.timezone.utc)
    results: dict[str, dict[str, Any]] = {}
    with LOCK:
        for name, (_, stale_after) in MQTT_FLOWS.items():
            seen = LAST_SEEN[name]
            age = None if seen is None else (now - seen).total_seconds()
            state = "waiting" if age is None else ("live" if age <= stale_after else "stale")
            required = name in REQUIRED_FLOWS
            results[name] = {
                "state": state,
                "age": age,
                "age_dwells": None if age is None else round(age / RF_DWELL_SECONDS, 2),
                "limit": stale_after,
                "count": MESSAGE_COUNTS[name],
                "required": required,
                "ok": not required or state == "live",
            }
    return results


def check_nodered_health() -> dict[str, Any]:
    try:
        with urllib.request.urlopen(NODERED_HEALTH_URL, timeout=2) as response:
            status = response.status
            body = response.read(100_000)
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = exc.read(100_000)
    except (OSError, urllib.error.URLError) as exc:
        return {"ok": False, "status": None, "error": str(exc)}
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = None
    return {"ok": status == 200, "status": status, "payload": payload}


def check_audiomoth() -> dict[str, Any]:
    if not AUDIOMOTH_ENABLED:
        return {"enabled": False, "ok": False, "state": "disabled"}
    try:
        payload = json.loads(AUDIOMOTH_HEALTH_PATH.read_text(encoding="utf-8"))
        age = time.time() - float(payload["unix_time"])
        state = str(payload["state"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        return {"enabled": True, "ok": False, "state": "missing", "error": str(exc)}

    allowed_age = 90 if AUDIOMOTH_TEST_MODE else float(
        os.getenv("AUDIOMOTH_INTERVAL_SECONDS", "300")
    ) + float(os.getenv("AUDIOMOTH_RECORD_SECONDS", "30")) + 30
    return {
        "enabled": True,
        "ok": state in {"recording", "ok"} and age <= allowed_age,
        "state": state,
        "age": round(age, 1),
        "last_output": payload.get("output"),
        "bytes": payload.get("bytes"),
        "error": payload.get("error"),
    }


def render_line(ok: bool, label: str, detail: str) -> str:
    symbol = colour("✓", C.GREEN) if ok else colour("✗", C.RED)
    return f"  {symbol} {label:<22} {detail}"


def main() -> int:
    global USE_COLOUR
    parser = argparse.ArgumentParser(description="FAI gateway EMC liveness monitor")
    parser.add_argument("--log", default=DEFAULT_LOG_PATH)
    parser.add_argument("--interval", type=float, default=POLL_INTERVAL)
    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--no-colour", action="store_true")
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be positive")
    if RF_DWELL_SECONDS <= 0:
        parser.error("EMC_RF_DWELL_SECONDS must be positive")
    USE_COLOUR = not args.no_colour

    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = dt.datetime.now(dt.timezone.utc)
    docker_client = docker.from_env()
    mqtt_client = create_mqtt_client(args.mqtt_host, args.mqtt_port)

    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(f"\n# EMC session started {started.isoformat()}\n")
        handle.write(f"# required_flows={','.join(sorted(REQUIRED_FLOWS))}\n")
        handle.write(f"# radiated_rf_dwell_seconds={RF_DWELL_SECONDS}\n")
        handle.write(f"# audiomoth_enabled={AUDIOMOTH_ENABLED} test_mode={AUDIOMOTH_TEST_MODE}\n")

    previous_signature = ""
    iteration = 0
    try:
        while True:
            cycle_started = time.monotonic()
            timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            containers = check_containers(docker_client)
            tcp = {name: check_tcp(*address) for name, address in TCP_PROBES.items()}
            flows = check_flows()
            devices = {name: path.exists() for name, path in DEVICE_PATHS.items()}
            nodered = check_nodered_health()
            audiomoth = check_audiomoth()
            with LOCK:
                connected = MQTT_CONNECTED
                recovery_count = RECOVERY_COUNT
                last_recovery = LAST_RECOVERY
                queued_events = list(RECOVERY_EVENTS)
                RECOVERY_EVENTS.clear()

            overall = (
                all(item["ok"] for item in containers.values())
                and all(tcp.values())
                and all(item["ok"] for item in flows.values())
                and all(devices.values())
                and nodered["ok"]
                and audiomoth["ok"]
                and connected
            )

            if USE_COLOUR:
                print("\033[2J\033[H", end="")
            result_text = colour("PASS", C.GREEN) if overall else colour("FAIL", C.RED)
            print(f"{colour(timestamp, C.CYAN)}  {result_text}")
            print("\nContainers")
            for name, item in containers.items():
                detail = f"{item['state']} health={item['health'] or '-'} restarts={item['restarts']}"
                print(render_line(item["ok"], name, detail))
            print("\nPorts and Node-RED")
            for name, item_ok in tcp.items():
                print(render_line(item_ok, name, "open" if item_ok else "closed"))
            print(render_line(nodered["ok"], "nodered:/healthz", json.dumps(nodered, separators=(",", ":"))[:500]))
            print("\nData flows")
            for name, item in flows.items():
                age = "never" if item["age"] is None else f"{item['age']:.1f}s"
                dwells = "-" if item["age_dwells"] is None else f"{item['age_dwells']:.2f}"
                detail = f"{item['state']} age={age} dwells={dwells} count={item['count']} required={item['required']}"
                print(render_line(item["ok"], name, detail))
            print("\nUSB devices")
            for name, present in devices.items():
                print(render_line(present, name, "present" if present else "missing"))
            print(render_line(audiomoth["ok"], "audiomoth", json.dumps(audiomoth, separators=(",", ":"))))
            print(render_line(connected, "mqtt-subscriber", "connected" if connected else "disconnected"))
            print(f"\nRecovery events: {recovery_count}; last={json.dumps(last_recovery, separators=(',', ':'))[:500] if last_recovery else '-'}")

            record = {
                "timestamp": timestamp,
                "overall": "PASS" if overall else "FAIL",
                "containers": containers,
                "tcp": tcp,
                "flows": flows,
                "devices": devices,
                "nodered": nodered,
                "audiomoth": audiomoth,
                "radiated_rf_dwell_seconds": RF_DWELL_SECONDS,
                "mqtt_connected": connected,
                "recovery_count": recovery_count,
                "last_recovery": last_recovery,
            }
            signature = json.dumps(record, sort_keys=True, default=str)
            with log_path.open("a", encoding="utf-8") as handle:
                for event in queued_events:
                    handle.write(event + "\n")
                handle.write("SAMPLE " + json.dumps(record, separators=(",", ":"), default=str) + "\n")
                if previous_signature and signature != previous_signature:
                    handle.flush()
            previous_signature = signature
            iteration += 1
            elapsed = time.monotonic() - cycle_started
            time.sleep(max(0, args.interval - elapsed))
    except KeyboardInterrupt:
        ended = dt.datetime.now(dt.timezone.utc)
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(f"# EMC session ended {ended.isoformat()} samples={iteration}\n")
        print(f"\nStopped {ended.isoformat()}")
    finally:
        mqtt_client.loop_stop()
        try:
            mqtt_client.disconnect()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
