#!/usr/bin/env python3
"""
FAI Gateway — EMC/LVD Test Liveness Monitor
============================================
Runs on the HOST (not in Docker) so it survives container failures.
Polls all critical processes every 1 second and writes:
  - Live coloured terminal output (for the test engineer watching in real time)
  - Append-only timestamped log → /opt/fai-storage/emc_test.log (on NVMe SSD)

Monitored:
  Tier 1 — Infrastructure:  Docker containers, mbusd TCP port, MQTT broker
  Tier 2 — Data flow:       Tinymesh last-message age, wMBus last-message age,
                             Modbus last-response age (via MQTT subscription)

Usage:
  pip3 install paho-mqtt docker --break-system-packages
  python3 emc_monitor.py

  Optional flags:
    --log /path/to/file.log   Override log path (default: /opt/fai-storage/emc_test.log)
    --interval 1.0            Poll interval in seconds (default: 1.0)
    --mqtt-host localhost      MQTT broker host (default: localhost)
    --mqtt-port 1883           MQTT broker port (default: 1883)
    --no-colour               Disable ANSI colour (e.g. for serial console capture)
"""

import argparse
import datetime
import socket
import sys
import threading
import time
import os

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt not installed. Run:")
    print("  pip3 install paho-mqtt --break-system-packages")
    sys.exit(1)

try:
    import docker
except ImportError:
    print("ERROR: docker SDK not installed. Run:")
    print("  pip3 install docker --break-system-packages")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────

DEFAULT_LOG_PATH   = "/opt/fai-storage/emc_test.log"
POLL_INTERVAL      = 1.0   # seconds

# Containers to check — name → acceptable states
# Containers to check — name → acceptable states
CONTAINERS = {
    "fai-mqtt":          ["running"],
    "fai-nodered":       ["running"],
    "fai-mbusd":         ["running"],
    "emc-burner":        ["running", "restarting"], # Restarting is valid due to the shell loop
    "fai-watchdog":      ["running"],
    "ups-watchdog":      ["running"],
}

# TCP probes — label → (host, port)
TCP_PROBES = {
    "mbusd:5020": ("127.0.0.1", 5020),
    "mqtt:1883":  ("127.0.0.1", 1883),
    "nodered:1880": ("127.0.0.1", 1880),
}

# MQTT topics to subscribe to for data-flow liveness
# These must match what your Node-RED flows actually publish
MQTT_FLOW_TOPICS = {
    "tinymesh": "gateway/+/tinymesh/out",
    "wmbus":    "gateway/+/wmbus/out",
    "power":    "gateway/+/power/out",
}

# Max age (seconds) before a data flow is flagged as stale
STALE_THRESHOLD = 300   # 5 minutes — adjust to your sensor transmit interval

# ── ANSI colours ───────────────────────────────────────────────────────────────

class C:
    RESET  = "\033[0m"
    BOLD   = "\033[1m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    RED    = "\033[91m"
    CYAN   = "\033[96m"
    WHITE  = "\033[97m"
    GREY   = "\033[90m"

USE_COLOUR = True

def ok(s):    return f"{C.GREEN}{s}{C.RESET}"   if USE_COLOUR else s
def warn(s):  return f"{C.YELLOW}{s}{C.RESET}"  if USE_COLOUR else s
def fail(s):  return f"{C.RED}{C.BOLD}{s}{C.RESET}" if USE_COLOUR else s
def info(s):  return f"{C.CYAN}{s}{C.RESET}"    if USE_COLOUR else s
def grey(s):  return f"{C.GREY}{s}{C.RESET}"    if USE_COLOUR else s

# ── State (written by MQTT thread, read by poll loop) ─────────────────────────

_lock = threading.Lock()
_last_seen = {k: None for k in MQTT_FLOW_TOPICS}   # flow_name → datetime | None
_mqtt_connected = False

# ── MQTT subscriber (runs in background thread) ────────────────────────────────

def on_connect(client, userdata, flags, reason_code, properties):
    global _mqtt_connected
    if reason_code == 0:
        _mqtt_connected = True
        for topic in MQTT_FLOW_TOPICS.values():
            client.subscribe(topic)
    else:
        _mqtt_connected = False

def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
    global _mqtt_connected
    _mqtt_connected = False

def on_message(client, userdata, msg):
    now = datetime.datetime.utcnow()
    with _lock:
        for name, topic_pattern in MQTT_FLOW_TOPICS.items():
            # Convert wildcard pattern to a simple prefix match
            prefix = topic_pattern.replace("/+/", "/").split("/+")[0]
            if msg.topic.startswith(prefix.split("/+")[0]) or \
               _topic_matches(msg.topic, topic_pattern):
                _last_seen[name] = now

def _topic_matches(topic, pattern):
    """Minimal MQTT single-level wildcard matcher for + only."""
    tp = topic.split("/")
    pp = pattern.split("/")
    if len(tp) != len(pp):
        return False
    return all(p == "+" or p == t for t, p in zip(tp, pp))

def start_mqtt_subscriber(host, port):
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="emc-monitor")
    client.on_connect    = on_connect
    client.on_disconnect = on_disconnect
    client.on_message    = on_message
    try:
        client.connect(host, port, keepalive=10)
    except Exception:
        pass   # will show as MQTT disconnected in the poll loop
    client.loop_start()
    return client

# ── Check functions ────────────────────────────────────────────────────────────

def check_containers(docker_client):
    results = {}
    try:
        containers = {c.name: c for c in docker_client.containers.list(all=True)}
        for name, good_states in CONTAINERS.items():
            if name not in containers:
                results[name] = ("MISSING", None)
            else:
                c = containers[name]
                state  = c.status          # running / exited / restarting …
                health = None
                if c.attrs.get("State", {}).get("Health"):
                    health = c.attrs["State"]["Health"]["Status"]  # healthy/unhealthy/starting
                ok_state = state in good_states
                results[name] = ("OK" if ok_state else "FAIL", state, health)
    except Exception as e:
        for name in CONTAINERS:
            results[name] = ("ERROR", str(e))
    return results

def check_tcp(label, host, port, timeout=1.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "OK"
    except Exception:
        return "FAIL"

def check_data_flows():
    now = datetime.datetime.utcnow()
    results = {}
    with _lock:
        for name, last in _last_seen.items():
            if last is None:
                results[name] = ("WAITING", None)   # never seen since monitor started
            else:
                age = (now - last).total_seconds()
                if age <= STALE_THRESHOLD:
                    results[name] = ("OK", age)
                else:
                    results[name] = ("STALE", age)
    return results

# ── Formatting helpers ─────────────────────────────────────────────────────────

def fmt_container(name, result):
    if result[0] == "MISSING":
        return f"  {fail('✗ MISSING')}  {name}"
    if result[0] == "ERROR":
        return f"  {fail('✗ ERROR')}    {name}: {result[1]}"
    status  = result[1]
    health  = result[2] if len(result) > 2 else None
    is_ok   = result[0] == "OK"
    sym     = ok("✓") if is_ok else fail("✗")
    h_str   = ""
    if health:
        if health == "healthy":
            h_str = f"  {ok('healthy')}"
        elif health == "starting":
            h_str = f"  {warn('starting')}"
        else:
            h_str = f"  {fail(health)}"
    status_str = ok(status) if is_ok else fail(status)
    return f"  {sym} {name:<20} {status_str}{h_str}"

def fmt_tcp(label, result):
    sym = ok("✓") if result == "OK" else fail("✗")
    val = ok(result) if result == "OK" else fail(result)
    return f"  {sym} {label:<18} {val}"

def fmt_flow(name, result):
    state, age = result[0], result[1]
    if state == "WAITING":
        return f"  {warn('?')} {name:<12} {warn('WAITING')}  {grey('(no data yet)')}"
    if state == "OK":
        return f"  {ok('✓')} {name:<12} {ok('LIVE')}     {grey(f'({age:.0f}s ago)')}"
    # STALE
    return f"  {fail('✗')} {name:<12} {fail('STALE')}    {grey(f'({age:.0f}s ago)')}"

def overall_status(container_results, tcp_results, flow_results):
    any_fail = (
        any(r[0] != "OK" for r in container_results.values()) or
        any(v == "FAIL" for v in tcp_results.values()) or
        any(r[0] == "STALE" for r in flow_results.values())
    )
    any_warn = any(r[0] == "WAITING" for r in flow_results.values())
    if any_fail:
        return fail("● FAIL")
    if any_warn:
        return warn("◐ WARN")
    return ok("● PASS")

# ── Plain-text line for log file (no ANSI) ────────────────────────────────────

def log_line(ts, container_results, tcp_results, flow_results):
    parts = [ts]

    for name, result in container_results.items():
        if result[0] == "MISSING":
            parts.append(f"{name}=MISSING")
        elif result[0] == "ERROR":
            parts.append(f"{name}=ERROR")
        else:
            health = result[2] if len(result) > 2 else None
            tag = result[0]
            if health and health != "healthy":
                tag = f"{result[1]}({health})"
            parts.append(f"{name}={tag}")

    for label, result in tcp_results.items():
        parts.append(f"tcp:{label}={result}")

    for name, result in flow_results.items():
        state, age = result[0], result[1]
        if age is not None:
            parts.append(f"flow:{name}={state}({age:.0f}s)")
        else:
            parts.append(f"flow:{name}={state}")

    return "  ".join(parts)

# ── Main loop ──────────────────────────────────────────────────────────────────

def main():
    global USE_COLOUR

    parser = argparse.ArgumentParser(description="FAI Gateway EMC Test Monitor")
    parser.add_argument("--log",       default=DEFAULT_LOG_PATH)
    parser.add_argument("--interval",  type=float, default=POLL_INTERVAL)
    parser.add_argument("--mqtt-host", default="localhost")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--no-colour", action="store_true")
    args = parser.parse_args()

    if args.no_colour:
        USE_COLOUR = False

    # Ensure log directory exists on NVMe
    os.makedirs(os.path.dirname(args.log), exist_ok=True)

    print(info(f"\nFAI Gateway EMC/LVD Test Monitor"))
    print(grey(f"  Log → {args.log}"))
    print(grey(f"  Poll interval: {args.interval}s  |  Stale threshold: {STALE_THRESHOLD}s"))
    print(grey(f"  MQTT: {args.mqtt_host}:{args.mqtt_port}"))
    print(grey(f"  Started: {datetime.datetime.utcnow().isoformat()}Z\n"))

    docker_client = docker.from_env()
    mqtt_client   = start_mqtt_subscriber(args.mqtt_host, args.mqtt_port)

    # Write log header
    with open(args.log, "a") as f:
        f.write(f"\n# ── EMC test session started {datetime.datetime.utcnow().isoformat()}Z ──\n")
        f.write(f"# Containers: {', '.join(CONTAINERS.keys())}\n")
        f.write(f"# TCP probes: {', '.join(TCP_PROBES.keys())}\n")
        f.write(f"# Data flows: {', '.join(MQTT_FLOW_TOPICS.keys())}\n")
        f.write(f"# Poll interval: {args.interval}s  Stale threshold: {STALE_THRESHOLD}s\n#\n")

    iteration = 0
    try:
        while True:
            t0 = time.monotonic()
            now_utc = datetime.datetime.utcnow()
            ts = now_utc.strftime("%Y-%m-%dT%H:%M:%S")

            container_results = check_containers(docker_client)
            tcp_results       = {l: check_tcp(l, h, p) for l, (h, p) in TCP_PROBES.items()}
            flow_results      = check_data_flows()

            status = overall_status(container_results, tcp_results, flow_results)

            # Clear terminal and redraw every poll (clean display)
            if USE_COLOUR:
                print("\033[2J\033[H", end="")   # clear screen, cursor home

            print(f"{info(ts+'Z')}   {status}\n")

            print(f"{C.BOLD if USE_COLOUR else ''}── Containers ──{C.RESET if USE_COLOUR else ''}")
            for name, result in container_results.items():
                print(fmt_container(name, result))

            print(f"\n{C.BOLD if USE_COLOUR else ''}── TCP Probes ──{C.RESET if USE_COLOUR else ''}")
            for label, result in tcp_results.items():
                print(fmt_tcp(label, result))

            print(f"\n{C.BOLD if USE_COLOUR else ''}── Data Flows ──{C.RESET if USE_COLOUR else ''}")
            for name, result in flow_results.items():
                print(fmt_flow(name, result))

            mqtt_sym = ok("✓ connected") if _mqtt_connected else warn("✗ disconnected")
            print(f"\n  MQTT subscriber: {mqtt_sym}")
            print(grey(f"\n  [poll #{iteration}  Ctrl-C to stop]"))

            # Append to log (plain text, no ANSI)
            line = log_line(ts, container_results, tcp_results, flow_results)
            with open(args.log, "a") as f:
                f.write(line + "\n")

            iteration += 1

            # Sleep for remainder of interval
            elapsed = time.monotonic() - t0
            sleep_for = max(0.0, args.interval - elapsed)
            time.sleep(sleep_for)

    except KeyboardInterrupt:
        end_ts = datetime.datetime.utcnow().isoformat()
        print(f"\n{grey('Monitor stopped: ' + end_ts + 'Z')}")
        with open(args.log, "a") as f:
            f.write(f"# ── Session ended {end_ts}Z  ({iteration} samples) ──\n\n")
        mqtt_client.loop_stop()
        mqtt_client.disconnect()

if __name__ == "__main__":
    main()