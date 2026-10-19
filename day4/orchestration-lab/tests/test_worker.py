"""Unit tests for worker core."""
from __future__ import annotations

from pathlib import Path

from src.monitoring.metrics import MetricsStore
from src.worker import core


def test_process_transaction(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("STATE_DIR", str(tmp_path))
    monkeypatch.setattr(core, "METRICS", MetricsStore())

    result = core.process_transaction({"id": "abc", "message": "pay-42"})
    assert result["status"] == "processed"
    assert result["message"] == "pay-42"
    state = tmp_path / "processed.jsonl"
    assert state.exists()
    assert "pay-42" in state.read_text(encoding="utf-8")
    assert core.METRICS.transactions_processed == 1
