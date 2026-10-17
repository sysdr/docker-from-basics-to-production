from __future__ import annotations

import os
from pathlib import Path

import pytest

from src.app import store


@pytest.fixture()
def tmp_data(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    data = tmp_path / "data"
    vol = tmp_path / "volume"
    data.mkdir()
    vol.mkdir()
    monkeypatch.setenv("PERSIST_DATA_DIR", str(data))
    monkeypatch.setenv("PERSIST_VOLUME_DIR", str(vol))
    return data, vol


def test_write_and_read_persists(tmp_data):
    data, vol = tmp_data
    entry = store.write_message("hello")
    assert entry["n"] == 1
    state = store.read_state()
    assert state["counter"] == 1
    assert (data / "state.json").exists()
    assert (vol / "last_write.txt").exists()
    assert "Hello" not in store.read_volume_marker()  # marker is counter:ts
    assert store.read_volume_marker().startswith("1:")


def test_counter_increments(tmp_data):
    store.write_message("a")
    store.write_message("b")
    assert store.read_state()["counter"] == 2
