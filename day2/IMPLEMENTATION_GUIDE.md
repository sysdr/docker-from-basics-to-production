## Implementation Guide: Persistence Lab (Day 2 — Docker Volumes)

This guide describes **`persistence-lab`**, a self-contained Python / Flask service that demonstrates **ephemeral vs durable container storage** in Docker: a **host bind mount** (`./data` → `/app/data`), a **named volume** (`persistence_state` → `/app/volume-data`), atomic JSON state writes, a **live metrics dashboard**, demo and verify scripts, and pytest coverage. There are **no third-party API keys** in the project.

---

## Overview

- **Purpose:** Prove that container filesystems are ephemeral by default, then make application state survive container recreate via bind mounts and named volumes. A durable counter and message log live under `/app/data`; a compact marker is mirrored into the named volume; scratch writes under `/tmp` illustrate data that disappears when the container is replaced.
- **Stack:** Python **3.12** (image) / **3.11+** (host tests), Flask **3.0.3**, Docker Compose v2, pytest **8.3.3**.
- **Ports:** Service and dashboard on **8080**.
- **Operations:** `./start.sh` builds and runs the stack; `./demo.sh` writes durable data, recreates the container, and confirms the counter survives; `./test.sh` runs host-side unit/API tests; `./verify.sh` checks health, unique container, non-zero metrics, and dashboard HTML; `./cleanup.sh` stops containers, prunes unused Docker resources/images, removes local junk, and stops the Docker daemon / Desktop.

---

## Architecture

```
Host browser
  └─ http://127.0.0.1:8080/dashboard
       │  poll /api/metrics, /api/state, /api/persistence, /health
       ▼
Container my-persistence  (image persistence-lab:day2)
  Flask app  python -m src.app.main
    ├─ background writer (PERSIST_RATE msgs/s) ──► store.write_message()
    ├─ POST /api/write | /api/demo              ──► durable state
    └─ POST /api/ephemeral                      ──► /tmp/ephemeral-lab (lost on recreate)

Durable paths
  Bind mount:  ./data  (host)  ◄──►  /app/data  (container)
                 state.json, events.jsonl
  Named volume: persistence_state ◄──► /app/volume-data/last_write.txt

Ephemeral path
  /tmp/ephemeral-lab/scratch.txt   (container layer / tmp — not durable)
```

**Day 2 idea:** Compute is disposable; state must be deliberate. After `docker compose up --force-recreate`, the durable counter on the bind mount (and the volume marker) still increase from the previous value, while in-memory metrics reset until traffic runs again.

---

## Project layout

```
day2/
  IMPLEMENTATION_GUIDE.md          # This file (outside the Git-pushed subtree)
  persistence-lab/                 # Git-pushed project root
    README.md
    requirements.txt
    .gitignore
    cleanup.sh
    start.sh / stop.sh / demo.sh / test.sh / verify.sh / env.sh
    Dockerfile
    docker-compose.yml
    data/                          # Bind-mounted; runtime files gitignored
    scripts/cli_write.py           # Optional CLI write/read helper
    src/
      app/
        main.py                    # Flask API + embedded dashboard
        store.py                   # Locked atomic durable I/O
      monitoring/
        metrics.py                 # Thread-safe in-process counters
      persistence/
        volumes.py                 # Mount / path introspection
    tests/
      test_store.py
      test_persistence.py
      test_api.py
```

---

## Design

### Durable store (`src/app/store.py`)

- **`PERSIST_DATA_DIR`** (default `/app/data`) holds `state.json` (counter, recent messages, boot metadata) and append-only `events.jsonl`.
- **`PERSIST_VOLUME_DIR`** (default `/app/volume-data`) holds `last_write.txt` (`counter:timestamp`) so the named volume participates in the persistence story.
- Writes use a **`threading.RLock`** and **atomic replace** (`*.tmp` → final path) to avoid torn JSON when the background writer and HTTP handlers race.
- Corrupt `state.json` is quarantined and replaced with an empty state so the lab recovers instead of crashing forever.
- **`seed_if_empty()`** writes seed messages on first boot, or records `persist_survived` when existing state is found after recreate.

### Ephemeral scratch

- **`write_ephemeral()`** writes under `/tmp/ephemeral-lab`. Demo increments `ephemeral_lost` to highlight that `/tmp` is not a durability strategy across container replacement.

### Metrics (`src/monitoring/metrics.py`)

- In-process counters: `writes`, `reads`, `bytes_written`, `bytes_read`, `demos_run`, `ephemeral_writes`, `ephemeral_lost`, `persist_survived`, rate and uptime, plus a recent-events ring buffer.
- These live in process memory — they reset on recreate (by design). Durable proof is the **counter in `state.json`**, visible on the host bind mount.

### Persistence introspection (`src/persistence/volumes.py`)

- Reads `/proc/self/mountinfo` when available, reports path facts for data / volume / ephemeral directories, and whether the process appears to be inside a container.

### Background writer

- Daemon thread writes at `PERSIST_RATE` (default `3`) so the dashboard stays lively after boot without requiring constant manual demos.

---

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` / `/dashboard` | Live HTML dashboard |
| `GET` | `/health` | `{ "status": "ok", "service": "persistence-lab" }` |
| `GET` | `/api/metrics` | Snapshot of in-process metrics |
| `GET` | `/api/state` | Durable state + `volume_marker` |
| `GET` | `/api/persistence` | Mount/path introspection |
| `POST` | `/api/write` | Body `{ "message": "..." }` → durable entry `201` |
| `POST` | `/api/ephemeral` | Body `{ "message": "..." }` → `/tmp` scratch `201` |
| `POST` | `/api/demo` | Body `{ "count": N }` → N durable writes + ephemeral scratch; returns counters and metrics |

Example:

```bash
curl -s http://127.0.0.1:8080/health
curl -s -X POST http://127.0.0.1:8080/api/demo \
  -H 'Content-Type: application/json' \
  -d '{"count": 20}'
curl -s http://127.0.0.1:8080/api/metrics
curl -s http://127.0.0.1:8080/api/state
```

---

## Dashboard / metrics

- URL: **http://127.0.0.1:8080/dashboard**
- Cards poll every ~1.5s: writes, reads, bytes written, persisted counter, demos run, ephemeral lost, plus storage introspection and recent events.
- Buttons: **Run Persistence Demo** (`POST /api/demo`) and **Write Message** (`POST /api/write`).
- After `./demo.sh`, values must be **non-zero** (`writes`, `bytes_written`, `demos_run`, durable `counter`). The demo recreates the container to prove durability, then re-runs a short demo so live (in-memory) metrics are non-zero again for dashboard validation.

---

## Build and run

From the project root (`persistence-lab/`):

```bash
./start.sh          # build image, start compose, wait for /health
./demo.sh           # durable writes, host bind-mount check, recreate proof
./test.sh           # venv + pytest
./verify.sh         # single container, metrics, dashboard
./stop.sh           # compose down
./cleanup.sh        # full teardown + Docker prune + stop Docker
```

Environment knobs (`env.sh`): `PERSIST_PORT` (8080), `PERSIST_HOSTNAME`, `PERSIST_RATE`, `COMPOSE_PROJECT_NAME`.

---

## Docker

### Image (`Dockerfile`)

- Base: `python:3.12-slim`
- Installs `requirements.txt`, copies `src/` and `scripts/`
- Ensures `/app/data` exists
- Healthcheck hits `http://127.0.0.1:8080/health`
- CMD: `python -m src.app.main`

### Compose (`docker-compose.yml`)

- Service name: `persistence-lab`
- Image tag: `persistence-lab:day2`
- Container name: `my-persistence` (start/verify enforce a single instance)
- Port: `8080:8080`
- Volumes:
  - Bind: `./data:/app/data`
  - Named: `persistence_state:/app/volume-data`
- Restart: `unless-stopped`
- Healthcheck aligned with the Dockerfile probe

---

## Tests

Host-side (`./test.sh`):

- **`test_store.py`** — write/read persistence and counter increments under temp dirs
- **`test_persistence.py`** — path facts and introspection helpers
- **`test_api.py`** — Flask test client for health, write→metrics, and demo→non-zero metrics

Integration-style checks live in **`demo.sh`** / **`verify.sh`** against the running container (bind-mount visibility, recreate survival, duplicate-container guard, dashboard HTML).

---

## Summary

Day 2 turns isolation into resilience for **state**: durable paths (bind mount + named volume) keep the counter and messages across container recreate, while `/tmp` and in-memory metrics show what does *not* survive. The Flask API and dashboard make those behaviors observable; scripts cover build, demo, test, verify, and full cleanup without any external API keys.
