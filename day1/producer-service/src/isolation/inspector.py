"""Read Linux namespace and cgroup facts visible from inside the process."""
from __future__ import annotations

import os
import platform
import socket
from pathlib import Path
from typing import Any


def _read_text(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def _parse_cgroup_v2_memory_max() -> str | None:
    raw = _read_text("/sys/fs/cgroup/memory.max")
    if raw is None:
        # cgroup v1 fallback
        raw = _read_text("/sys/fs/cgroup/memory/memory.limit_in_bytes")
    return raw


def _parse_cgroup_cpu() -> dict[str, Any]:
    info: dict[str, Any] = {}
    max_raw = _read_text("/sys/fs/cgroup/cpu.max")
    if max_raw:
        parts = max_raw.split()
        info["cpu_max"] = max_raw
        if len(parts) == 2 and parts[0] != "max":
            try:
                quota, period = int(parts[0]), int(parts[1])
                info["cpu_limit_cores"] = round(quota / period, 3)
            except ValueError:
                pass
    else:
        quota = _read_text("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
        period = _read_text("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        if quota and period:
            info["cpu_cfs_quota_us"] = quota
            info["cpu_cfs_period_us"] = period
            try:
                q, p = int(quota), int(period)
                if q > 0 and p > 0:
                    info["cpu_limit_cores"] = round(q / p, 3)
            except ValueError:
                pass
    return info


def collect_isolation_facts() -> dict[str, Any]:
    ns_dir = Path("/proc/self/ns")
    namespaces = {}
    if ns_dir.is_dir():
        for entry in sorted(ns_dir.iterdir()):
            try:
                namespaces[entry.name] = os.readlink(entry)
            except OSError:
                namespaces[entry.name] = None

    mem_max = _parse_cgroup_v2_memory_max()
    mem_bytes = None
    if mem_max and mem_max != "max":
        try:
            mem_bytes = int(mem_max)
        except ValueError:
            mem_bytes = None

    return {
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "uid": os.getuid(),
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "configured_hostname": os.environ.get("PRODUCER_HOSTNAME"),
        "namespaces": namespaces,
        "cgroup_memory_max": mem_max,
        "cgroup_memory_max_mb": round(mem_bytes / (1024 * 1024), 2) if mem_bytes else None,
        "cgroup_cpu": _parse_cgroup_cpu(),
        "inside_container": Path("/.dockerenv").exists() or bool(namespaces),
    }
