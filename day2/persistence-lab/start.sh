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
