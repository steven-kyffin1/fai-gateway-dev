#!/usr/bin/env python3
import json
import time
from pathlib import Path

path = Path("/tmp/ups-watchdog-health.json")
try:
    health = json.loads(path.read_text(encoding="utf-8"))
    age = time.time() - float(health["unix_time"])
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

raise SystemExit(0 if age < 15 else 1)

