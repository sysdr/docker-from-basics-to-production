"""Thread-safe in-process metrics for the Day 4 orchestration dashboard."""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class MetricsStore:
    transactions_written: int = 0
    transactions_processed: int = 0
    transactions_failed: int = 0
    bytes_persisted: int = 0
    demos_run: int = 0
    health_probes_ok: int = 0
    peer_probes_ok: int = 0
    desired_services: int = 2
    started_at: float = field(default_factory=time.time)
    last_tx_at: float | None = None
    recent_events: deque = field(default_factory=lambda: deque(maxlen=30))
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record_write(self, payload: str) -> None:
        with self._lock:
            self.transactions_written += 1
            self.bytes_persisted += len(payload.encode("utf-8"))
            self.last_tx_at = time.time()
            self.recent_events.appendleft(
                {"ts": self.last_tx_at, "op": "write", "preview": payload[:80], "size": len(payload)}
            )

    def record_process(self, payload: str) -> None:
        with self._lock:
            self.transactions_processed += 1
            self.bytes_persisted += len(payload.encode("utf-8"))
            self.last_tx_at = time.time()
            self.recent_events.appendleft(
                {"ts": self.last_tx_at, "op": "process", "preview": payload[:80], "size": len(payload)}
            )

    def record_fail(self, reason: str) -> None:
        with self._lock:
            self.transactions_failed += 1
            self.recent_events.appendleft(
                {"ts": time.time(), "op": "fail", "preview": reason[:80], "size": 0}
            )

    def record_health_ok(self) -> None:
        with self._lock:
            self.health_probes_ok += 1

    def record_peer_ok(self) -> None:
        with self._lock:
            self.peer_probes_ok += 1

    def record_demo(self) -> None:
        with self._lock:
            self.demos_run += 1

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            uptime = max(0.0, time.time() - self.started_at)
            return {
                "transactions_written": self.transactions_written,
                "transactions_processed": self.transactions_processed,
                "transactions_failed": self.transactions_failed,
                "bytes_persisted": self.bytes_persisted,
                "demos_run": self.demos_run,
                "health_probes_ok": self.health_probes_ok,
                "peer_probes_ok": self.peer_probes_ok,
                "desired_services": self.desired_services,
                "uptime_seconds": round(uptime, 1),
                "tx_per_second": round(self.transactions_written / uptime, 2) if uptime > 0 else 0.0,
                "last_tx_at": self.last_tx_at,
                "recent_events": list(self.recent_events),
            }


METRICS = MetricsStore()
