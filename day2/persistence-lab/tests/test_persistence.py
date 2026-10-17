from __future__ import annotations

from pathlib import Path

import pytest

from src.persistence.volumes import path_facts, collect_persistence_facts


def test_path_facts_empty(tmp_path: Path):
    facts = path_facts(str(tmp_path))
    assert facts["exists"] is True
    assert facts["total_bytes"] == 0


def test_path_facts_with_file(tmp_path: Path):
    f = tmp_path / "state.txt"
    f.write_text("Hello Persistent World", encoding="utf-8")
    facts = path_facts(str(tmp_path))
    assert facts["total_bytes"] > 0
    assert any(x["name"] == "state.txt" for x in facts["files"])


def test_collect_persistence_facts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setenv("PERSIST_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PERSIST_VOLUME_DIR", str(tmp_path / "vol"))
    (tmp_path / "data").mkdir()
    (tmp_path / "vol").mkdir()
    facts = collect_persistence_facts()
    assert "data_dir" in facts
    assert facts["data_dir"]["exists"] is True
