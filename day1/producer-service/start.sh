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
