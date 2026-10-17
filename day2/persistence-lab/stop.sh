#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/env.sh"
cd "$ROOT"

echo "[stop] Stopping persistence-lab..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker rm -f my-persistence >/dev/null 2>&1 || true
echo "[stop] Done."
