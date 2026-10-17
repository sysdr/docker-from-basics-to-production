#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "[test] Installing test dependencies into a local venv (host-side unit/API tests)..."
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

echo "[test] Running pytest..."
PYTHONPATH="$ROOT" pytest -q tests/
echo "[test] All tests passed."
