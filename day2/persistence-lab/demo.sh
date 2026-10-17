#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

BASE="http://127.0.0.1:${PERSIST_PORT}"
echo "[demo] Hitting $BASE/api/demo ..."
RESP="$(curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 20}')"
echo "$RESP" | python3 -m json.tool

echo "[demo] Current metrics:"
curl -sf "$BASE/api/metrics" | python3 -m json.tool

echo "[demo] Host bind-mount visibility (./data):"
ls -la "$ROOT/data" || true
if [[ -f "$ROOT/data/state.json" ]]; then
  echo "[demo] SUCCESS: state.json present on host bind mount"
  python3 -c "import json; print('counter=', json.load(open('$ROOT/data/state.json'))['counter'])"
else
  echo "[demo] FAILURE: state.json missing on host"
  exit 1
fi

# Snapshot in-memory metrics before recreate (process memory is ephemeral)
WRITES_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["writes"])')"
BYTES_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes_written"])')"
DEMOS_BEFORE="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["demos_run"])')"
if [[ "$WRITES_BEFORE" -le 0 || "$BYTES_BEFORE" -le 0 || "$DEMOS_BEFORE" -le 0 ]]; then
  echo "[demo] ERROR: metrics still zero before recreate (writes=$WRITES_BEFORE bytes=$BYTES_BEFORE demos=$DEMOS_BEFORE)"
  exit 1
fi

# Prove durable counter survives container recreate (bind mount + named volume)
echo "[demo] Recreating container to prove durable storage..."
BEFORE="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
docker compose up -d --force-recreate persistence-lab >/dev/null
for i in $(seq 1 40); do
  if curl -sf "$BASE/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
AFTER="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
echo "[demo] counter before recreate=$BEFORE after=$AFTER"
if [[ "$AFTER" -lt "$BEFORE" ]]; then
  echo "[demo] ERROR: counter dropped after recreate — persistence failed"
  exit 1
fi

# In-memory metrics reset on recreate — run demo again so dashboard is non-zero
echo "[demo] Re-seeding live metrics after recreate (process memory is ephemeral)..."
curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 10}' >/dev/null

WRITES="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["writes"])')"
BYTES="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes_written"])')"
DEMOS="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["demos_run"])')"
COUNTER="$(curl -sf "$BASE/api/state" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counter"])')"
if [[ "$WRITES" -le 0 || "$BYTES" -le 0 || "$DEMOS" -le 0 || "$COUNTER" -le 0 ]]; then
  echo "[demo] ERROR: metrics still zero (writes=$WRITES bytes=$BYTES demos=$DEMOS counter=$COUNTER)"
  exit 1
fi

# Duplicate service check
COUNT="$(docker ps -q --filter name=^/my-persistence$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[demo] ERROR: expected 1 my-persistence, found $COUNT"
  docker ps --filter name=my-persistence
  exit 1
fi

echo "[demo] OK — writes=$WRITES bytes_written=$BYTES demos_run=$DEMOS counter=$COUNTER (persisted through recreate from $BEFORE)"
echo "[demo] Open dashboard: $BASE/dashboard"
