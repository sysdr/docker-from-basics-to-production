"""Worker service HTTP API — processes transactions after producer is healthy."""
from __future__ import annotations

import os

from flask import Flask, jsonify, request

from src.monitoring.metrics import METRICS
from src.orchestration.inspector import collect_orchestration_facts
from src.worker.core import process_transaction

app = Flask(__name__)


@app.get("/health")
def health():
    METRICS.record_health_ok()
    return jsonify({"status": "ok", "service": "worker_service"})


@app.get("/api/metrics")
def metrics():
    return jsonify(METRICS.snapshot())


@app.get("/api/orchestration")
def orchestration():
    return jsonify(collect_orchestration_facts())


@app.post("/api/process")
def api_process():
    body = request.get_json(silent=True) or {}
    result = process_transaction(body)
    return jsonify(result), 201


def main() -> None:
    state = os.environ.get("STATE_DIR", "/app/state")
    os.makedirs(state, exist_ok=True)
    port = int(os.environ.get("WORKER_PORT", "8082"))
    app.run(host="0.0.0.0", port=port, threaded=True)


if __name__ == "__main__":
    main()
