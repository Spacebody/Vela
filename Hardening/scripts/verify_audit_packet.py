#!/usr/bin/env python3
"""Verify every payload file against an Audit Packet inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def digest(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"not a regular file: {path}")
        value = hashlib.sha256()
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(chunk)
        return value.hexdigest()
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("packet")
    args = parser.parse_args()
    root = Path(args.packet).resolve()
    try:
        inventory_path = root / "packet-inventory.json"
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        expected = {item["path"]: item for item in inventory["entries"]}
        if inventory.get("schemaVersion") != 1 or inventory.get("entryCount") != len(expected):
            raise ValueError("invalid or duplicate inventory entries")
        actual: set[str] = set()
        for path in root.rglob("*"):
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or (not stat.S_ISDIR(info.st_mode) and not stat.S_ISREG(info.st_mode)):
                raise ValueError(f"unsafe packet entry: {path}")
            if stat.S_ISREG(info.st_mode) and path != inventory_path:
                relative = str(path.relative_to(root))
                actual.add(relative)
                item = expected.get(relative)
                if item is None or item["size"] != info.st_size or item["sha256"] != digest(path):
                    raise ValueError(f"packet entry mismatch: {relative}")
        if actual != set(expected):
            raise ValueError("packet file set does not match inventory")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Audit Packet verified: {len(expected)} payload files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
