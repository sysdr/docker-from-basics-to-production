"""Thread-safe in-process metrics for the persistence dashboard."""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class MetricsStore:
    writes: int = 0
    reads: int = 0
    bytes_written: int = 0
    bytes_read: int = 0
    demos_run: int = 0
    ephemeral_writes: int = 0
    ephemeral_lost: int = 0
    persist_survived: int = 0
    started_at: float = field(default_factory=time.time)
    last_write_at: float | None = None
    recent_events: deque = field(default_factory=lambda: deque(maxlen=20))
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record_write(self, payload: str, *, ephemeral: bool = False) -> None:
        with self._lock:
            size = len(payload.encode("utf-8"))
            self.writes += 1
            self.bytes_written += size
            self.last_write_at = time.time()
            if ephemeral:
                self.ephemeral_writes += 1
            self.recent_events.appendleft(
                {
                    "ts": time.time(),
                    "op": "write",
                    "size": size,
                    "preview": payload[:80],
                    "ephemeral": ephemeral,
                }
            )

    def record_read(self, nbytes: int) -> None:
        with self._lock:
            self.reads += 1
            self.bytes_read += max(0, nbytes)

    def record_demo(self) -> None:
        with self._lock:
            self.demos_run += 1

    def record_ephemeral_loss(self, count: int = 1) -> None:
        with self._lock:
            self.ephemeral_lost += count

    def record_persist_survived(self, count: int = 1) -> None:
        with self._lock:
            self.persist_survived += count

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            uptime = max(time.time() - self.started_at, 0.001)
            return {
                "writes": self.writes,
                "reads": self.reads,
                "bytes_written": self.bytes_written,
                "bytes_read": self.bytes_read,
                "demos_run": self.demos_run,
                "ephemeral_writes": self.ephemeral_writes,
                "ephemeral_lost": self.ephemeral_lost,
                "persist_survived": self.persist_survived,
                "writes_per_second": round(self.writes / uptime, 3),
                "uptime_seconds": round(uptime, 1),
                "last_write_at": self.last_write_at,
                "recent_events": list(self.recent_events),
            }


METRICS = MetricsStore()
