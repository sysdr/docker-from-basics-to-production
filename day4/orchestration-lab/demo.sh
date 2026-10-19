#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

BASE="http://127.0.0.1:${PRODUCER_PORT}"
WBASE="http://127.0.0.1:${WORKER_PORT}"

echo "[demo] Hitting $BASE/api/demo ..."
RESP="$(curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 20}')"
echo "$RESP" | python3 -m json.tool

echo "[demo] Producer metrics:"
curl -sf "$BASE/api/metrics" | python3 -m json.tool

echo "[demo] Worker metrics:"
curl -sf "$WBASE/api/metrics" | python3 -m json.tool

echo "[demo] Worker logs (Processed tokens):"
WORKER_LOGS="$(docker logs worker_service 2>&1 || true)"
grep "Processed" <<<"$WORKER_LOGS" | tail -10 || true

WRITTEN="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["transactions_written"])')"
BYTES="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["bytes_persisted"])')"
DEMOS="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["demos_run"])')"
PROCESSED="$(curl -sf "$WBASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["transactions_processed"])')"
PEERS="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["peer_probes_ok"])')"

if [[ "$WRITTEN" -le 0 || "$PROCESSED" -le 0 || "$BYTES" -le 0 || "$DEMOS" -le 0 ]]; then
  echo "[demo] ERROR: metrics still zero (written=$WRITTEN processed=$PROCESSED bytes=$BYTES demos=$DEMOS)"
  exit 1
fi

if [[ ! -f "./data/transactions.log" ]]; then
  echo "[demo] ERROR: transactions.log missing on host bind mount"
  exit 1
fi
LINES="$(wc -l < ./data/transactions.log | tr -d ' ')"
if [[ "$LINES" -le 0 ]]; then
  echo "[demo] ERROR: transactions.log is empty"
  exit 1
fi

python3 - << PY
import json, os, urllib.request
port = os.environ["PRODUCER_PORT"]
n = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/orchestration"))
assert n.get("peer_dns", {}).get("resolved"), n
assert n.get("peer_health", {}).get("ok"), n
assert n.get("tx_log_exists"), n
print("[demo] DNS + peer health + tx log OK:", n["peer_dns"]["addresses"], "lines=", n["tx_log_lines"])
PY

PCOUNT="$(docker ps -q --filter name=^/producer_service$ | wc -l | tr -d ' ')"
WCOUNT="$(docker ps -q --filter name=^/worker_service$ | wc -l | tr -d ' ')"
if [[ "$PCOUNT" != "1" || "$WCOUNT" != "1" ]]; then
  echo "[demo] ERROR: expected 1 producer_service and 1 worker_service, found producer=$PCOUNT worker=$WCOUNT"
  docker ps --filter name=producer_service --filter name=worker_service
  exit 1
fi

echo "[demo] OK — written=$WRITTEN processed=$PROCESSED bytes=$BYTES demos=$DEMOS peers=$PEERS log_lines=$LINES"
echo "[demo] Open dashboard: $BASE/dashboard"
