#!/usr/bin/env bash
# =============================================================================
# Day 1: Docker — From Isolated Containers to Resilient Stacks
# setup.sh — Generates a self-contained producer-service project demonstrating
# container isolation (namespaces + cgroups), a live metrics dashboard, demo,
# and tests.
#
# Only the child directory (producer-service/) is meant to be pushed to git.
# It must not depend on this setup.sh at runtime.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="producer-service"
PROJECT_DIR="$ROOT/$PROJECT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

info "Setting up Day 1: Isolated Containers — producer-service"

if [[ -d "$PROJECT_DIR" ]]; then
  warn "Removing existing $PROJECT/"
  rm -rf "$PROJECT_DIR"
fi

mkdir -p "$PROJECT_DIR"/{src,tests,scripts}
mkdir -p "$PROJECT_DIR"/src/{producer,monitoring,isolation}

# -----------------------------------------------------------------------------
# .gitignore
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/.gitignore" << 'EOF'
# Python
__pycache__/
*.py[cod]
*$py.class
*.egg-info/
.eggs/
dist/
build/
*.egg

# Virtual environments
.venv/
venv/
ENV/
env/

# Test / coverage
.pytest_cache/
.coverage
htmlcov/
.tox/
.mypy_cache/
.ruff_cache/

# Node
node_modules/
npm-debug.log*
yarn-error.log*

# Env / secrets
.env
.env.*
!.env.example
*.pem
*.key
secrets/
credentials.json

# Istio / mesh leftovers
istio-*/
*istio*.yaml
*istio*.yml

# IDE / OS
.idea/
.vscode/
*.swp
.DS_Store
Thumbs.db

# Runtime / local
.pids/
*.pid
*.log
logs/
tmp/
.cache/

# Docker local overrides
docker-compose.override.yml
EOF

# -----------------------------------------------------------------------------
# requirements.txt
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/requirements.txt" << 'EOF'
# Day 1 host-side / test dependencies
flask==3.0.3
requests==2.32.3
pytest==8.3.3
EOF

# -----------------------------------------------------------------------------
# Dockerfile — lean producer image with isolation-friendly defaults
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/Dockerfile" << 'EOF'
FROM python:3.12-slim

WORKDIR /app

# Install only runtime deps first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY scripts/ ./scripts/

ENV PYTHONUNBUFFERED=1 \
    PRODUCER_PORT=8080 \
    PRODUCER_HOSTNAME=producer-service

EXPOSE 8080

# Run as non-root when possible
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["python", "-m", "src.producer.app"]
EOF

# -----------------------------------------------------------------------------
# docker-compose.yml — cgroup limits + named container for Day 1 isolation lab
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
services:
  producer-service:
    build: .
    image: producer-service:day1
    container_name: my-producer
    ports:
      - "8080:8080"
    environment:
      PRODUCER_PORT: "8080"
      PRODUCER_HOSTNAME: "producer-service"
      PRODUCER_RATE: "5"
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
    mem_limit: 128m
    cpus: 0.50
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s
EOF

# -----------------------------------------------------------------------------
# Package markers
# -----------------------------------------------------------------------------
touch "$PROJECT_DIR/src/__init__.py"
touch "$PROJECT_DIR/src/producer/__init__.py"
touch "$PROJECT_DIR/src/monitoring/__init__.py"
touch "$PROJECT_DIR/src/isolation/__init__.py"
touch "$PROJECT_DIR/tests/__init__.py"

# -----------------------------------------------------------------------------
# Isolation introspection — namespaces + cgroups
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/isolation/inspector.py" << 'EOF'
"""Read Linux namespace and cgroup facts visible from inside the process."""
from __future__ import annotations

import os
import platform
import socket
from pathlib import Path
from typing import Any


def _read_text(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def _parse_cgroup_v2_memory_max() -> str | None:
    raw = _read_text("/sys/fs/cgroup/memory.max")
    if raw is None:
        # cgroup v1 fallback
        raw = _read_text("/sys/fs/cgroup/memory/memory.limit_in_bytes")
    return raw


def _parse_cgroup_cpu() -> dict[str, Any]:
    info: dict[str, Any] = {}
    max_raw = _read_text("/sys/fs/cgroup/cpu.max")
    if max_raw:
        parts = max_raw.split()
        info["cpu_max"] = max_raw
        if len(parts) == 2 and parts[0] != "max":
            try:
                quota, period = int(parts[0]), int(parts[1])
                info["cpu_limit_cores"] = round(quota / period, 3)
            except ValueError:
                pass
    else:
        quota = _read_text("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
        period = _read_text("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        if quota and period:
            info["cpu_cfs_quota_us"] = quota
            info["cpu_cfs_period_us"] = period
            try:
                q, p = int(quota), int(period)
                if q > 0 and p > 0:
                    info["cpu_limit_cores"] = round(q / p, 3)
            except ValueError:
                pass
    return info


def collect_isolation_facts() -> dict[str, Any]:
    ns_dir = Path("/proc/self/ns")
    namespaces = {}
    if ns_dir.is_dir():
        for entry in sorted(ns_dir.iterdir()):
            try:
                namespaces[entry.name] = os.readlink(entry)
            except OSError:
                namespaces[entry.name] = None

    mem_max = _parse_cgroup_v2_memory_max()
    mem_bytes = None
    if mem_max and mem_max != "max":
        try:
            mem_bytes = int(mem_max)
        except ValueError:
            mem_bytes = None

    return {
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "uid": os.getuid(),
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "configured_hostname": os.environ.get("PRODUCER_HOSTNAME"),
        "namespaces": namespaces,
        "cgroup_memory_max": mem_max,
        "cgroup_memory_max_mb": round(mem_bytes / (1024 * 1024), 2) if mem_bytes else None,
        "cgroup_cpu": _parse_cgroup_cpu(),
        "inside_container": Path("/.dockerenv").exists() or bool(namespaces),
    }
EOF

# -----------------------------------------------------------------------------
# Metrics store
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/monitoring/metrics.py" << 'EOF'
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
EOF

# -----------------------------------------------------------------------------
# Producer core
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/producer/core.py" << 'EOF'
"""Event producer — generates structured log/event payloads."""
from __future__ import annotations

import json
import random
import time
import uuid
from typing import Any

from src.monitoring.metrics import METRICS

LEVELS = ("INFO", "WARN", "ERROR", "DEBUG")
SOURCES = ("auth-service", "payments", "inventory", "checkout", "notifications")


def build_event(org_id: str | None = None, message: str | None = None) -> dict[str, Any]:
    event = {
        "id": str(uuid.uuid4()),
        "organizationId": org_id or f"org-{random.randint(1, 5)}",
        "level": random.choice(LEVELS),
        "message": message or f"Synthetic event at {time.time():.3f}",
        "source": random.choice(SOURCES),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    return event


def produce_event(**kwargs: Any) -> dict[str, Any]:
    event = build_event(**kwargs)
    payload = json.dumps(event, separators=(",", ":"))
    try:
        # Day 1: "produce" means build + acknowledge; Kafka comes in later days.
        METRICS.record_success(payload)
        return event
    except Exception:
        METRICS.record_failure()
        raise


def produce_batch(count: int = 25) -> list[dict[str, Any]]:
    events = []
    for i in range(count):
        events.append(produce_event(message=f"Demo batch message {i + 1}/{count}"))
    METRICS.record_demo()
    return events
EOF

# -----------------------------------------------------------------------------
# Flask app — API + dashboard
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/producer/app.py" << 'EOF'
"""Producer service HTTP API and live isolation dashboard."""
from __future__ import annotations

import os
import threading
import time

from flask import Flask, jsonify, request

from src.isolation.inspector import collect_isolation_facts
from src.monitoring.metrics import METRICS
from src.producer.core import produce_batch, produce_event

app = Flask(__name__)

_bg_stop = threading.Event()
_bg_thread: threading.Thread | None = None


def _background_producer() -> None:
    rate = float(os.environ.get("PRODUCER_RATE", "5"))
    interval = 1.0 / max(rate, 0.1)
    while not _bg_stop.wait(interval):
        try:
            produce_event(message="background tick")
        except Exception:
            METRICS.record_failure()


def start_background() -> None:
    global _bg_thread
    if _bg_thread and _bg_thread.is_alive():
        return
    _bg_stop.clear()
    _bg_thread = threading.Thread(target=_background_producer, name="bg-producer", daemon=True)
    _bg_thread.start()


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Producer Service — Isolation Dashboard</title>
  <style>
    :root {
      --bg: #0f1419;
      --panel: #1a2332;
      --text: #e7ecf3;
      --muted: #8b9bb4;
      --accent: #3dd6c6;
      --warn: #f0a202;
      --ok: #5ad67d;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
      background: radial-gradient(1200px 600px at 10% -10%, #1e3a4c 0%, var(--bg) 55%);
      color: var(--text); min-height: 100vh;
    }
    header { padding: 1.5rem 2rem 0.5rem; }
    header h1 { margin: 0; font-size: 1.6rem; letter-spacing: 0.02em; }
    header p { margin: 0.4rem 0 0; color: var(--muted); }
    main { padding: 1rem 2rem 2rem; display: grid; gap: 1rem;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
    .card {
      background: color-mix(in srgb, var(--panel) 92%, white 8%);
      border: 1px solid #2a3a4f; border-radius: 12px; padding: 1rem 1.1rem;
    }
    .card h2 { margin: 0 0 0.6rem; font-size: 0.85rem; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.08em; }
    .value { font-size: 2rem; font-weight: 650; color: var(--accent); }
    .sub { color: var(--muted); font-size: 0.85rem; margin-top: 0.35rem; }
    .wide { grid-column: 1 / -1; }
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th, td { text-align: left; padding: 0.4rem 0.35rem; border-bottom: 1px solid #2a3a4f; }
    th { color: var(--muted); font-weight: 550; }
    .pill { display: inline-block; padding: 0.15rem 0.55rem; border-radius: 999px;
      background: #243447; color: var(--ok); font-size: 0.8rem; }
    button {
      background: var(--accent); color: #04211e; border: 0; border-radius: 8px;
      padding: 0.55rem 1rem; font-weight: 650; cursor: pointer;
    }
    button:hover { filter: brightness(1.08); }
    code { color: var(--warn); }
  </style>
</head>
<body>
  <header>
    <h1>Producer Service — Day 1 Isolation Lab</h1>
    <p>Live metrics + Linux namespace / cgroup facts from inside the container.</p>
  </header>
  <main>
    <div class="card"><h2>Messages Produced</h2><div class="value" id="msg">0</div>
      <div class="sub" id="rate">0 msg/s</div></div>
    <div class="card"><h2>Success Rate</h2><div class="value" id="ok">0%</div>
      <div class="sub" id="fail">0 failed</div></div>
    <div class="card"><h2>Bytes Produced</h2><div class="value" id="bytes">0</div>
      <div class="sub" id="uptime">uptime 0s</div></div>
    <div class="card"><h2>Demos Run</h2><div class="value" id="demos">0</div>
      <div class="sub"><span class="pill" id="health">checking…</span></div></div>
    <div class="card wide">
      <h2>Container Isolation</h2>
      <table>
        <tr><th>PID (inside)</th><td id="pid">—</td></tr>
        <tr><th>Hostname</th><td id="host">—</td></tr>
        <tr><th>Memory limit</th><td id="mem">—</td></tr>
        <tr><th>CPU limit</th><td id="cpu">—</td></tr>
        <tr><th>PID namespace</th><td id="ns_pid"><code>—</code></td></tr>
        <tr><th>UTS namespace</th><td id="ns_uts"><code>—</code></td></tr>
        <tr><th>MNT namespace</th><td id="ns_mnt"><code>—</code></td></tr>
      </table>
      <p style="margin-top:1rem">
        <button id="runDemo">Run Demo Batch</button>
      </p>
    </div>
    <div class="card wide">
      <h2>Recent Messages</h2>
      <table>
        <thead><tr><th>When</th><th>Size</th><th>Preview</th></tr></thead>
        <tbody id="recent"></tbody>
      </table>
    </div>
  </main>
  <script>
    async function refresh() {
      const [m, iso, h] = await Promise.all([
        fetch('/api/metrics').then(r => r.json()),
        fetch('/api/isolation').then(r => r.json()),
        fetch('/health').then(r => r.json()),
      ]);
      document.getElementById('msg').textContent = m.messages_produced;
      document.getElementById('rate').textContent = m.messages_per_second + ' msg/s';
      document.getElementById('ok').textContent = m.success_rate_pct + '%';
      document.getElementById('fail').textContent = m.messages_failed + ' failed';
      document.getElementById('bytes').textContent = m.bytes_produced;
      document.getElementById('uptime').textContent = 'uptime ' + m.uptime_seconds + 's';
      document.getElementById('demos').textContent = m.demos_run;
      document.getElementById('health').textContent = h.status || 'ok';
      document.getElementById('pid').textContent = iso.pid;
      document.getElementById('host').textContent = iso.hostname;
      document.getElementById('mem').textContent =
        iso.cgroup_memory_max_mb != null ? iso.cgroup_memory_max_mb + ' MiB' : (iso.cgroup_memory_max || 'unlimited');
      const cpu = iso.cgroup_cpu && iso.cgroup_cpu.cpu_limit_cores;
      document.getElementById('cpu').textContent = cpu != null ? cpu + ' cores' : (iso.cgroup_cpu.cpu_max || 'n/a');
      const ns = iso.namespaces || {};
      document.getElementById('ns_pid').innerHTML = '<code>' + (ns.pid || '—') + '</code>';
      document.getElementById('ns_uts').innerHTML = '<code>' + (ns.uts || '—') + '</code>';
      document.getElementById('ns_mnt').innerHTML = '<code>' + (ns.mnt || '—') + '</code>';
      const tbody = document.getElementById('recent');
      tbody.innerHTML = (m.recent_messages || []).map(row => {
        const when = row.ts ? new Date(row.ts * 1000).toLocaleTimeString() : '—';
        return '<tr><td>' + when + '</td><td>' + row.size + '</td><td><code>' +
          (row.preview || '').replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])) +
          '</code></td></tr>';
      }).join('');
    }
    document.getElementById('runDemo').onclick = async () => {
      await fetch('/api/demo', { method: 'POST', headers: {'Content-Type':'application/json'},
        body: JSON.stringify({ count: 25 }) });
      await refresh();
    };
    refresh();
    setInterval(refresh, 1500);
  </script>
</body>
</html>
"""


@app.get("/")
@app.get("/dashboard")
def dashboard():
    return DASHBOARD_HTML


@app.get("/health")
def health():
    return jsonify({"status": "ok", "service": "producer-service"})


@app.get("/api/metrics")
def api_metrics():
    return jsonify(METRICS.snapshot())


@app.get("/api/isolation")
def api_isolation():
    return jsonify(collect_isolation_facts())


@app.post("/api/events")
def api_events():
    body = request.get_json(silent=True) or {}
    event = produce_event(
        org_id=body.get("organizationId"),
        message=body.get("message"),
    )
    return jsonify(event), 201


@app.post("/api/demo")
def api_demo():
    body = request.get_json(silent=True) or {}
    count = int(body.get("count", 25))
    count = max(1, min(count, 500))
    events = produce_batch(count)
    return jsonify({"produced": len(events), "metrics": METRICS.snapshot()})


def main() -> None:
    start_background()
    # Seed a few events so the dashboard is never stuck at zero after boot.
    produce_batch(5)
    port = int(os.environ.get("PRODUCER_PORT", "8080"))
    app.run(host="0.0.0.0", port=port, threaded=True)


if __name__ == "__main__":
    main()
EOF

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/tests/test_producer.py" << 'EOF'
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
EOF

cat > "$PROJECT_DIR/tests/test_isolation.py" << 'EOF'
from src.isolation.inspector import collect_isolation_facts


def test_isolation_facts_include_pid_and_hostname():
    facts = collect_isolation_facts()
    assert isinstance(facts["pid"], int)
    assert facts["pid"] > 0
    assert facts["hostname"]
    assert "namespaces" in facts
EOF

cat > "$PROJECT_DIR/tests/test_api.py" << 'EOF'
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
EOF

# -----------------------------------------------------------------------------
# Scripts: env, start, stop, demo, test, cleanup
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/env.sh" << 'EOF'
#!/usr/bin/env bash
# Shared environment for producer-service scripts.
export PRODUCER_PORT="${PRODUCER_PORT:-8080}"
export PRODUCER_HOSTNAME="${PRODUCER_HOSTNAME:-producer-service}"
export PRODUCER_RATE="${PRODUCER_RATE:-5}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-day1producer}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
EOF

cat > "$PROJECT_DIR/start.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[start] Checking for duplicate producer containers..."
EXISTING="$(docker ps -aq --filter name=^/my-producer$ || true)"
if [[ -n "$EXISTING" ]]; then
  echo "[start] Removing existing my-producer container(s) to avoid duplicates..."
  docker rm -f my-producer >/dev/null 2>&1 || true
fi

echo "[start] Building and starting producer-service (memory 128m, 0.5 CPU)..."
docker compose up --build -d

echo "[start] Waiting for health..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${PRODUCER_PORT}/health" >/dev/null 2>&1; then
    echo "[start] Healthy."
    echo "[start] Dashboard: http://127.0.0.1:${PRODUCER_PORT}/dashboard"
    docker compose ps
    exit 0
  fi
  sleep 1
done

echo "[start] Service failed to become healthy. Logs:"
docker compose logs --tail=80
exit 1
EOF

cat > "$PROJECT_DIR/stop.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[stop] Stopping producer-service..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker rm -f my-producer >/dev/null 2>&1 || true
echo "[stop] Done."
EOF

cat > "$PROJECT_DIR/demo.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"

BASE="http://127.0.0.1:${PRODUCER_PORT}"
echo "[demo] Hitting $BASE/api/demo ..."
RESP="$(curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 40}')"
echo "$RESP" | python3 -m json.tool

echo "[demo] Current metrics:"
curl -sf "$BASE/api/metrics" | python3 -m json.tool

MSG="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["messages_produced"])')"
if [[ "$MSG" -le 0 ]]; then
  echo "[demo] ERROR: messages_produced is still zero"
  exit 1
fi
echo "[demo] OK — messages_produced=$MSG (non-zero)"
echo "[demo] Open dashboard: $BASE/dashboard"
EOF

cat > "$PROJECT_DIR/test.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "[test] Installing test dependencies into a local venv (host-side unit/API tests)..."
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

echo "[test] Running pytest..."
PYTHONPATH="$ROOT" pytest -q tests/
echo "[test] All tests passed."
EOF

cat > "$PROJECT_DIR/cleanup.sh" << 'EOF'
#!/usr/bin/env bash
# Stop project containers, remove junk artifacts, prune unused Docker
# resources/images, then stop the Docker service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[cleanup]${NC} $*"; }
warn() { echo -e "${YELLOW}[cleanup]${NC} $*"; }

info "Stopping producer-service stack..."
if [[ -x "$ROOT/stop.sh" ]]; then
  "$ROOT/stop.sh" || true
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    info "Removing project containers by name..."
    docker rm -f my-producer >/dev/null 2>&1 || true
    docker compose down --remove-orphans --rmi local -v >/dev/null 2>&1 || true

    info "Removing project image producer-service:day1 (if present)..."
    docker rmi producer-service:day1 >/dev/null 2>&1 || true

    info "Pruning unused containers, networks, and dangling images..."
    docker container prune -f >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    docker system prune -f >/dev/null 2>&1 || true
  else
    warn "Docker daemon not reachable — skipping container/image prune."
  fi
else
  warn "docker CLI not found — skipping Docker cleanup."
fi

info "Removing node_modules, venv, caches, pyc, and Istio leftovers..."
find "$ROOT" \
  \( -type d \( -name node_modules -o -name .venv -o -name venv -o -name .pytest_cache -o -name '__pycache__' -o -name 'istio-*' \) \) \
  -prune -exec rm -rf {} + 2>/dev/null || true
find "$ROOT" \( -name '*.pyc' -o -name '*.pyo' -o -iname '*istio*.yaml' -o -iname '*istio*.yml' \) -type f -delete 2>/dev/null || true

info "Stopping Docker service / Docker Desktop (if available)..."
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
  sudo systemctl stop docker.service docker.socket 2>/dev/null || systemctl --user stop docker 2>/dev/null || true
fi
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command \
    "Stop-Process -Name 'Docker Desktop','com.docker.backend','com.docker.proxy' -Force -ErrorAction SilentlyContinue" \
    >/dev/null 2>&1 || true
fi

info "Done."
echo "Remaining Docker status (may fail if daemon stopped):"
docker ps -a 2>&1 | head -5 || true
EOF

cat > "$PROJECT_DIR/verify.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[verify] Container running?"
docker inspect -f '{{.State.Running}}' my-producer | grep -q true

echo "[verify] No duplicate my-producer containers..."
COUNT="$(docker ps -q --filter name=^/my-producer$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[verify] Expected exactly 1 my-producer, found $COUNT"
  docker ps --filter name=my-producer
  exit 1
fi

echo "[verify] Health + metrics non-zero..."
curl -sf "http://127.0.0.1:${PRODUCER_PORT}/health" >/dev/null
METRICS="$(curl -sf "http://127.0.0.1:${PRODUCER_PORT}/api/metrics")"
echo "$METRICS" | python3 -m json.tool
python3 - << PY
import json, os, urllib.request
m = json.load(urllib.request.urlopen("http://127.0.0.1:%s/api/metrics" % os.environ["PRODUCER_PORT"]))
assert m["messages_produced"] > 0, m
assert m["bytes_produced"] > 0, m
print("[verify] metrics OK")
PY

echo "[verify] Isolation endpoint..."
curl -sf "http://127.0.0.1:${PRODUCER_PORT}/api/isolation" | python3 -m json.tool >/dev/null
echo "[verify] All checks passed."
EOF

# -----------------------------------------------------------------------------
# README (project is independent of setup.sh)
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/README.md" << 'EOF'
# Producer Service — Day 1 Isolation Lab

Hands-on lab that builds and runs an isolated **producer-service** container with
cgroup limits, namespace introspection, live metrics, and a dashboard.

## Quick start

```bash
./start.sh
./demo.sh
# Dashboard: http://127.0.0.1:8080/dashboard
./test.sh
./verify.sh
./stop.sh
```

Tear down containers, prune Docker resources, and stop Docker:

```bash
./cleanup.sh
```

## Requirements

- Docker Desktop / Docker Engine 20.10+
- Docker Compose v2
- Python 3.11+ (for `./test.sh`)

## Layout

```
producer-service/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── .gitignore
├── start.sh / stop.sh / demo.sh / test.sh / verify.sh / cleanup.sh
├── src/
│   ├── producer/
│   ├── monitoring/
│   └── isolation/
└── tests/
```
EOF

chmod +x "$PROJECT_DIR"/{start,stop,demo,test,cleanup,verify,env}.sh

# -----------------------------------------------------------------------------
# Expected file checklist
# -----------------------------------------------------------------------------
EXPECTED=(
  ".gitignore"
  "requirements.txt"
  "Dockerfile"
  "docker-compose.yml"
  "README.md"
  "env.sh"
  "start.sh"
  "stop.sh"
  "demo.sh"
  "test.sh"
  "cleanup.sh"
  "verify.sh"
  "src/__init__.py"
  "src/producer/__init__.py"
  "src/producer/app.py"
  "src/producer/core.py"
  "src/monitoring/__init__.py"
  "src/monitoring/metrics.py"
  "src/isolation/__init__.py"
  "src/isolation/inspector.py"
  "tests/__init__.py"
  "tests/test_producer.py"
  "tests/test_isolation.py"
  "tests/test_api.py"
)

info "Verifying generated files..."
MISSING=0
for rel in "${EXPECTED[@]}"; do
  if [[ ! -e "$PROJECT_DIR/$rel" ]]; then
    error "Missing: $PROJECT/$rel"
    MISSING=1
  fi
done

if [[ "$MISSING" -ne 0 ]]; then
  error "Setup incomplete — missing files listed above."
  exit 1
fi

FILE_COUNT="$(find "$PROJECT_DIR" -type f | wc -l | tr -d ' ')"
info "Generated $FILE_COUNT files under $PROJECT/"
info "Setup complete."
info "Next: cd $PROJECT && ./start.sh"
echo
echo "Project root (git-push target): $PROJECT_DIR"
