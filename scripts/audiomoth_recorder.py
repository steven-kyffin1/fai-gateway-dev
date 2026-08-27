#!/usr/bin/env python3
"""Minimal scheduled/continuous AudioMoth USB microphone recorder."""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from pathlib import Path
import signal
import subprocess
import time


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


ENABLED = env_bool("AUDIOMOTH_ENABLED", False)
TEST_MODE = env_bool("AUDIOMOTH_TEST_MODE", False)
ALSA_DEVICE = os.getenv("AUDIOMOTH_ALSA_DEVICE", "plughw:CARD=AudioMoth,DEV=0")
SAMPLE_RATE = int(os.getenv("AUDIOMOTH_SAMPLE_RATE", "48000"))
CHANNELS = int(os.getenv("AUDIOMOTH_CHANNELS", "1"))
FORMAT = os.getenv("AUDIOMOTH_FORMAT", "S16_LE")
RECORD_SECONDS = int(
    os.getenv("AUDIOMOTH_RECORD_SECONDS", "60" if TEST_MODE else "30")
)
INTERVAL_SECONDS = int(
    os.getenv("AUDIOMOTH_INTERVAL_SECONDS", "0" if TEST_MODE else "300")
)
OUTPUT_DIR = Path(os.getenv("AUDIOMOTH_OUTPUT_DIR", "/opt/fai-storage/audio"))
LOG_PATH = Path(
    os.getenv("AUDIOMOTH_LOG_PATH", "/opt/fai-storage/emc/audiomoth.log")
)
HEALTH_PATH = Path(
    os.getenv("AUDIOMOTH_HEALTH_PATH", "/run/fai-audiomoth/health.json")
)

STOP = False


def stop_handler(signum: int, frame: object) -> None:
    del signum, frame
    global STOP
    STOP = True


def write_health(state: str, **fields: object) -> None:
    HEALTH_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary = HEALTH_PATH.with_suffix(".tmp")
    payload = {
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "unix_time": time.time(),
        "state": state,
        "test_mode": TEST_MODE,
        "device": ALSA_DEVICE,
        **fields,
    }
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    temporary.replace(HEALTH_PATH)


def record_once() -> bool:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final_path = OUTPUT_DIR / f"audiomoth_{timestamp}.wav"
    partial_path = OUTPUT_DIR / f".audiomoth_{timestamp}.partial.wav"
    command = [
        "/usr/bin/arecord",
        "--quiet",
        "--device",
        ALSA_DEVICE,
        "--format",
        FORMAT,
        "--rate",
        str(SAMPLE_RATE),
        "--channels",
        str(CHANNELS),
        "--duration",
        str(RECORD_SECONDS),
        "--file-type",
        "wav",
        str(partial_path),
    ]

    write_health("recording", output=str(final_path))
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            capture_output=True,
            timeout=RECORD_SECONDS + 15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logging.error("Recording command failed: %s", exc)
        partial_path.unlink(missing_ok=True)
        write_health("error", error=str(exc))
        return False

    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        logging.error(
            "arecord failed rc=%s stderr=%r",
            completed.returncode,
            completed.stderr[-1000:],
        )
        partial_path.unlink(missing_ok=True)
        write_health("error", error=completed.stderr[-1000:])
        return False

    try:
        size = partial_path.stat().st_size
        minimum_size = int(SAMPLE_RATE * CHANNELS * 2 * RECORD_SECONDS * 0.8)
        if size < minimum_size:
            raise ValueError(f"short WAV: {size} bytes; expected at least {minimum_size}")
        partial_path.replace(final_path)
    except (OSError, ValueError) as exc:
        logging.error("Recording validation failed: %s", exc)
        partial_path.unlink(missing_ok=True)
        write_health("error", error=str(exc))
        return False

    logging.info(
        "Recording complete path=%s bytes=%s elapsed=%.1fs",
        final_path,
        size,
        elapsed,
    )
    write_health(
        "ok",
        output=str(final_path),
        bytes=size,
        elapsed_seconds=round(elapsed, 2),
    )
    return True


def main() -> int:
    if not ENABLED:
        print("AudioMoth recorder disabled; set AUDIOMOTH_ENABLED=true")
        return 0
    if RECORD_SECONDS <= 0 or INTERVAL_SECONDS < 0:
        print("Invalid AudioMoth duration/interval", file=os.sys.stderr)
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    for stale_partial in OUTPUT_DIR.glob(".audiomoth_*.partial.wav"):
        stale_partial.unlink(missing_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)sZ %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        handlers=[
            logging.StreamHandler(),
            logging.FileHandler(LOG_PATH, encoding="utf-8"),
        ],
    )
    logging.Formatter.converter = time.gmtime
    logging.info(
        "START test_mode=%s device=%s rate=%s channels=%s duration=%ss interval=%ss",
        TEST_MODE,
        ALSA_DEVICE,
        SAMPLE_RATE,
        CHANNELS,
        RECORD_SECONDS,
        INTERVAL_SECONDS,
    )

    while not STOP:
        success = record_once()
        wait_seconds = INTERVAL_SECONDS if success else 5
        deadline = time.monotonic() + wait_seconds
        while not STOP and time.monotonic() < deadline:
            time.sleep(min(1, max(0, deadline - time.monotonic())))

    write_health("stopped")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    raise SystemExit(main())
