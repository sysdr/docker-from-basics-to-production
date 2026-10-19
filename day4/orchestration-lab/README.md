# Orchestration Lab — Day 4

Hands-on lab that demonstrates **declarative Docker Compose orchestration**:
desired state (`docker-compose.yml`), healthchecks, `depends_on` with
`service_healthy`, restart policies, a bind-mounted `transactions.log`, a live
metrics dashboard, demo, and tests. No third-party API keys are required.

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
orchestration-lab/
├── docker-compose.yml
├── requirements.txt
├── .gitignore
├── start.sh / stop.sh / demo.sh / test.sh / verify.sh / cleanup.sh
├── data/                 # bind-mounted host directory (transactions.log)
├── producer/Dockerfile
├── worker/Dockerfile
├── src/
│   ├── producer/
│   ├── worker/
│   ├── monitoring/
│   └── orchestration/
└── tests/
```

## What you learn

- Compose declares **desired state** (services, network, volumes, health, restart)
- `depends_on: condition: service_healthy` waits for readiness, not just start
- Bind mounts keep `transactions.log` durable on the host
- Worker only joins after `producer_service` is healthy
