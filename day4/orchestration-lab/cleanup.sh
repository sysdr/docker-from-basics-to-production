#!/usr/bin/env bash
# Stop project containers, remove junk artifacts, prune unused Docker
# resources/images, then stop the Docker service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[cleanup]${NC} $*"; }
warn() { echo -e "${YELLOW}[cleanup]${NC} $*"; }

dtimeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=KILL "$secs" "$@" || true
  else
    "$@" || true
  fi
}

info "Stopping orchestration-lab stack..."
if [[ -x "$ROOT/stop.sh" ]]; then
  "$ROOT/stop.sh" || true
fi

if command -v docker >/dev/null 2>&1; then
  if dtimeout 15 docker info >/dev/null 2>&1; then
    info "Removing project containers by name..."
    dtimeout 20 docker rm -f producer_service worker_service >/dev/null 2>&1 || true
    dtimeout 60 docker compose down --remove-orphans --rmi local -v >/dev/null 2>&1 || true

    info "Removing project images (if present)..."
    dtimeout 30 docker rmi producer-service:day4 worker-service:day4 >/dev/null 2>&1 || true

    info "Removing orch-net network (if unused)..."
    dtimeout 15 docker network rm orch-net >/dev/null 2>&1 || true

    info "Pruning unused containers, networks, and dangling images..."
    dtimeout 60 docker container prune -f >/dev/null 2>&1 || true
    dtimeout 60 docker network prune -f >/dev/null 2>&1 || true
    dtimeout 60 docker image prune -f >/dev/null 2>&1 || true
    dtimeout 90 docker system prune -f >/dev/null 2>&1 || true
  else
    warn "Docker daemon not reachable — skipping container/image prune."
  fi
else
  warn "docker CLI not found — skipping Docker cleanup."
fi

info "Removing node_modules, venv, caches, pyc, and Istio leftovers..."
find "$ROOT" \
  \( -type d \( -name node_modules -o -name .venv -o -name venv -o -name .pytest_cache -o -name '__pycache__' -o -name 'istio-*' \) \) \
  -prune -exec rm -rf {} + 2>/dev/null || true
find "$ROOT" \( -name '*.pyc' -o -name '*.pyo' -o -iname '*istio*.yaml' -o -iname '*istio*.yml' \) -type f -delete 2>/dev/null || true

info "Stopping Docker service / Docker Desktop (if available)..."
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
  sudo systemctl stop docker.service docker.socket 2>/dev/null || systemctl --user stop docker 2>/dev/null || true
fi
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command \
    "Stop-Process -Name 'Docker Desktop','com.docker.backend','com.docker.proxy' -Force -ErrorAction SilentlyContinue" \
    >/dev/null 2>&1 || true
fi

info "Done."
echo "Remaining Docker status (may fail if daemon stopped):"
docker ps -a 2>&1 | head -5 || true
