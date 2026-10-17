"""Inspect mount points and compare ephemeral vs persistent paths."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any


def _read_mounts() -> list[dict[str, str]]:
    mounts: list[dict[str, str]] = []
    try:
        text = Path("/proc/self/mountinfo").read_text(encoding="utf-8")
    except OSError:
        return mounts
    for line in text.splitlines():
        # mountinfo: ... - fstype source opts
        parts = line.split(" - ", 1)
        if len(parts) != 2:
            continue
        left, right = parts
        left_cols = left.split()
        right_cols = right.split()
        if len(left_cols) < 5 or len(right_cols) < 2:
            continue
        mounts.append(
            {
                "mount_point": left_cols[4],
                "fstype": right_cols[0],
                "source": right_cols[1],
            }
        )
    return mounts


def path_facts(path: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists()
    files = []
    total_bytes = 0
    if exists and p.is_dir():
        for child in sorted(p.iterdir()):
            if child.is_file():
                size = child.stat().st_size
                files.append({"name": child.name, "bytes": size})
                total_bytes += size
    return {
        "path": path,
        "exists": exists,
        "is_dir": p.is_dir() if exists else False,
        "files": files,
        "total_bytes": total_bytes,
        "writable": os.access(path, os.W_OK) if exists else False,
    }


def collect_persistence_facts() -> dict[str, Any]:
    data_dir = os.environ.get("PERSIST_DATA_DIR", "/app/data")
    volume_dir = os.environ.get("PERSIST_VOLUME_DIR", "/app/volume-data")
    ephemeral_dir = "/tmp/ephemeral-lab"

    mounts = _read_mounts()
    interesting = [
        m
        for m in mounts
        if m["mount_point"] in {data_dir, volume_dir, "/app", "/"}
        or data_dir.startswith(m["mount_point"])
        or volume_dir.startswith(m["mount_point"])
    ]

    return {
        "hostname": os.environ.get("PERSIST_HOSTNAME", "unknown"),
        "inside_container": Path("/.dockerenv").exists(),
        "data_dir": path_facts(data_dir),
        "volume_dir": path_facts(volume_dir),
        "ephemeral_dir": path_facts(ephemeral_dir),
        "mounts_sample": interesting[:12] or mounts[:8],
        "bind_mount_active": any(
            m["mount_point"] == data_dir or data_dir.startswith(m["mount_point"] + "/")
            for m in mounts
            if m["mount_point"] not in {"/", "/app"}
        )
        or Path(data_dir).is_mount()
        or Path("/.dockerenv").exists(),
    }
