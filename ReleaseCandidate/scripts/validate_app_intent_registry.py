#!/usr/bin/env python3
"""Validate the App Intent registry and optionally compare it with its Golden."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


EXPECTED_KEYS = {
    "schemaVersion",
    "availability",
    "intents",
    "entities",
    "enums",
    "shortcuts",
}
PLACEHOLDERS = ("REPLACE_WITH", "__", "TODO", "TBD")


class RegistryError(ValueError):
    pass


def load(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise RegistryError(f"expected a regular registry file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RegistryError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise RegistryError("App Intent registry must be a JSON object")
    return value


def item_identifier(item: object, collection: str) -> str:
    if isinstance(item, str) and item:
        return item
    if isinstance(item, dict):
        for key in ("type", "identifier", "rawValue"):
            value = item.get(key)
            if isinstance(value, str) and value:
                return value
    raise RegistryError(f"{collection} contains an item without a stable identifier")


def validate(value: dict) -> None:
    if set(value) != EXPECTED_KEYS:
        raise RegistryError(
            "App Intent registry keys differ; "
            f"missing={sorted(EXPECTED_KEYS - set(value))}, "
            f"extra={sorted(set(value) - EXPECTED_KEYS)}"
        )
    if value.get("schemaVersion") != 1:
        raise RegistryError("App Intent registry schemaVersion must be 1")
    availability = value.get("availability")
    if availability not in {"absent", "available"}:
        raise RegistryError("App Intent availability must be absent or available")
    for name in ("intents", "entities", "enums", "shortcuts"):
        items = value.get(name)
        if not isinstance(items, list):
            raise RegistryError(f"{name} must be an array")
        identifiers = [item_identifier(item, name) for item in items]
        if len(identifiers) != len(set(identifiers)):
            raise RegistryError(f"duplicate stable identifiers in {name}")
    if availability == "absent":
        populated = [
            name
            for name in ("intents", "entities", "enums", "shortcuts")
            if value[name]
        ]
        if populated:
            raise RegistryError(
                "absent App Intent registry must have empty collections: "
                + ", ".join(populated)
            )
    elif not value["intents"]:
        raise RegistryError("available App Intent registry must contain an intent")
    serialized = json.dumps(value, ensure_ascii=False)
    if any(token in serialized for token in PLACEHOLDERS):
        raise RegistryError("App Intent registry contains a placeholder")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("golden")
    parser.add_argument("current", nargs="?")
    args = parser.parse_args()
    try:
        golden = load(Path(args.golden))
        validate(golden)
        if args.current:
            current = load(Path(args.current))
            validate(current)
            if golden != current:
                raise RegistryError("App Intent registry changed")
    except RegistryError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("App Intent registry validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
