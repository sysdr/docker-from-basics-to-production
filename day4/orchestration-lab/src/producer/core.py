"""Producer core: append durable transactions and notify the worker."""
from __future__ import annotations

import json
import os
import time
import uuid
import urllib.error
import urllib.request
from typing import Any

from src.monitoring.metrics import METRICS
from src.orchestration.inspector import resolve_host


def tx_log_path() -> str:
    return os.environ.get("TX_LOG", "/app/data/transactions.log")


def ensure_data_dir() -> None:
    path = os.environ.get("DATA_DIR", "/app/data")
    os.makedirs(path, exist_ok=True)


def append_transaction(message: str) -> dict[str, Any]:
    ensure_data_dir()
    record = {
        "id": str(uuid.uuid4()),
        "message": message,
        "ts": time.time(),
        "from": "producer_service",
    }
    line = json.dumps(record, separators=(",", ":"))
    with open(tx_log_path(), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    METRICS.record_write(line)
    return record


def notify_worker(record: dict[str, Any]) -> bool:
    host = os.environ.get("WORKER_HOSTNAME", "worker_service")
    port = os.environ.get("WORKER_PORT", "8082")
    dns = resolve_host(host)
    if dns.get("resolved"):
        METRICS.record_health_ok()
    url = f"http://{host}:{port}/api/process"
    data = json.dumps(record).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            if 200 <= resp.status < 300:
                METRICS.record_peer_ok()
                return True
            METRICS.record_fail(f"worker status {resp.status}")
            return False
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        METRICS.record_fail(str(exc))
        return False


def write_and_notify(message: str) -> dict[str, Any]:
    record = append_transaction(message)
    delivered = notify_worker(record)
    return {"record": record, "notified": delivered}


def run_demo(count: int = 20) -> dict[str, Any]:
    METRICS.record_demo()
    results = []
    notified = 0
    for i in range(count):
        result = write_and_notify(f"demo transaction #{i + 1}")
        results.append(result["record"]["id"])
        if result["notified"]:
            notified += 1
    return {
        "count": count,
        "written": len(results),
        "notified": notified,
        "ids": results,
        "metrics": METRICS.snapshot(),
    }
