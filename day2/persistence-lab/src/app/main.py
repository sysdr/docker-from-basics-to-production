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
