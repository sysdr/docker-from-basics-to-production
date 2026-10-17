from src.monitoring.metrics import MetricsStore
from src.producer.core import build_event, produce_batch, produce_event


def test_build_event_has_required_fields():
    event = build_event(org_id="org-test", message="hello")
    assert event["organizationId"] == "org-test"
    assert event["message"] == "hello"
    assert event["id"]
    assert event["level"]
    assert event["source"]
    assert event["timestamp"]


def test_produce_event_increments_metrics(monkeypatch):
    store = MetricsStore()
    monkeypatch.setattr("src.producer.core.METRICS", store)
    produce_event(message="unit-test")
    snap = store.snapshot()
    assert snap["messages_produced"] == 1
    assert snap["bytes_produced"] > 0
    assert snap["success_rate_pct"] == 100.0


def test_produce_batch_records_demo(monkeypatch):
    store = MetricsStore()
    monkeypatch.setattr("src.producer.core.METRICS", store)
    events = produce_batch(10)
    assert len(events) == 10
    snap = store.snapshot()
    assert snap["messages_produced"] == 10
    assert snap["demos_run"] == 1
