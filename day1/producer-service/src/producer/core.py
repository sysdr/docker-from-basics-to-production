"""Event producer — generates structured log/event payloads."""
from __future__ import annotations

import json
import random
import time
import uuid
from typing import Any

from src.monitoring.metrics import METRICS

LEVELS = ("INFO", "WARN", "ERROR", "DEBUG")
SOURCES = ("auth-service", "payments", "inventory", "checkout", "notifications")


def build_event(org_id: str | None = None, message: str | None = None) -> dict[str, Any]:
    event = {
        "id": str(uuid.uuid4()),
        "organizationId": org_id or f"org-{random.randint(1, 5)}",
        "level": random.choice(LEVELS),
        "message": message or f"Synthetic event at {time.time():.3f}",
        "source": random.choice(SOURCES),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return event


def produce_event(**kwargs: Any) -> dict[str, Any]:
    event = build_event(**kwargs)
    payload = json.dumps(event, separators=(",", ":"))
    try:
        # Day 1: "produce" means build + acknowledge; Kafka comes in later days.
        METRICS.record_success(payload)
        return event
    except Exception:
        METRICS.record_failure()
        raise


def produce_batch(count: int = 25) -> list[dict[str, Any]]:
    events = []
    for i in range(count):
        events.append(produce_event(message=f"Demo batch message {i + 1}/{count}"))
    METRICS.record_demo()
    return events
