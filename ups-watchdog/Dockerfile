FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends dbus && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir smbus2==0.5.0

WORKDIR /app
COPY scripts/ups_watchdog.py /app/ups_watchdog.py
COPY ups-watchdog/healthcheck.py /app/healthcheck.py
CMD ["python", "-u", "/app/ups_watchdog.py"]

