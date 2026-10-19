"""Unit tests for producer core (no Docker required)."""
from __future__ import annotations

import json
from pathlib import Path

from src.monitoring.metrics import MetricsStore
from src.producer import core


def test_append_transaction_writes_log(tmp_path: Path, monkeypatch):
    log = tmp_path / "transactions.log"
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TX_LOG", str(log))
    monkeypatch.setattr(core, "METRICS", MetricsStore())
    monkeypatch.setattr(core, "notify_worker", lambda record: True)

    record = core.append_transaction("hello-day4")
    assert record["message"] == "hello-day4"
    assert log.exists()
    lines = log.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0])["message"] == "hello-day4"
    assert core.METRICS.transactions_written == 1
    assert core.METRICS.bytes_persisted > 0


def test_run_demo_increments_metrics(tmp_path: Path, monkeypatch):
    log = tmp_path / "transactions.log"
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TX_LOG", str(log))
    monkeypatch.setattr(core, "METRICS", MetricsStore())
    monkeypatch.setattr(core, "notify_worker", lambda record: True)

    result = core.run_demo(5)
    assert result["written"] == 5
    assert result["notified"] == 5
    assert core.METRICS.demos_run == 1
    assert core.METRICS.transactions_written == 5
