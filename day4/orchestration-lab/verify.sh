#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[verify] Containers running?"
docker inspect -f '{{.State.Running}}' producer_service | grep -q true
docker inspect -f '{{.State.Running}}' worker_service | grep -q true

echo "[verify] No duplicate producer/worker containers..."
PCOUNT="$(docker ps -q --filter name=^/producer_service$ | wc -l | tr -d ' ')"
WCOUNT="$(docker ps -q --filter name=^/worker_service$ | wc -l | tr -d ' ')"
if [[ "$PCOUNT" != "1" || "$WCOUNT" != "1" ]]; then
  echo "[verify] Expected 1 producer_service + 1 worker_service, found producer=$PCOUNT worker=$WCOUNT"
  docker ps --filter name=producer_service --filter name=worker_service
  exit 1
fi

echo "[verify] Both on orch-net..."
docker network inspect orch-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q producer_service
docker network inspect orch-net --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q worker_service

echo "[verify] Health + metrics non-zero..."
curl -sf "http://127.0.0.1:${PRODUCER_PORT}/health" >/dev/null
curl -sf "http://127.0.0.1:${WORKER_PORT}/health" >/dev/null
python3 - << PY
import json, os, urllib.request
p = os.environ["PRODUCER_PORT"]
w = os.environ["WORKER_PORT"]
m = json.load(urllib.request.urlopen(f"http://127.0.0.1:{p}/api/metrics"))
wm = json.load(urllib.request.urlopen(f"http://127.0.0.1:{w}/api/metrics"))
assert m["transactions_written"] > 0, m
assert m["bytes_persisted"] > 0, m
assert m["demos_run"] > 0, m
assert wm["transactions_processed"] > 0, wm
print("[verify] metrics OK", {
    "written": m["transactions_written"],
    "processed": wm["transactions_processed"],
    "demos": m["demos_run"],
})
PY

echo "[verify] transactions.log on host..."
test -f ./data/transactions.log
test -s ./data/transactions.log

echo "[verify] Worker Processed logs..."
WORKER_LOGS="$(docker logs worker_service 2>&1 || true)"
if ! grep -q "Processed" <<<"$WORKER_LOGS"; then
  echo "[verify] ERROR: no Processed lines in worker logs"
  exit 1
fi

echo "[verify] Dashboard reachable..."
DASH="$(curl -sf "http://127.0.0.1:${PRODUCER_PORT}/dashboard")"
if ! grep -q "Orchestration Lab" <<<"$DASH"; then
  echo "[verify] ERROR: dashboard HTML missing expected title"
  exit 1
fi
echo "[verify] All checks passed."
