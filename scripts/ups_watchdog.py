#!/usr/bin/env python3
"""Monitor the LTC3350 backup state and request a graceful host halt."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import signal
import subprocess
import time

from smbus2 import SMBus


def env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


BUS_NUMBER = int(os.getenv("BUS_NUMBER", "6"), 0)
LTC_ADDRESS = int(os.getenv("LTC_ADDRESS", "0x09"), 0)
STATUS_REGISTER = int(os.getenv("LTC_STATUS_REGISTER", "0x1C"), 0)
SWAP_BYTES = env_bool("LTC_SWAP_BYTES", True)
TRIGGER_SECONDS = float(os.getenv("UPS_TRIGGER_SECONDS", "5"))
WAKE_SECONDS = int(os.getenv("UPS_WAKE_SECONDS", "60"))
POLL_SECONDS = float(os.getenv("UPS_POLL_SECONDS", "1"))
HEALTH_PATH = Path("/tmp/ups-watchdog-health.json")
RTC_WAKEALARM = Path(os.getenv("RTC_WAKEALARM_PATH", "/sys/class/rtc/rtc0/wakealarm"))

STOP = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)sZ %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logging.Formatter.converter = time.gmtime
LOG = logging.getLogger("ups-watchdog")


def set_stopping(signum: int, frame: object) -> None:
    del signum, frame
    global STOP
    STOP = True


def read_backup_state(bus: SMBus) -> bool:
    status = bus.read_word_data(LTC_ADDRESS, STATUS_REGISTER)
    if SWAP_BYTES:
        status = ((status & 0xFF) << 8) | (status >> 8)
    return bool(status & 0x0001)


def write_health(state: str) -> None:
    temporary = HEALTH_PATH.with_suffix(".tmp")
    temporary.write_text(
        json.dumps({"unix_time": time.time(), "state": state}),
        encoding="utf-8",
    )
    temporary.replace(HEALTH_PATH)


def set_wake_alarm() -> bool:
    try:
        RTC_WAKEALARM.write_text("0\n", encoding="ascii")
        RTC_WAKEALARM.write_text(f"+{WAKE_SECONDS}\n", encoding="ascii")
        configured = RTC_WAKEALARM.read_text(encoding="ascii").strip()
        LOG.info("RTC wake alarm configured value=%s", configured)
        return bool(configured and configured != "0")
    except OSError as exc:
        LOG.error("Unable to configure RTC wake alarm: %s", exc)
        return False


def request_host_halt() -> bool:
    command = [
        "/usr/bin/dbus-send",
        "--system",
        "--print-reply",
        "--dest=org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager.Halt",
        "boolean:true",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            capture_output=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        LOG.error("Host halt request failed: %s", exc)
        return False

    if completed.returncode != 0:
        LOG.error(
            "Host halt rejected rc=%s stderr=%r",
            completed.returncode,
            completed.stderr[-500:],
        )
        return False
    return True


def main() -> int:
    if TRIGGER_SECONDS <= 0 or POLL_SECONDS <= 0:
        LOG.error("UPS trigger and poll intervals must be positive")
        return 2

    LOG.info(
        "START bus=%s address=%#x register=%#x trigger=%.1fs wake=%ss",
        BUS_NUMBER,
        LTC_ADDRESS,
        STATUS_REGISTER,
        TRIGGER_SECONDS,
        WAKE_SECONDS,
    )

    backup_started: float | None = None
    read_failures = 0
    halt_requested = False

    while not STOP:
        try:
            with SMBus(BUS_NUMBER) as bus:
                while not STOP:
                    try:
                        on_backup = read_backup_state(bus)
                        read_failures = 0
                    except OSError as exc:
                        read_failures += 1
                        write_health("i2c-error")
                        LOG.warning("I2C read failed count=%s error=%s", read_failures, exc)
                        if read_failures >= 5:
                            raise
                        time.sleep(POLL_SECONDS)
                        continue

                    now = time.monotonic()
                    if on_backup:
                        if backup_started is None:
                            backup_started = now
                            LOG.warning("Main power lost; SuperCAP backup active")
                        elapsed = now - backup_started
                        write_health("backup")
                        LOG.warning("Backup active for %.1fs / %.1fs", elapsed, TRIGGER_SECONDS)

                        if elapsed >= TRIGGER_SECONDS and not halt_requested:
                            halt_requested = True
                            wake_ok = set_wake_alarm()
                            LOG.critical(
                                "Requesting graceful host halt wake_alarm_configured=%s",
                                wake_ok,
                            )
                            if not request_host_halt():
                                halt_requested = False
                            else:
                                while not STOP:
                                    write_health("halt-requested")
                                    time.sleep(5)
                    else:
                        if backup_started is not None:
                            LOG.info("Main power restored before halt threshold")
                        backup_started = None
                        halt_requested = False
                        write_health("mains")

                    time.sleep(POLL_SECONDS)
        except OSError as exc:
            write_health("i2c-reopen")
            LOG.error("I2C bus unavailable; retrying in 2s: %s", exc)
            time.sleep(2)

    LOG.info("STOP")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, set_stopping)
    signal.signal(signal.SIGINT, set_stopping)
    raise SystemExit(main())

