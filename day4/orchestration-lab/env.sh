#!/usr/bin/env bash
# Shared environment for orchestration-lab scripts
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-day4orch}"
export PRODUCER_PORT="${PRODUCER_PORT:-8080}"
export WORKER_PORT="${WORKER_PORT:-8082}"
export LAB_NETWORK="${LAB_NETWORK:-orch-net}"
export PRODUCER_RATE="${PRODUCER_RATE:-2}"
