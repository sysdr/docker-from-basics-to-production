# Persistence Lab — Day 2

Hands-on lab that shows **ephemeral vs persistent** Docker storage using a bind
mount (`./data`), a named volume (`persistence_state`), live metrics, and a
dashboard. No third-party API keys are required.

## Quick start

```bash
./start.sh
./demo.sh
# Dashboard: http://127.0.0.1:8080/dashboard
./test.sh
./verify.sh
./stop.sh
```

Tear down containers, prune Docker resources/images, remove local junk, and stop Docker:

```bash
./cleanup.sh
```

## Requirements

- Docker Desktop / Docker Engine 20.10+
- Docker Compose v2
- Python 3.11+ (for `./test.sh`)

Install host test deps with:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

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

## API (summary)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Liveness |
| GET | `/dashboard` | Live metrics UI |
| GET | `/api/metrics` | In-process counters |
| GET | `/api/state` | Durable counter + messages |
| GET | `/api/persistence` | Mount / path introspection |
| POST | `/api/write` | Persist a message |
| POST | `/api/ephemeral` | Write to `/tmp` (lost on recreate) |
| POST | `/api/demo` | Batch durable writes + ephemeral scratch |
