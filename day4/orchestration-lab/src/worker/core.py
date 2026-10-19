"""Worker core: process transactions notified by the producer."""
from __future__ import annotations

import json
import os
import time
from typing import Any

from src.monitoring.metrics import METRICS


def state_path() -> str:
    base = os.environ.get("STATE_DIR", "/app/state")
    os.makedirs(base, exist_ok=True)
    return os.path.join(base, "processed.jsonl")


def process_transaction(payload: dict[str, Any]) -> dict[str, Any]:
    message = str(payload.get("message", ""))
    tx_id = str(payload.get("id", ""))
    line = json.dumps(
        {
            "id": tx_id,
            "message": message,
            "processed_at": time.time(),
            "by": "worker_service",
        },
        separators=(",", ":"),
    )
    with open(state_path(), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    METRICS.record_process(line)
    print(f"Processed: {message}", flush=True)
    return {"id": tx_id, "status": "processed", "message": message}
