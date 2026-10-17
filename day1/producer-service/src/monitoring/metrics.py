"""Thread-safe in-process metrics for the producer dashboard."""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class MetricsStore:
    messages_produced: int = 0
    messages_failed: int = 0
    bytes_produced: int = 0
    demos_run: int = 0
    started_at: float = field(default_factory=time.time)
    last_message_at: float | None = None
    recent_messages: deque = field(default_factory=lambda: deque(maxlen=20))
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record_success(self, payload: str) -> None:
        with self._lock:
            self.messages_produced += 1
            self.bytes_produced += len(payload.encode("utf-8"))
            self.last_message_at = time.time()
            self.recent_messages.appendleft(
                {"ts": self.last_message_at, "size": len(payload), "preview": payload[:80]}
            )

    def record_failure(self) -> None:
        with self._lock:
            self.messages_failed += 1

    def record_demo(self) -> None:
        with self._lock:
            self.demos_run += 1

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            uptime = max(0.0, time.time() - self.started_at)
            rate = self.messages_produced / uptime if uptime > 0 else 0.0
            return {
                "messages_produced": self.messages_produced,
                "messages_failed": self.messages_failed,
                "bytes_produced": self.bytes_produced,
                "demos_run": self.demos_run,
                "uptime_seconds": round(uptime, 2),
                "messages_per_second": round(rate, 3),
                "last_message_at": self.last_message_at,
                "recent_messages": list(self.recent_messages),
                "success_rate_pct": round(
                    (self.messages_produced / max(1, self.messages_produced + self.messages_failed))
                    * 100,
                    2,
                ),
            }


METRICS = MetricsStore()
