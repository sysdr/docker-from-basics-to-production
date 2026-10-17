#!/usr/bin/env bash
# Shared environment for producer-service scripts.
export PRODUCER_PORT="${PRODUCER_PORT:-8080}"
export PRODUCER_HOSTNAME="${PRODUCER_HOSTNAME:-producer-service}"
export PRODUCER_RATE="${PRODUCER_RATE:-5}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-day1producer}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
