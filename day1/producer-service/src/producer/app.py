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
