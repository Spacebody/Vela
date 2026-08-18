#!/usr/bin/env python3
"""Stage immutable raw Catalog history needed by the next release sequence."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    atomic_write,
    read_regular_bytes,
    validate_catalog,
    validate_signature_envelope,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stage an immutable sequence-addressed Core Catalog history record"
    )
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--signatures", required=True)
    parser.add_argument("--public-directory", required=True)
    parser.add_argument("--sequence", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.sequence < 1:
            raise CoreReleaseError("Catalog history sequence must be positive")
        catalog_raw = read_regular_bytes(Path(args.catalog), maximum=2 * 1024 * 1024)
        catalog = validate_catalog(catalog_raw)
        if catalog["sequence"] != args.sequence:
            raise CoreReleaseError("Catalog history sequence differs from raw Catalog bytes")
        signatures_raw = read_regular_bytes(Path(args.signatures), maximum=64 * 1024)
        validate_signature_envelope(signatures_raw, catalog_raw, production=True)

        public_input = Path(args.public_directory)
        if not public_input.is_dir() or public_input.is_symlink():
            raise CoreReleaseError("public staging directory is missing or unsafe")
        public = public_input.resolve(strict=True)
        history_root = public / "catalog-history"
        if history_root.exists() or history_root.is_symlink():
            if not history_root.is_dir() or history_root.is_symlink():
                raise CoreReleaseError("Catalog history root is unsafe")
        else:
            history_root.mkdir(mode=0o755)
        target = history_root / f"sequence-{args.sequence}"
        try:
            target.mkdir(mode=0o755)
        except FileExistsError as error:
            raise CoreReleaseError(
                f"refusing to overwrite immutable Catalog history sequence {args.sequence}"
            ) from error
        atomic_write(target / "core-catalog.json", catalog_raw, mode=0o644)
        atomic_write(
            target / "core-catalog.signatures.json",
            signatures_raw,
            mode=0o644,
        )
        directory = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        print(
            "Staged immutable Core Catalog history: "
            f"sequence={args.sequence} directory={target}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
