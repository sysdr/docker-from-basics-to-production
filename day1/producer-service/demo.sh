#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"

BASE="http://127.0.0.1:${PRODUCER_PORT}"
echo "[demo] Hitting $BASE/api/demo ..."
RESP="$(curl -sf -X POST "$BASE/api/demo" \
  -H 'Content-Type: application/json' \
  -d '{"count": 40}')"
echo "$RESP" | python3 -m json.tool

echo "[demo] Current metrics:"
curl -sf "$BASE/api/metrics" | python3 -m json.tool

MSG="$(curl -sf "$BASE/api/metrics" | python3 -c 'import sys,json; print(json.load(sys.stdin)["messages_produced"])')"
if [[ "$MSG" -le 0 ]]; then
  echo "[demo] ERROR: messages_produced is still zero"
  exit 1
fi
echo "[demo] OK — messages_produced=$MSG (non-zero)"
echo "[demo] Open dashboard: $BASE/dashboard"
