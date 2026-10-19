"""Producer service HTTP API and live orchestration dashboard."""
from __future__ import annotations

import os
import threading
import time

from flask import Flask, jsonify, request

from src.monitoring.metrics import METRICS
from src.orchestration.inspector import collect_orchestration_facts
from src.producer.core import run_demo, write_and_notify

app = Flask(__name__)

_bg_stop = threading.Event()
_bg_thread: threading.Thread | None = None


def _background_producer() -> None:
    rate = float(os.environ.get("PRODUCER_RATE", "2"))
    interval = 1.0 / max(rate, 0.1)
    n = 0
    # Wait briefly so worker can become healthy after depends_on.
    time.sleep(3)
    while not _bg_stop.wait(interval):
        n += 1
        try:
            write_and_notify(f"background tick #{n}")
        except Exception:
            pass


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
  <title>Orchestration Lab — Day 4 Dashboard</title>
  <style>
    :root {
      --bg: #0b1220;
      --panel: #121c2e;
      --text: #e7eefc;
      --muted: #8b9bb8;
      --accent: #5ec8ff;
      --warn: #f0b429;
      --ok: #5ad67d;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
      background: radial-gradient(1000px 520px at 10% -10%, #1a3358 0%, var(--bg) 55%);
      color: var(--text); min-height: 100vh;
    }
    header { padding: 1.5rem 2rem 0.5rem; }
    header h1 { margin: 0; font-size: 1.55rem; letter-spacing: 0.02em; }
    header p { margin: 0.4rem 0 0; color: var(--muted); }
    main { padding: 1rem 2rem 2rem; display: grid; gap: 1rem;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
    .card {
      background: color-mix(in srgb, var(--panel) 92%, white 8%);
      border: 1px solid #243552; border-radius: 12px; padding: 1rem 1.1rem;
    }
    .card h2 { margin: 0 0 0.6rem; font-size: 0.8rem; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.08em; }
    .value { font-size: 1.85rem; font-weight: 650; color: var(--accent); }
    .sub { color: var(--muted); font-size: 0.85rem; margin-top: 0.35rem; }
    .wide { grid-column: 1 / -1; }
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th, td { text-align: left; padding: 0.4rem 0.35rem; border-bottom: 1px solid #243552; }
    th { color: var(--muted); font-weight: 550; }
    .pill { display: inline-block; padding: 0.15rem 0.55rem; border-radius: 999px;
      background: #1a2a44; color: var(--ok); font-size: 0.8rem; }
    button {
      background: var(--accent); color: #041018; border: 0; border-radius: 8px;
      padding: 0.55rem 1rem; font-weight: 650; cursor: pointer; margin-right: 0.5rem;
    }
    button.secondary { background: #243552; color: var(--text); }
    button:hover { filter: brightness(1.08); }
    code { color: var(--warn); }
  </style>
</head>
<body>
  <header>
    <h1>Orchestration Lab — Day 4</h1>
    <p>Declarative Compose desired state: healthchecks, depends_on, restart, durable <code>transactions.log</code>.</p>
  </header>
  <main>
    <div class="card"><h2>Written</h2><div class="value" id="written">0</div>
      <div class="sub" id="tps">0 tx/s</div></div>
    <div class="card"><h2>Processed</h2><div class="value" id="processed">0</div>
      <div class="sub" id="failed">0 failed</div></div>
    <div class="card"><h2>Bytes Persisted</h2><div class="value" id="bytes">0</div>
      <div class="sub" id="loglines">0 log lines</div></div>
    <div class="card"><h2>Demos Run</h2><div class="value" id="demos">0</div>
      <div class="sub"><span class="pill" id="health">checking…</span></div></div>
    <div class="card"><h2>Peer Probes</h2><div class="value" id="peers">0</div>
      <div class="sub" id="desired">desired services: 2</div></div>
    <div class="card"><h2>Uptime</h2><div class="value" id="uptime">0s</div>
      <div class="sub" id="network">orch-net</div></div>
    <div class="card wide">
      <h2>Orchestration Introspection</h2>
      <table>
        <tr><th>Producer hostname</th><td id="phost">—</td></tr>
        <tr><th>Worker DNS</th><td id="wdns"><code>—</code></td></tr>
        <tr><th>Peer health</th><td id="phealth">—</td></tr>
        <tr><th>TX log</th><td id="txlog">—</td></tr>
        <tr><th>depends_on / restart</th><td id="deps">—</td></tr>
      </table>
      <p style="margin-top:1rem">
        <button id="runDemo">Run Orchestration Demo</button>
        <button class="secondary" id="runWrite">Write One Transaction</button>
      </p>
    </div>
    <div class="card wide">
      <h2>Recent Events</h2>
      <table>
        <thead><tr><th>op</th><th>preview</th><th>size</th></tr></thead>
        <tbody id="events"></tbody>
      </table>
    </div>
  </main>
  <script>
    async function refresh() {
      try {
        const [m, o, h, w] = await Promise.all([
          fetch('/api/metrics').then(r => r.json()),
          fetch('/api/orchestration').then(r => r.json()),
          fetch('/health').then(r => r.json()),
          fetch('/api/worker-metrics').then(r => r.json()).catch(() => ({transactions_processed: 0})),
        ]);
        document.getElementById('written').textContent = m.transactions_written;
        document.getElementById('tps').textContent = m.tx_per_second + ' tx/s';
        document.getElementById('processed').textContent = w.transactions_processed ?? 0;
        document.getElementById('failed').textContent = (m.transactions_failed || 0) + ' failed';
        document.getElementById('bytes').textContent = m.bytes_persisted;
        document.getElementById('loglines').textContent = (o.tx_log_lines || 0) + ' log lines';
        document.getElementById('demos').textContent = m.demos_run;
        document.getElementById('peers').textContent = m.peer_probes_ok;
        document.getElementById('desired').textContent = 'desired services: ' + (m.desired_services || 2);
        document.getElementById('uptime').textContent = Math.round(m.uptime_seconds) + 's';
        document.getElementById('network').textContent = o.lab_network || 'orch-net';
        document.getElementById('health').textContent = h.status === 'ok' ? 'healthy' : 'degraded';
        document.getElementById('phost').textContent = o.hostname || '—';
        const dns = o.peer_dns || {};
        document.getElementById('wdns').innerHTML = '<code>' + (dns.addresses || []).join(', ') + '</code>';
        document.getElementById('phealth').textContent = (o.peer_health && o.peer_health.ok) ? 'OK' : 'waiting';
        document.getElementById('txlog').textContent = (o.tx_log_exists ? 'present' : 'missing') + ' @ ' + (o.tx_log_path || '');
        document.getElementById('deps').textContent = (o.depends_on || '') + ' | ' + (o.restart_policy || '');
        const tb = document.getElementById('events');
        tb.innerHTML = '';
        (m.recent_events || []).slice(0, 12).forEach(ev => {
          const tr = document.createElement('tr');
          tr.innerHTML = '<td>' + ev.op + '</td><td>' + (ev.preview || '') + '</td><td>' + ev.size + '</td>';
          tb.appendChild(tr);
        });
      } catch (e) {
        document.getElementById('health').textContent = 'error';
      }
    }
    document.getElementById('runDemo').onclick = async () => {
      await fetch('/api/demo', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({count: 20})});
      refresh();
    };
    document.getElementById('runWrite').onclick = async () => {
      await fetch('/api/write', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({message: 'manual write'})});
      refresh();
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
    METRICS.record_health_ok()
    return jsonify({"status": "ok", "service": "producer_service"})


@app.get("/api/metrics")
def metrics():
    return jsonify(METRICS.snapshot())


@app.get("/api/orchestration")
def orchestration():
    return jsonify(collect_orchestration_facts())


@app.get("/api/worker-metrics")
def worker_metrics():
    import json
    import urllib.error
    import urllib.request

    host = os.environ.get("WORKER_HOSTNAME", "worker_service")
    port = os.environ.get("WORKER_PORT", "8082")
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/api/metrics", timeout=2) as resp:
            return jsonify(json.loads(resp.read().decode("utf-8")))
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return jsonify({"transactions_processed": 0, "error": str(exc)}), 502


@app.post("/api/write")
def api_write():
    body = request.get_json(silent=True) or {}
    message = str(body.get("message") or "manual transaction")
    result = write_and_notify(message)
    return jsonify(result), 201


@app.post("/api/demo")
def api_demo():
    body = request.get_json(silent=True) or {}
    count = int(body.get("count") or 20)
    count = max(1, min(count, 200))
    return jsonify(run_demo(count))


def main() -> None:
    ensure = os.environ.get("DATA_DIR", "/app/data")
    os.makedirs(ensure, exist_ok=True)
    # Seed an empty log so start.sh persistence check can pass after first write cycle.
    start_background()
    port = int(os.environ.get("PRODUCER_PORT", "8080"))
    app.run(host="0.0.0.0", port=port, threaded=True)


if __name__ == "__main__":
    main()
