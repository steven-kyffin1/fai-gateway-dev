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

RTC_ADDRESS = int(os.getenv("RTC_ADDRESS", "0x51"), 0)
PCF8563_REG_ST2 = 0x01
PCF8563_REG_TMRC = 0x0E
PCF8563_REG_TMR = 0x0F
PCF8563_BIT_TIE = 0x01
PCF8563_TMRC_ENABLE = 0x80
PCF8563_TMRC_1HZ = 0x02

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


def cancel_wake_timer(bus: SMBus) -> bool:
    """Best-effort disable of the PCF8563 reset timer."""
    try:
        bus.write_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMRC,
            PCF8563_TMRC_1HZ,
            force=True,
        )
        tmrc = bus.read_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMRC,
            force=True,
        )
        disabled = not bool(tmrc & PCF8563_TMRC_ENABLE)
        LOG.info(
            "PCF8563 reset timer cancel tmrc=0x%02x disabled=%s",
            tmrc,
            disabled,
        )
        return disabled
    except OSError as exc:
        LOG.error("Unable to disable PCF8563 reset timer: %s", exc)
        return False


def set_wake_alarm(bus: SMBus) -> bool:
    """Arm the PCF8563 hardware reset timer used by this platform."""
    if not 2 <= WAKE_SECONDS <= 255:
        LOG.error(
            "Invalid PCF8563 reset timeout=%s; valid range is 2..255 seconds",
            WAKE_SECONDS,
        )
        return False

    try:
        # Match the installed rtc-pcf8563w watchdog driver's start sequence:
        # clear pending timer state / enable timer interrupt,
        # load timeout, then enable timer at 1 Hz.
        bus.write_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_ST2,
            PCF8563_BIT_TIE,
            force=True,
        )
        bus.write_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMR,
            WAKE_SECONDS,
            force=True,
        )
        bus.write_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMRC,
            PCF8563_TMRC_ENABLE | PCF8563_TMRC_1HZ,
            force=True,
        )

        st2 = bus.read_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_ST2,
            force=True,
        )
        tmrc = bus.read_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMRC,
            force=True,
        )
        tmr = bus.read_byte_data(
            RTC_ADDRESS,
            PCF8563_REG_TMR,
            force=True,
        )

        # Ignore undefined/reserved TMRC bits. The required state is:
        # timer enabled + frequency selector 2 (1 Hz).
        tmrc_ok = (
            tmrc & (PCF8563_TMRC_ENABLE | 0x03)
        ) == (PCF8563_TMRC_ENABLE | PCF8563_TMRC_1HZ)

        st2_ok = bool(st2 & PCF8563_BIT_TIE)

        # A read can occur around a one-second decrement boundary.
        tmr_ok = max(2, WAKE_SECONDS - 2) <= tmr <= WAKE_SECONDS

        configured = tmrc_ok and st2_ok and tmr_ok

        LOG.info(
            "PCF8563 reset timer armed=%s timeout=%ss "
            "st2=0x%02x tmrc=0x%02x tmr=%s",
            configured,
            WAKE_SECONDS,
            st2,
            tmrc,
            tmr,
        )

        if not configured:
            LOG.error("PCF8563 reset timer verification failed; disabling timer")
            cancel_wake_timer(bus)

        return configured

    except OSError as exc:
        LOG.error("Unable to arm PCF8563 reset timer: %s", exc)
        cancel_wake_timer(bus)
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
                            wake_ok = set_wake_alarm(bus)

                            if not wake_ok:
                                LOG.critical(
                                    "Automatic wake could not be armed; "
                                    "refusing graceful host halt"
                                )
                                write_health("wake-arm-failed")
                                halt_requested = False
                            else:
                                LOG.critical(
                                    "Requesting graceful host halt "
                                    "wake_alarm_configured=true"
                                )
                                if not request_host_halt():
                                    LOG.error(
                                        "Host halt failed after reset timer was armed; "
                                        "cancelling reset timer"
                                    )
                                    cancel_wake_timer(bus)
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

