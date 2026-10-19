"""Flask API smoke tests for producer and worker."""
from __future__ import annotations

from pathlib import Path

import pytest

from src.monitoring import metrics as metrics_mod
from src.producer import app as producer_app
from src.producer import core as producer_core
from src.worker import app as worker_app
from src.worker import core as worker_core


@pytest.fixture()
def producer_client(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TX_LOG", str(tmp_path / "transactions.log"))
    monkeypatch.setenv("SERVICE_ROLE", "producer")
    store = metrics_mod.MetricsStore()
    monkeypatch.setattr(metrics_mod, "METRICS", store)
    monkeypatch.setattr(producer_core, "METRICS", store)
    monkeypatch.setattr(producer_app, "METRICS", store)
    monkeypatch.setattr(producer_core, "notify_worker", lambda record: True)
    producer_app.app.config["TESTING"] = True
    return producer_app.app.test_client()


@pytest.fixture()
def worker_client(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("STATE_DIR", str(tmp_path))
    monkeypatch.setenv("SERVICE_ROLE", "worker")
    store = metrics_mod.MetricsStore()
    monkeypatch.setattr(metrics_mod, "METRICS", store)
    monkeypatch.setattr(worker_core, "METRICS", store)
    monkeypatch.setattr(worker_app, "METRICS", store)
    worker_app.app.config["TESTING"] = True
    return worker_app.app.test_client()


def test_producer_health_and_demo(producer_client, tmp_path: Path):
    assert producer_client.get("/health").json["status"] == "ok"
    resp = producer_client.post("/api/demo", json={"count": 3})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["written"] == 3
    assert body["metrics"]["demos_run"] >= 1
    assert (tmp_path / "transactions.log").exists()
    dash = producer_client.get("/dashboard")
    assert dash.status_code == 200
    assert b"Orchestration Lab" in dash.data


def test_worker_process(worker_client):
    assert worker_client.get("/health").json["service"] == "worker_service"
    resp = worker_client.post("/api/process", json={"id": "t1", "message": "m1"})
    assert resp.status_code == 201
    assert resp.get_json()["status"] == "processed"
    metrics = worker_client.get("/api/metrics").get_json()
    assert metrics["transactions_processed"] >= 1
