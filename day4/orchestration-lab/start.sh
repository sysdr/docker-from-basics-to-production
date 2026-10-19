#!/usr/bin/env bash
# start.sh: Declarative Orchestration — bring desired Compose state online
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "--- Checking Docker Engine ---"
docker --version || { echo "Docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable"; exit 1; }

mkdir -p "$ROOT/data"

echo "[start] Preparing Docker network ${LAB_NETWORK} for compose..."
# If a leftover non-compose orch-net exists, remove it so compose can own the name.
if docker network inspect "${LAB_NETWORK}" >/dev/null 2>&1; then
  LABEL="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "${LAB_NETWORK}" 2>/dev/null || true)"
  if [[ -z "${LABEL}" ]]; then
    echo "[start] Removing non-compose ${LAB_NETWORK} so compose can recreate it..."
    docker network rm "${LAB_NETWORK}" >/dev/null 2>&1 || true
  fi
fi

echo "--- Building and Launching via Compose ---"
docker compose up --build -d

echo "[start] Waiting for health..."
for i in $(seq 1 60); do
  P_OK="$(docker inspect -f '{{.State.Running}}' producer_service 2>/dev/null || echo false)"
  W_OK="$(docker inspect -f '{{.State.Running}}' worker_service 2>/dev/null || echo false)"
  P_H="$(curl -sf "http://127.0.0.1:${PRODUCER_PORT}/health" >/dev/null 2>&1 && echo true || echo false)"
  W_H="$(curl -sf "http://127.0.0.1:${WORKER_PORT}/health" >/dev/null 2>&1 && echo true || echo false)"
  if [[ "$P_OK" == "true" && "$W_OK" == "true" && "$P_H" == "true" && "$W_H" == "true" ]]; then
    echo "[start] Services healthy after ${i}s"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "[start] FAILURE: services did not become healthy"
    docker compose ps
    docker compose logs --tail=80
    exit 1
  fi
  sleep 1
done

echo "--- Verifying Service Health ---"
if [ "$(docker inspect -f '{{.State.Running}}' producer_service)" == "true" ]; then
  echo "SUCCESS: Producer is running."
else
  echo "FAILURE: Producer failed to start."
  exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' worker_service)" == "true" ]; then
  echo "SUCCESS: Worker is running."
else
  echo "FAILURE: Worker failed to start."
  exit 1
fi

# Seed a transaction so the durable log exists for the persistence check
curl -sf -X POST "http://127.0.0.1:${PRODUCER_PORT}/api/write" \
  -H 'Content-Type: application/json' \
  -d '{"message":"bootstrap transaction"}' >/dev/null

echo "--- Verifying Data Persistence ---"
sleep 2
if [ -f "./data/transactions.log" ]; then
  echo "SUCCESS: Data file detected."
else
  echo "FAILURE: Data file missing."
  exit 1
fi

PCOUNT="$(docker ps -q --filter name=^/producer_service$ | wc -l | tr -d ' ')"
WCOUNT="$(docker ps -q --filter name=^/worker_service$ | wc -l | tr -d ' ')"
if [[ "$PCOUNT" != "1" || "$WCOUNT" != "1" ]]; then
  echo "[start] ERROR: duplicate or missing services (producer=$PCOUNT worker=$WCOUNT)"
  docker ps --filter name=producer_service --filter name=worker_service
  exit 1
fi

echo "[start] Done. Dashboard: http://127.0.0.1:${PRODUCER_PORT}/dashboard"
docker compose ps
