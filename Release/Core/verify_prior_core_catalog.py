#!/usr/bin/env python3
"""Bind a prior Catalog file to the reviewed URL/SHA/sequence release config."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_catalog_distribution import load_catalog_distribution
from core_release_lib import (
    CoreReleaseError,
    read_regular_bytes,
    sha256_bytes,
    validate_catalog,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify immutable prior Core Catalog provenance and bytes"
    )
    parser.add_argument("catalog")
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name("config") / "core-release.json"),
    )
    args = parser.parse_args()
    try:
        distribution, _ = load_catalog_distribution(
            Path(args.config),
            production=True,
        )
        sequence = distribution["sequence"]
        if sequence <= 1:
            raise CoreReleaseError("current Catalog sequence does not require a prior Catalog")
        raw = read_regular_bytes(Path(args.catalog), maximum=2 * 1024 * 1024)
        actual_sha = sha256_bytes(raw)
        if actual_sha != distribution["priorCatalogSHA256"]:
            raise CoreReleaseError(
                "prior Core Catalog bytes differ from the reviewed expected SHA-256"
            )
        prior = validate_catalog(raw)
        expected_sequence = distribution["priorCatalogSequence"]
        if prior["sequence"] != expected_sequence:
            raise CoreReleaseError(
                f"prior Core Catalog sequence must be exactly {expected_sequence}"
            )
        print(
            "Immutable prior Core Catalog verified: "
            f"sequence={expected_sequence} sha256={actual_sha}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
