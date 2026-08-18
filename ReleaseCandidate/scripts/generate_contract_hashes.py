#!/usr/bin/env python3
"""Generate or verify canonical SHA-256 values for the frozen contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


class HashError(RuntimeError):
    pass


def load_object(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise HashError(f"expected a regular contract file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise HashError(f"cannot read contract {path}: {error}") from error
    if not isinstance(value, dict):
        raise HashError(f"contract must be a JSON object: {path}")
    return value


def digest(value: object) -> str:
    canonical = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def manifest(contracts: Path) -> dict:
    public_name = "public-contract-freeze.json"
    intent_name = "app-intent-registry.json"
    return {
        "schemaVersion": 1,
        "algorithm": "SHA-256",
        "canonicalization": "UTF-8 JSON; sorted keys; no insignificant whitespace",
        "publicContract": public_name,
        "publicContractSHA256": digest(load_object(contracts / public_name)),
        "appIntentRegistry": intent_name,
        "appIntentRegistrySHA256": digest(load_object(contracts / intent_name)),
    }


def encoded(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contracts-dir", default="Contracts/v1")
    parser.add_argument("--output", default="Contracts/v1/hashes.json")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    contracts = Path(args.contracts_dir)
    output = Path(args.output)
    try:
        expected = encoded(manifest(contracts))
        if args.verify:
            if not output.is_file() or output.is_symlink():
                raise HashError(f"expected a regular hash manifest: {output}")
            if output.read_bytes() != expected:
                raise HashError(f"contract hash manifest drifted: {output}")
            print("Contract hash verification passed.")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(expected)
            print(output)
    except (HashError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
