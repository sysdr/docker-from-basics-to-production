#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[verify] Container running?"
docker inspect -f '{{.State.Running}}' my-persistence | grep -q true

echo "[verify] No duplicate my-persistence containers..."
COUNT="$(docker ps -q --filter name=^/my-persistence$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[verify] Expected exactly 1 my-persistence, found $COUNT"
  docker ps --filter name=my-persistence
  exit 1
fi

echo "[verify] Health + metrics non-zero..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/health" >/dev/null
METRICS="$(curl -sf "http://127.0.0.1:${PERSIST_PORT}/api/metrics")"
echo "$METRICS" | python3 -m json.tool
python3 - << PY
import json, os, urllib.request
port = os.environ["PERSIST_PORT"]
m = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/metrics"))
s = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state"))
assert m["writes"] > 0, m
assert m["bytes_written"] > 0, m
assert m["demos_run"] > 0, m
assert s["counter"] > 0, s
print("[verify] metrics OK")
PY

echo "[verify] Host bind mount has state.json..."
test -f "$ROOT/data/state.json"

echo "[verify] Persistence endpoint..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/api/persistence" | python3 -m json.tool >/dev/null
echo "[verify] Dashboard reachable..."
curl -sf "http://127.0.0.1:${PERSIST_PORT}/dashboard" | grep -q "Persistence Lab"
echo "[verify] All checks passed."
