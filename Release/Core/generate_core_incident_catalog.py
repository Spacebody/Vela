#!/usr/bin/env python3
"""Generate a catalog-only incident update from immutable prior Catalog bytes."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_release_lib import (
    CORE_ID_PATTERN,
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    parse_time,
    read_regular_bytes,
    sha256_bytes,
    validate_catalog,
)
from generate_core_catalog import apply_status_transition, validate_incident_reason


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a catalog-only blocked/withdrawn incident sequence"
    )
    parser.add_argument("--prior-catalog", required=True)
    parser.add_argument("--core-id", required=True)
    parser.add_argument("--status", choices=("blocked", "withdrawn"), required=True)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--sequence", type=int, required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--expires-at", required=True)
    parser.add_argument("--key-set-version", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        if CORE_ID_PATTERN.fullmatch(args.core_id) is None:
            raise CoreReleaseError("incident Core ID is invalid")
        validate_incident_reason(args.reason, args.status)
        generated = parse_time(args.generated_at, "generatedAt")
        expires = parse_time(args.expires_at, "expiresAt")
        if expires <= generated:
            raise CoreReleaseError("incident Catalog expiry must follow generation")
        if args.key_set_version < 1:
            raise CoreReleaseError("incident Catalog key-set version must be positive")

        prior_raw = read_regular_bytes(Path(args.prior_catalog), maximum=2 * 1024 * 1024)
        prior = validate_catalog(prior_raw)
        if args.sequence != prior["sequence"] + 1:
            raise CoreReleaseError("incident Catalog sequence must exactly follow the prior sequence")

        target = next(
            (entry for entry in prior["entries"] if entry["coreID"] == args.core_id),
            None,
        )
        if target is None:
            raise CoreReleaseError("incident target is absent from the immutable prior Catalog")
        apply_status_transition(target, args.status, args.reason)
        catalog = {
            "schemaVersion": 1,
            "sequence": args.sequence,
            "generatedAt": args.generated_at,
            "expiresAt": args.expires_at,
            "catalogKeySetVersion": args.key_set_version,
            "entries": prior["entries"],
        }
        raw = canonical_json_bytes(catalog)
        validate_catalog(raw, prior_raw=prior_raw, production=args.production)
        atomic_write(Path(args.output), raw)
        print(
            "Generated catalog-only Core incident: "
            f"sequence={args.sequence} coreID={args.core_id} status={args.status} "
            f"sha256={sha256_bytes(raw)}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
