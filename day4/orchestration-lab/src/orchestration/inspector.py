"""Introspect declarative Compose desired-state facts from inside a container."""
from __future__ import annotations

import os
import socket
import urllib.error
import urllib.request
from typing import Any


def resolve_host(hostname: str) -> dict[str, Any]:
    try:
        infos = socket.getaddrinfo(hostname, None)
        addrs = sorted({i[4][0] for i in infos})
        return {"hostname": hostname, "resolved": True, "addresses": addrs}
    except OSError as exc:
        return {"hostname": hostname, "resolved": False, "error": str(exc), "addresses": []}


def probe_http(url: str, timeout: float = 2.0) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")[:200]
            return {"ok": True, "status": resp.status, "body_preview": body}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"ok": False, "error": str(exc)}


def collect_orchestration_facts() -> dict[str, Any]:
    role = os.environ.get("SERVICE_ROLE", "unknown")
    if role == "producer":
        peer = os.environ.get("WORKER_HOSTNAME", "worker_service")
        peer_port = os.environ.get("WORKER_PORT", "8082")
        depends = "none (root of depends_on chain)"
    else:
        peer = os.environ.get("PRODUCER_HOSTNAME", "producer_service")
        peer_port = os.environ.get("PRODUCER_PORT", "8080")
        depends = "producer_service (condition: service_healthy)"

    dns = resolve_host(peer)
    health: dict[str, Any] = {"ok": False}
    if dns.get("resolved"):
        health = probe_http(f"http://{peer}:{peer_port}/health")

    tx_log = os.environ.get("TX_LOG", "/app/data/transactions.log")
    log_exists = os.path.exists(tx_log)
    log_lines = 0
    if log_exists:
        try:
            with open(tx_log, "r", encoding="utf-8") as fh:
                log_lines = sum(1 for _ in fh)
        except OSError:
            log_lines = -1

    return {
        "service_role": role,
        "hostname": socket.gethostname(),
        "lab_network": os.environ.get("LAB_NETWORK", ""),
        "inside_container": os.path.exists("/.dockerenv"),
        "restart_policy": "unless-stopped (declared in compose)",
        "depends_on": depends,
        "healthcheck": "CMD python urllib /health (declared in compose)",
        "peer_dns": dns,
        "peer_health": health,
        "tx_log_path": tx_log,
        "tx_log_exists": log_exists,
        "tx_log_lines": log_lines,
        "desired_services": 2,
    }
