"""Tests for orchestration introspection helpers."""
from __future__ import annotations

import os

from src.orchestration import inspector


def test_resolve_localhost():
    result = inspector.resolve_host("localhost")
    assert result["resolved"] is True
    assert result["addresses"]


def test_collect_facts_producer(monkeypatch, tmp_path):
    log = tmp_path / "transactions.log"
    log.write_text('{"id":"1"}\n', encoding="utf-8")
    monkeypatch.setenv("SERVICE_ROLE", "producer")
    monkeypatch.setenv("WORKER_HOSTNAME", "localhost")
    monkeypatch.setenv("WORKER_PORT", "9")  # closed port → peer health false is OK
    monkeypatch.setenv("TX_LOG", str(log))
    monkeypatch.setenv("LAB_NETWORK", "orch-net")

    facts = inspector.collect_orchestration_facts()
    assert facts["service_role"] == "producer"
    assert facts["tx_log_exists"] is True
    assert facts["tx_log_lines"] == 1
    assert facts["desired_services"] == 2
    assert "unless-stopped" in facts["restart_policy"]
