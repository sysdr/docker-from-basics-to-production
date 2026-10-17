#!/usr/bin/env bash
# Shared environment for persistence-lab scripts.
export PERSIST_PORT="${PERSIST_PORT:-8080}"
export PERSIST_HOSTNAME="${PERSIST_HOSTNAME:-persistence-lab}"
export PERSIST_RATE="${PERSIST_RATE:-3}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-day2persist}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
