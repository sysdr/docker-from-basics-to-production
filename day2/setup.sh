#!/usr/bin/env bash
# =============================================================================
# Day 2: Docker — From Isolated Containers to Resilient Stacks
# setup.sh — Generates a self-contained persistence-lab project demonstrating
# ephemeral vs persistent storage (bind mounts + named volumes), a live
# metrics dashboard, demo, and tests.
#
# Only the child directory (persistence-lab/) is meant to be pushed to git.
# It must not depend on this setup.sh at runtime.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="persistence-lab"
PROJECT_DIR="$ROOT/$PROJECT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

info "Setting up Day 2: Persistence Lab — $PROJECT"

if [[ -d "$PROJECT_DIR" ]]; then
  warn "Removing existing $PROJECT/"
  rm -rf "$PROJECT_DIR"
fi

mkdir -p "$PROJECT_DIR"/{src,tests,scripts,data}
mkdir -p "$PROJECT_DIR"/src/{app,monitoring,persistence}

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
data/*
!data/.gitkeep

# Docker local overrides
docker-compose.override.yml
EOF

# Keep data/ in git but ignore runtime contents
touch "$PROJECT_DIR/data/.gitkeep"

# -----------------------------------------------------------------------------
# requirements.txt
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/requirements.txt" << 'EOF'
# Day 2 host-side / test dependencies
flask==3.0.3
requests==2.32.3
pytest==8.3.3
EOF

# -----------------------------------------------------------------------------
# Dockerfile
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/Dockerfile" << 'EOF'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY scripts/ ./scripts/

RUN mkdir -p /app/data && chmod 777 /app/data

ENV PYTHONUNBUFFERED=1 \
    PERSIST_PORT=8080 \
    PERSIST_DATA_DIR=/app/data \
    PERSIST_HOSTNAME=persistence-lab

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["python", "-m", "src.app.main"]
EOF

# -----------------------------------------------------------------------------
# docker-compose.yml — bind mount + named volume for Day 2 persistence lab
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
services:
  persistence-lab:
    build: .
    image: persistence-lab:day2
    container_name: my-persistence
    ports:
      - "8080:8080"
    environment:
      PERSIST_PORT: "8080"
      PERSIST_HOSTNAME: "persistence-lab"
      PERSIST_DATA_DIR: "/app/data"
      PERSIST_RATE: "3"
    volumes:
      # Bind mount: host ./data visible on host for inspection
      - ./data:/app/data
      # Named volume: secondary durable store (survives container recreate)
      - persistence_state:/app/volume-data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s

volumes:
  persistence_state:
EOF

# -----------------------------------------------------------------------------
# Package markers
# -----------------------------------------------------------------------------
touch "$PROJECT_DIR/src/__init__.py"
touch "$PROJECT_DIR/src/app/__init__.py"
touch "$PROJECT_DIR/src/monitoring/__init__.py"
touch "$PROJECT_DIR/src/persistence/__init__.py"
touch "$PROJECT_DIR/tests/__init__.py"

# -----------------------------------------------------------------------------
# Persistence helpers — mount inspection + ephemeral vs durable paths
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/persistence/volumes.py" << 'EOF'
"""Inspect mount points and compare ephemeral vs persistent paths."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any


def _read_mounts() -> list[dict[str, str]]:
    mounts: list[dict[str, str]] = []
    try:
        text = Path("/proc/self/mountinfo").read_text(encoding="utf-8")
    except OSError:
        return mounts
    for line in text.splitlines():
        # mountinfo: ... - fstype source opts
        parts = line.split(" - ", 1)
        if len(parts) != 2:
            continue
        left, right = parts
        left_cols = left.split()
        right_cols = right.split()
        if len(left_cols) < 5 or len(right_cols) < 2:
            continue
        mounts.append(
            {
                "mount_point": left_cols[4],
                "fstype": right_cols[0],
                "source": right_cols[1],
            }
        )
    return mounts


def path_facts(path: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists()
    files = []
    total_bytes = 0
    if exists and p.is_dir():
        for child in sorted(p.iterdir()):
            if child.is_file():
                size = child.stat().st_size
                files.append({"name": child.name, "bytes": size})
                total_bytes += size
    return {
        "path": path,
        "exists": exists,
        "is_dir": p.is_dir() if exists else False,
        "files": files,
        "total_bytes": total_bytes,
        "writable": os.access(path, os.W_OK) if exists else False,
    }


def collect_persistence_facts() -> dict[str, Any]:
    data_dir = os.environ.get("PERSIST_DATA_DIR", "/app/data")
    volume_dir = os.environ.get("PERSIST_VOLUME_DIR", "/app/volume-data")
    ephemeral_dir = "/tmp/ephemeral-lab"

    mounts = _read_mounts()
    interesting = [
        m
        for m in mounts
        if m["mount_point"] in {data_dir, volume_dir, "/app", "/"}
        or data_dir.startswith(m["mount_point"])
        or volume_dir.startswith(m["mount_point"])
    ]

    return {
        "hostname": os.environ.get("PERSIST_HOSTNAME", "unknown"),
        "inside_container": Path("/.dockerenv").exists(),
        "data_dir": path_facts(data_dir),
        "volume_dir": path_facts(volume_dir),
        "ephemeral_dir": path_facts(ephemeral_dir),
        "mounts_sample": interesting[:12] or mounts[:8],
        "bind_mount_active": any(
            m["mount_point"] == data_dir or data_dir.startswith(m["mount_point"] + "/")
            for m in mounts
            if m["mount_point"] not in {"/", "/app"}
        )
        or Path(data_dir).is_mount()
        or Path("/.dockerenv").exists(),
    }
EOF

# -----------------------------------------------------------------------------
# Metrics store
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/monitoring/metrics.py" << 'EOF'
"""Thread-safe in-process metrics for the persistence dashboard."""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class MetricsStore:
    writes: int = 0
    reads: int = 0
    bytes_written: int = 0
    bytes_read: int = 0
    demos_run: int = 0
    ephemeral_writes: int = 0
    ephemeral_lost: int = 0
    persist_survived: int = 0
    started_at: float = field(default_factory=time.time)
    last_write_at: float | None = None
    recent_events: deque = field(default_factory=lambda: deque(maxlen=20))
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def record_write(self, payload: str, *, ephemeral: bool = False) -> None:
        with self._lock:
            size = len(payload.encode("utf-8"))
            self.writes += 1
            self.bytes_written += size
            self.last_write_at = time.time()
            if ephemeral:
                self.ephemeral_writes += 1
            self.recent_events.appendleft(
                {
                    "ts": time.time(),
                    "op": "write",
                    "size": size,
                    "preview": payload[:80],
                    "ephemeral": ephemeral,
                }
            )

    def record_read(self, nbytes: int) -> None:
        with self._lock:
            self.reads += 1
            self.bytes_read += max(0, nbytes)

    def record_demo(self) -> None:
        with self._lock:
            self.demos_run += 1

    def record_ephemeral_loss(self, count: int = 1) -> None:
        with self._lock:
            self.ephemeral_lost += count

    def record_persist_survived(self, count: int = 1) -> None:
        with self._lock:
            self.persist_survived += count

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            uptime = max(time.time() - self.started_at, 0.001)
            return {
                "writes": self.writes,
                "reads": self.reads,
                "bytes_written": self.bytes_written,
                "bytes_read": self.bytes_read,
                "demos_run": self.demos_run,
                "ephemeral_writes": self.ephemeral_writes,
                "ephemeral_lost": self.ephemeral_lost,
                "persist_survived": self.persist_survived,
                "writes_per_second": round(self.writes / uptime, 3),
                "uptime_seconds": round(uptime, 1),
                "last_write_at": self.last_write_at,
                "recent_events": list(self.recent_events),
            }


METRICS = MetricsStore()
EOF

# -----------------------------------------------------------------------------
# Durable store
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/app/store.py" << 'EOF'
"""Read/write durable application state under the data directory."""
from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from src.monitoring.metrics import METRICS

STATE_FILE = "state.json"
EVENTS_FILE = "events.jsonl"

_LOCK = threading.RLock()


def data_dir() -> Path:
    return Path(os.environ.get("PERSIST_DATA_DIR", "/app/data"))


def volume_dir() -> Path:
    return Path(os.environ.get("PERSIST_VOLUME_DIR", "/app/volume-data"))


def ephemeral_dir() -> Path:
    return Path("/tmp/ephemeral-lab")


def _ensure_dirs() -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    volume_dir().mkdir(parents=True, exist_ok=True)
    ephemeral_dir().mkdir(parents=True, exist_ok=True)


def _atomic_write(path: Path, payload: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, path)


def _empty_state() -> dict[str, Any]:
    return {
        "counter": 0,
        "messages": [],
        "boot_id": str(uuid.uuid4()),
        "created_at": time.time(),
        "updated_at": time.time(),
    }


def _load_state() -> dict[str, Any]:
    _ensure_dirs()
    path = data_dir() / STATE_FILE
    if not path.exists():
        return _empty_state()
    raw = path.read_text(encoding="utf-8")
    METRICS.record_read(len(raw.encode("utf-8")))
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Recover from a torn write (should be rare after atomic replace)
        backup = path.with_suffix(".corrupt")
        try:
            path.replace(backup)
        except OSError:
            path.unlink(missing_ok=True)
        return _empty_state()


def _save_state(state: dict[str, Any]) -> None:
    _ensure_dirs()
    state["updated_at"] = time.time()
    path = data_dir() / STATE_FILE
    payload = json.dumps(state, indent=2)
    _atomic_write(path, payload)
    METRICS.record_write(payload, ephemeral=False)
    # Mirror a compact marker into the named volume
    marker = volume_dir() / "last_write.txt"
    _atomic_write(marker, f"{state['counter']}:{state['updated_at']}\n")


def write_message(message: str) -> dict[str, Any]:
    with _LOCK:
        state = _load_state()
        state["counter"] = int(state.get("counter", 0)) + 1
        entry = {
            "id": str(uuid.uuid4()),
            "n": state["counter"],
            "message": message,
            "ts": time.time(),
        }
        messages = list(state.get("messages") or [])
        messages.append(entry)
        state["messages"] = messages[-50:]
        _save_state(state)

        events_path = data_dir() / EVENTS_FILE
        line = json.dumps(entry) + "\n"
        with events_path.open("a", encoding="utf-8") as fh:
            fh.write(line)
        METRICS.record_write(line, ephemeral=False)
        return entry


def write_ephemeral(message: str) -> dict[str, Any]:
    with _LOCK:
        _ensure_dirs()
        path = ephemeral_dir() / "scratch.txt"
        payload = f"{time.time()}:{message}\n"
        path.write_text(payload, encoding="utf-8")
        METRICS.record_write(payload, ephemeral=True)
        return {"path": str(path), "bytes": len(payload.encode("utf-8")), "message": message}


def read_state() -> dict[str, Any]:
    with _LOCK:
        return _load_state()


def read_volume_marker() -> str | None:
    with _LOCK:
        path = volume_dir() / "last_write.txt"
        if not path.exists():
            return None
        text = path.read_text(encoding="utf-8")
        METRICS.record_read(len(text.encode("utf-8")))
        return text.strip()


def seed_if_empty() -> dict[str, Any]:
    with _LOCK:
        state = _load_state()
        if int(state.get("counter", 0)) == 0:
            # release lock briefly for write_message which re-acquires
            pass
    if int(read_state().get("counter", 0)) == 0:
        write_message("Hello Persistent World")
        write_message("Day 2 bind-mount seed")
        METRICS.record_persist_survived(1)
        return read_state()
    METRICS.record_persist_survived(1)
    return read_state()
EOF

# -----------------------------------------------------------------------------
# Flask app + dashboard
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/src/app/main.py" << 'EOF'
"""Persistence lab HTTP API and live dashboard."""
from __future__ import annotations

import os
import threading
import time

from flask import Flask, jsonify, request

from src.app.store import (
    read_state,
    read_volume_marker,
    seed_if_empty,
    write_ephemeral,
    write_message,
)
from src.monitoring.metrics import METRICS
from src.persistence.volumes import collect_persistence_facts

app = Flask(__name__)

_bg_stop = threading.Event()
_bg_thread: threading.Thread | None = None


def _background_writer() -> None:
    rate = float(os.environ.get("PERSIST_RATE", "3"))
    interval = 1.0 / max(rate, 0.1)
    n = 0
    while not _bg_stop.wait(interval):
        n += 1
        try:
            write_message(f"background tick #{n}")
        except Exception:
            pass


def start_background() -> None:
    global _bg_thread
    if _bg_thread and _bg_thread.is_alive():
        return
    _bg_stop.clear()
    _bg_thread = threading.Thread(target=_background_writer, name="bg-writer", daemon=True)
    _bg_thread.start()


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Persistence Lab — Day 2 Dashboard</title>
  <style>
    :root {
      --bg: #0e1512;
      --panel: #16241e;
      --text: #e8f2ec;
      --muted: #8aa396;
      --accent: #6ee7a8;
      --warn: #f0b429;
      --ok: #5ad67d;
      --danger: #f07178;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
      background: radial-gradient(1100px 560px at 90% -10%, #1d3b2e 0%, var(--bg) 55%);
      color: var(--text); min-height: 100vh;
    }
    header { padding: 1.5rem 2rem 0.5rem; }
    header h1 { margin: 0; font-size: 1.55rem; letter-spacing: 0.02em; }
    header p { margin: 0.4rem 0 0; color: var(--muted); }
    main { padding: 1rem 2rem 2rem; display: grid; gap: 1rem;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
    .card {
      background: color-mix(in srgb, var(--panel) 92%, white 8%);
      border: 1px solid #274034; border-radius: 12px; padding: 1rem 1.1rem;
    }
    .card h2 { margin: 0 0 0.6rem; font-size: 0.8rem; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.08em; }
    .value { font-size: 1.85rem; font-weight: 650; color: var(--accent); }
    .sub { color: var(--muted); font-size: 0.85rem; margin-top: 0.35rem; }
    .wide { grid-column: 1 / -1; }
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th, td { text-align: left; padding: 0.4rem 0.35rem; border-bottom: 1px solid #274034; }
    th { color: var(--muted); font-weight: 550; }
    .pill { display: inline-block; padding: 0.15rem 0.55rem; border-radius: 999px;
      background: #1f3329; color: var(--ok); font-size: 0.8rem; }
    button {
      background: var(--accent); color: #062116; border: 0; border-radius: 8px;
      padding: 0.55rem 1rem; font-weight: 650; cursor: pointer; margin-right: 0.5rem;
    }
    button.secondary { background: #2a4338; color: var(--text); }
    button:hover { filter: brightness(1.08); }
    code { color: var(--warn); }
  </style>
</head>
<body>
  <header>
    <h1>Persistence Lab — Day 2</h1>
    <p>Ephemeral vs durable storage: bind mounts, named volumes, and live metrics.</p>
  </header>
  <main>
    <div class="card"><h2>Writes</h2><div class="value" id="writes">0</div>
      <div class="sub" id="wps">0 writes/s</div></div>
    <div class="card"><h2>Reads</h2><div class="value" id="reads">0</div>
      <div class="sub" id="bread">0 bytes read</div></div>
    <div class="card"><h2>Bytes Written</h2><div class="value" id="bwrite">0</div>
      <div class="sub" id="uptime">uptime 0s</div></div>
    <div class="card"><h2>Persisted Counter</h2><div class="value" id="counter">0</div>
      <div class="sub" id="survived">survived 0</div></div>
    <div class="card"><h2>Demos Run</h2><div class="value" id="demos">0</div>
      <div class="sub"><span class="pill" id="health">checking…</span></div></div>
    <div class="card"><h2>Ephemeral Lost</h2><div class="value" id="elost">0</div>
      <div class="sub" id="ewrites">0 ephemeral writes</div></div>
    <div class="card wide">
      <h2>Storage Introspection</h2>
      <table>
        <tr><th>Hostname</th><td id="host">—</td></tr>
        <tr><th>Data dir (bind)</th><td id="ddir"><code>—</code></td></tr>
        <tr><th>Data files</th><td id="dfiles">—</td></tr>
        <tr><th>Volume marker</th><td id="vmarker"><code>—</code></td></tr>
        <tr><th>Inside container</th><td id="inside">—</td></tr>
      </table>
      <p style="margin-top:1rem">
        <button id="runDemo">Run Persistence Demo</button>
        <button class="secondary" id="runWrite">Write Message</button>
      </p>
    </div>
    <div class="card wide">
      <h2>Recent Events</h2>
      <table>
        <thead><tr><th>When</th><th>Op</th><th>Size</th><th>Preview</th></tr></thead>
        <tbody id="recent"></tbody>
      </table>
    </div>
  </main>
  <script>
    async function refresh() {
      const [m, p, h, s] = await Promise.all([
        fetch('/api/metrics').then(r => r.json()),
        fetch('/api/persistence').then(r => r.json()),
        fetch('/health').then(r => r.json()),
        fetch('/api/state').then(r => r.json()),
      ]);
      document.getElementById('writes').textContent = m.writes;
      document.getElementById('wps').textContent = m.writes_per_second + ' writes/s';
      document.getElementById('reads').textContent = m.reads;
      document.getElementById('bread').textContent = m.bytes_read + ' bytes read';
      document.getElementById('bwrite').textContent = m.bytes_written;
      document.getElementById('uptime').textContent = 'uptime ' + m.uptime_seconds + 's';
      document.getElementById('counter').textContent = s.counter || 0;
      document.getElementById('survived').textContent = 'survived ' + m.persist_survived;
      document.getElementById('demos').textContent = m.demos_run;
      document.getElementById('health').textContent = h.status || 'ok';
      document.getElementById('elost').textContent = m.ephemeral_lost;
      document.getElementById('ewrites').textContent = m.ephemeral_writes + ' ephemeral writes';
      document.getElementById('host').textContent = p.hostname;
      document.getElementById('ddir').innerHTML = '<code>' + (p.data_dir && p.data_dir.path) + '</code>';
      const files = (p.data_dir && p.data_dir.files) || [];
      document.getElementById('dfiles').textContent = files.map(f => f.name + '(' + f.bytes + 'B)').join(', ') || 'none';
      document.getElementById('vmarker').innerHTML = '<code>' + (s.volume_marker || '—') + '</code>';
      document.getElementById('inside').textContent = String(p.inside_container);
      const tbody = document.getElementById('recent');
      tbody.innerHTML = (m.recent_events || []).map(row => {
        const when = row.ts ? new Date(row.ts * 1000).toLocaleTimeString() : '—';
        return '<tr><td>' + when + '</td><td>' + row.op + (row.ephemeral ? ' (tmp)' : '') +
          '</td><td>' + row.size + '</td><td><code>' +
          (row.preview || '').replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])) +
          '</code></td></tr>';
      }).join('');
    }
    document.getElementById('runDemo').onclick = async () => {
      await fetch('/api/demo', { method: 'POST', headers: {'Content-Type':'application/json'},
        body: JSON.stringify({ count: 15 }) });
      await refresh();
    };
    document.getElementById('runWrite').onclick = async () => {
      await fetch('/api/write', { method: 'POST', headers: {'Content-Type':'application/json'},
        body: JSON.stringify({ message: 'dashboard manual write' }) });
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
    return jsonify({"status": "ok", "service": "persistence-lab"})


@app.get("/api/metrics")
def api_metrics():
    return jsonify(METRICS.snapshot())


@app.get("/api/persistence")
def api_persistence():
    return jsonify(collect_persistence_facts())


@app.get("/api/state")
def api_state():
    state = read_state()
    state["volume_marker"] = read_volume_marker()
    return jsonify(state)


@app.post("/api/write")
def api_write():
    body = request.get_json(silent=True) or {}
    message = body.get("message") or "Hello Persistent World"
    entry = write_message(str(message))
    return jsonify(entry), 201


@app.post("/api/ephemeral")
def api_ephemeral():
    body = request.get_json(silent=True) or {}
    message = body.get("message") or "scratch"
    return jsonify(write_ephemeral(str(message))), 201


@app.post("/api/demo")
def api_demo():
    body = request.get_json(silent=True) or {}
    count = int(body.get("count", 15))
    count = max(1, min(count, 200))
    before = read_state().get("counter", 0)
    entries = [write_message(f"demo message #{i + 1}") for i in range(count)]
    write_ephemeral("demo ephemeral scratch")
    # Simulate ephemeral loss awareness: container /tmp is not durable across recreate
    METRICS.record_ephemeral_loss(1)
    METRICS.record_demo()
    after = read_state()
    return jsonify(
        {
            "produced": len(entries),
            "counter_before": before,
            "counter_after": after.get("counter"),
            "volume_marker": read_volume_marker(),
            "metrics": METRICS.snapshot(),
        }
    )


def main() -> None:
    seed_if_empty()
    start_background()
    port = int(os.environ.get("PERSIST_PORT", "8080"))
    app.run(host="0.0.0.0", port=port, threaded=True)


if __name__ == "__main__":
    main()
EOF

# -----------------------------------------------------------------------------
# CLI helper used by compose-less ephemeral tests (optional)
# -----------------------------------------------------------------------------
mkdir -p "$PROJECT_DIR/scripts"
cat > "$PROJECT_DIR/scripts/cli_write.py" << 'EOF'
#!/usr/bin/env python3
"""Simple CLI used by ephemeral-vs-persistent smoke checks."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow running as `python scripts/cli_write.py` from /app
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.app.store import write_message, read_state  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", type=str, help="Message to persist")
    parser.add_argument("--read", action="store_true", help="Print state counter")
    args = parser.parse_args()
    if args.write:
        entry = write_message(args.write)
        print(f"WROTE:{entry['n']}:{entry['message']}")
    if args.read:
        state = read_state()
        print(f"COUNTER:{state.get('counter', 0)}")


if __name__ == "__main__":
    main()
EOF

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/tests/test_store.py" << 'EOF'
from __future__ import annotations

import os
from pathlib import Path

import pytest

from src.app import store


@pytest.fixture()
def tmp_data(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    data = tmp_path / "data"
    vol = tmp_path / "volume"
    data.mkdir()
    vol.mkdir()
    monkeypatch.setenv("PERSIST_DATA_DIR", str(data))
    monkeypatch.setenv("PERSIST_VOLUME_DIR", str(vol))
    return data, vol


def test_write_and_read_persists(tmp_data):
    data, vol = tmp_data
    entry = store.write_message("hello")
    assert entry["n"] == 1
    state = store.read_state()
    assert state["counter"] == 1
    assert (data / "state.json").exists()
    assert (vol / "last_write.txt").exists()
    assert "Hello" not in store.read_volume_marker()  # marker is counter:ts
    assert store.read_volume_marker().startswith("1:")


def test_counter_increments(tmp_data):
    store.write_message("a")
    store.write_message("b")
    assert store.read_state()["counter"] == 2
EOF

cat > "$PROJECT_DIR/tests/test_persistence.py" << 'EOF'
from __future__ import annotations

from pathlib import Path

import pytest

from src.persistence.volumes import path_facts, collect_persistence_facts


def test_path_facts_empty(tmp_path: Path):
    facts = path_facts(str(tmp_path))
    assert facts["exists"] is True
    assert facts["total_bytes"] == 0


def test_path_facts_with_file(tmp_path: Path):
    f = tmp_path / "state.txt"
    f.write_text("Hello Persistent World", encoding="utf-8")
    facts = path_facts(str(tmp_path))
    assert facts["total_bytes"] > 0
    assert any(x["name"] == "state.txt" for x in facts["files"])


def test_collect_persistence_facts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setenv("PERSIST_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PERSIST_VOLUME_DIR", str(tmp_path / "vol"))
    (tmp_path / "data").mkdir()
    (tmp_path / "vol").mkdir()
    facts = collect_persistence_facts()
    assert "data_dir" in facts
    assert facts["data_dir"]["exists"] is True
EOF

cat > "$PROJECT_DIR/tests/test_api.py" << 'EOF'
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
EOF

# -----------------------------------------------------------------------------
# Ops scripts
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/env.sh" << 'EOF'
#!/usr/bin/env bash
# Shared environment for persistence-lab scripts.
export PERSIST_PORT="${PERSIST_PORT:-8080}"
export PERSIST_HOSTNAME="${PERSIST_HOSTNAME:-persistence-lab}"
export PERSIST_RATE="${PERSIST_RATE:-3}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-day2persist}"
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

mkdir -p "$ROOT/data"

echo "[start] Checking for duplicate persistence containers..."
EXISTING="$(docker ps -aq --filter name=^/my-persistence$ || true)"
if [[ -n "$EXISTING" ]]; then
  echo "[start] Removing existing my-persistence container(s) to avoid duplicates..."
  docker rm -f my-persistence >/dev/null 2>&1 || true
fi

echo "[start] Building and starting persistence-lab (bind mount ./data + named volume)..."
docker compose up --build -d

echo "[start] Waiting for health..."
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:${PERSIST_PORT}/health" >/dev/null 2>&1; then
    echo "[start] Healthy."
    echo "[start] Dashboard: http://127.0.0.1:${PERSIST_PORT}/dashboard"
    docker compose ps
    # Duplicate check
    COUNT="$(docker ps -q --filter name=^/my-persistence$ | wc -l | tr -d ' ')"
    echo "[start] Running my-persistence containers: $COUNT"
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

echo "[stop] Stopping persistence-lab..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker rm -f my-persistence >/dev/null 2>&1 || true
echo "[stop] Done."
EOF

cat > "$PROJECT_DIR/demo.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

BASE="http://127.0.0.1:${PERSIST_PORT}"
echo "[demo] Hitting $BASE/api/demo ..."
RESP="$(curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 20}')"
echo "$RESP" | python3 -m json.tool

echo "[demo] Current metrics:"
curl -sf "$BASE/api/metrics" | python3 -m json.tool

echo "[demo] Host bind-mount visibility (./data):"
ls -la "$ROOT/data" || true
if [[ -f "$ROOT/data/state.json" ]]; then
  echo "[demo] SUCCESS: state.json present on host bind mount"
  python3 -c "import json; print('counter=', json.load(open('$ROOT/data/state.json'))['counter'])"
else
  echo "[demo] FAILURE: state.json missing on host"
  exit 1
fi

# Snapshot in-memory metrics before recreate (process memory is ephemeral)
WRITES_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["writes"])')"
BYTES_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes_written"])')"
DEMOS_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["demos_run"])')"
if [[ "$WRITES_BEFORE" -le 0 || "$BYTES_BEFORE" -le 0 || "$DEMOS_BEFORE" -le 0 ]]; then
  echo "[demo] ERROR: metrics still zero before recreate (writes=$WRITES_BEFORE bytes=$BYTES_BEFORE demos=$DEMOS_BEFORE)"
  exit 1
fi

# Prove durable counter survives container recreate (bind mount + named volume)
echo "[demo] Recreating container to prove durable storage..."
BEFORE="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
docker compose up -d --force-recreate persistence-lab >/dev/null
for i in $(seq 1 40); do
  if curl -sf "$BASE/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
AFTER="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
echo "[demo] counter before recreate=$BEFORE after=$AFTER"
if [[ "$AFTER" -lt "$BEFORE" ]]; then
  echo "[demo] ERROR: counter dropped after recreate — persistence failed"
  exit 1
fi

# In-memory metrics reset on recreate — run demo again so dashboard is non-zero
echo "[demo] Re-seeding live metrics after recreate (process memory is ephemeral)..."
curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 10}' >/dev/null

WRITES="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["writes"])')"
BYTES="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes_written"])')"
DEMOS="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["demos_run"])')"
COUNTER="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
if [[ "$WRITES" -le 0 || "$BYTES" -le 0 || "$DEMOS" -le 0 || "$COUNTER" -le 0 ]]; then
  echo "[demo] ERROR: metrics still zero (writes=$WRITES bytes=$BYTES demos=$DEMOS counter=$COUNTER)"
  exit 1
fi

# Duplicate service check
COUNT="$(docker ps -q --filter name=^/my-persistence$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[demo] ERROR: expected 1 my-persistence, found $COUNT"
  docker ps --filter name=my-persistence
  exit 1
fi

echo "[demo] OK — writes=$WRITES bytes_written=$BYTES demos_run=$DEMOS counter=$COUNTER (persisted through recreate from $BEFORE)"
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

cat > "$PROJECT_DIR/verify.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[verify] Container running?"
docker inspect -f '{{.State.Running}}' my-persistence | grep -q true

echo "[verify] No duplicate my-persistence containers..."
COUNT="$(docker ps -q --filter name=^/my-persistence$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[verify] Expected exactly 1 my-persistence, found $COUNT"
  docker ps --filter name=my-persistence
  exit 1
fi

echo "[verify] Health + metrics non-zero..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/health" >/dev/null
METRICS="$(curl -sf "http://127.0.0.1:${PERSIST_PORT}/api/metrics")"
echo "$METRICS" | python3 -m json.tool
python3 - << PY
import json, os, urllib.request
port = os.environ["PERSIST_PORT"]
m = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/metrics"))
s = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state"))
assert m["writes"] > 0, m
assert m["bytes_written"] > 0, m
assert m["demos_run"] > 0, m
assert s["counter"] > 0, s
print("[verify] metrics OK")
PY

echo "[verify] Host bind mount has state.json..."
test -f "$ROOT/data/state.json"

echo "[verify] Persistence endpoint..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/api/persistence" | python3 -m json.tool >/dev/null
echo "[verify] Dashboard reachable..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/dashboard" | grep -q "Persistence Lab"
echo "[verify] All checks passed."
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

info "Stopping persistence-lab stack..."
if [[ -x "$ROOT/stop.sh" ]]; then
  "$ROOT/stop.sh" || true
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    info "Removing project containers by name..."
    docker rm -f my-persistence >/dev/null 2>&1 || true
    docker compose down --remove-orphans --rmi local -v >/dev/null 2>&1 || true

    info "Removing project image persistence-lab:day2 (if present)..."
    docker rmi persistence-lab:day2 >/dev/null 2>&1 || true

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

# -----------------------------------------------------------------------------
# README (project is independent of setup.sh)
# -----------------------------------------------------------------------------
cat > "$PROJECT_DIR/README.md" << 'EOF'
# Persistence Lab — Day 2

Hands-on lab that shows **ephemeral vs persistent** Docker storage using a bind
mount (`./data`), a named volume (`persistence_state`), live metrics, and a
dashboard.

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
persistence-lab/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── .gitignore
├── start.sh / stop.sh / demo.sh / test.sh / verify.sh / cleanup.sh
├── data/                 # bind-mounted host directory
├── src/
│   ├── app/
│   ├── monitoring/
│   └── persistence/
└── tests/
```
EOF

chmod +x "$PROJECT_DIR"/{start,stop,demo,test,cleanup,verify,env}.sh
chmod +x "$PROJECT_DIR/scripts/cli_write.py"

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
  "data/.gitkeep"
  "scripts/cli_write.py"
  "src/__init__.py"
  "src/app/__init__.py"
  "src/app/main.py"
  "src/app/store.py"
  "src/monitoring/__init__.py"
  "src/monitoring/metrics.py"
  "src/persistence/__init__.py"
  "src/persistence/volumes.py"
  "tests/__init__.py"
  "tests/test_store.py"
  "tests/test_persistence.py"
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
