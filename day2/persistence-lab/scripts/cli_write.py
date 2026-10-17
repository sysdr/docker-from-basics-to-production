#!/usr/bin/env python3
"""Simple CLI used by ephemeral-vs-persistent smoke checks."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow running as `python scripts/cli_write.py` from /app
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.app.store import write_message, read_state  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", type=str, help="Message to persist")
    parser.add_argument("--read", action="store_true", help="Print state counter")
    args = parser.parse_args()
    if args.write:
        entry = write_message(args.write)
        print(f"WROTE:{entry['n']}:{entry['message']}")
    if args.read:
        state = read_state()
        print(f"COUNTER:{state.get('counter', 0)}")


if __name__ == "__main__":
    main()
