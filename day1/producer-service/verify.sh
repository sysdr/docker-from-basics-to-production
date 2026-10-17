#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[verify] Container running?"
docker inspect -f '{{.State.Running}}' my-producer | grep -q true

echo "[verify] No duplicate my-producer containers..."
COUNT="$(docker ps -q --filter name=^/my-producer$ | wc -l | tr -d ' ')"
if [[ "$COUNT" != "1" ]]; then
  echo "[verify] Expected exactly 1 my-producer, found $COUNT"
  docker ps --filter name=my-producer
  exit 1
fi

echo "[verify] Health + metrics non-zero..."
curl -sf "http://127.0.0.1:${PRODUCER_PORT}/health" >/dev/null
METRICS="$(curl -sf "http://127.0.0.1:${PRODUCER_PORT}/api/metrics")"
echo "$METRICS" | python3 -m json.tool
python3 - << PY
import json, os, urllib.request
m = json.load(urllib.request.urlopen("http://127.0.0.1:%s/api/metrics" % os.environ["PRODUCER_PORT"]))
assert m["messages_produced"] > 0, m
assert m["bytes_produced"] > 0, m
print("[verify] metrics OK")
PY

echo "[verify] Isolation endpoint..."
curl -sf "http://127.0.0.1:${PRODUCER_PORT}/api/isolation" | python3 -m json.tool >/dev/null
echo "[verify] All checks passed."
