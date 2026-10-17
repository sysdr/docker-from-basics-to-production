import pytest

from src.producer.app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_demo_updates_metrics(client):
    before = client.get("/api/metrics").get_json()["messages_produced"]
    resp = client.post("/api/demo", json={"count": 7})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["produced"] == 7
    after = client.get("/api/metrics").get_json()
    assert after["messages_produced"] >= before + 7
    assert after["demos_run"] >= 1
    assert after["bytes_produced"] > 0
