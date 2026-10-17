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
