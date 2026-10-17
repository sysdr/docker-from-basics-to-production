"""Read/write durable application state under the data directory."""
from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from src.monitoring.metrics import METRICS

STATE_FILE = "state.json"
EVENTS_FILE = "events.jsonl"

_LOCK = threading.RLock()


def data_dir() -> Path:
    return Path(os.environ.get("PERSIST_DATA_DIR", "/app/data"))


def volume_dir() -> Path:
    return Path(os.environ.get("PERSIST_VOLUME_DIR", "/app/volume-data"))


def ephemeral_dir() -> Path:
    return Path("/tmp/ephemeral-lab")


def _ensure_dirs() -> None:
    data_dir().mkdir(parents=True, exist_ok=True)
    volume_dir().mkdir(parents=True, exist_ok=True)
    ephemeral_dir().mkdir(parents=True, exist_ok=True)


def _atomic_write(path: Path, payload: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, path)


def _empty_state() -> dict[str, Any]:
    return {
        "counter": 0,
        "messages": [],
        "boot_id": str(uuid.uuid4()),
        "created_at": time.time(),
        "updated_at": time.time(),
    }


def _load_state() -> dict[str, Any]:
    _ensure_dirs()
    path = data_dir() / STATE_FILE
    if not path.exists():
        return _empty_state()
    raw = path.read_text(encoding="utf-8")
    METRICS.record_read(len(raw.encode("utf-8")))
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Recover from a torn write (should be rare after atomic replace)
        backup = path.with_suffix(".corrupt")
        try:
            path.replace(backup)
        except OSError:
            path.unlink(missing_ok=True)
        return _empty_state()


def _save_state(state: dict[str, Any]) -> None:
    _ensure_dirs()
    state["updated_at"] = time.time()
    path = data_dir() / STATE_FILE
    payload = json.dumps(state, indent=2)
    _atomic_write(path, payload)
    METRICS.record_write(payload, ephemeral=False)
    # Mirror a compact marker into the named volume
    marker = volume_dir() / "last_write.txt"
    _atomic_write(marker, f"{state['counter']}:{state['updated_at']}\n")


def write_message(message: str) -> dict[str, Any]:
    with _LOCK:
        state = _load_state()
        state["counter"] = int(state.get("counter", 0)) + 1
        entry = {
            "id": str(uuid.uuid4()),
            "n": state["counter"],
            "message": message,
            "ts": time.time(),
        }
        messages = list(state.get("messages") or [])
        messages.append(entry)
        state["messages"] = messages[-50:]
        _save_state(state)

        events_path = data_dir() / EVENTS_FILE
        line = json.dumps(entry) + "\n"
        with events_path.open("a", encoding="utf-8") as fh:
            fh.write(line)
        METRICS.record_write(line, ephemeral=False)
        return entry


def write_ephemeral(message: str) -> dict[str, Any]:
    with _LOCK:
        _ensure_dirs()
        path = ephemeral_dir() / "scratch.txt"
        payload = f"{time.time()}:{message}\n"
        path.write_text(payload, encoding="utf-8")
        METRICS.record_write(payload, ephemeral=True)
        return {"path": str(path), "bytes": len(payload.encode("utf-8")), "message": message}


def read_state() -> dict[str, Any]:
    with _LOCK:
        return _load_state()


def read_volume_marker() -> str | None:
    with _LOCK:
        path = volume_dir() / "last_write.txt"
        if not path.exists():
            return None
        text = path.read_text(encoding="utf-8")
        METRICS.record_read(len(text.encode("utf-8")))
        return text.strip()


def seed_if_empty() -> dict[str, Any]:
    with _LOCK:
        state = _load_state()
        if int(state.get("counter", 0)) == 0:
            # release lock briefly for write_message which re-acquires
            pass
    if int(read_state().get("counter", 0)) == 0:
        write_message("Hello Persistent World")
        write_message("Day 2 bind-mount seed")
        METRICS.record_persist_survived(1)
        return read_state()
    METRICS.record_persist_survived(1)
    return read_state()
