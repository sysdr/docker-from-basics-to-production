from __future__ import annotations

from pathlib import Path

import pytest

from src.app.main import app
from src.monitoring.metrics import METRICS


@pytest.fixture()
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    data = tmp_path / "data"
    vol = tmp_path / "volume"
    data.mkdir()
    vol.mkdir()
    monkeypatch.setenv("PERSIST_DATA_DIR", str(data))
    monkeypatch.setenv("PERSIST_VOLUME_DIR", str(vol))
    # reset metrics between tests
    METRICS.writes = 0
    METRICS.reads = 0
    METRICS.bytes_written = 0
    METRICS.bytes_read = 0
    METRICS.demos_run = 0
    METRICS.ephemeral_writes = 0
    METRICS.ephemeral_lost = 0
    METRICS.persist_survived = 0
    METRICS.recent_events.clear()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_write_and_metrics(client):
    r = client.post("/api/write", json={"message": "lab"})
    assert r.status_code == 201
    m = client.get("/api/metrics").get_json()
    assert m["writes"] > 0
    assert m["bytes_written"] > 0
    s = client.get("/api/state").get_json()
    assert s["counter"] >= 1


def test_demo_updates_metrics(client):
    r = client.post("/api/demo", json={"count": 5})
    assert r.status_code == 200
    body = r.get_json()
    assert body["produced"] == 5
    assert body["metrics"]["demos_run"] >= 1
    assert body["metrics"]["writes"] > 0
    assert body["counter_after"] >= 5
