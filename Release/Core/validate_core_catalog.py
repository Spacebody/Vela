#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    parse_time,
    read_regular_bytes,
    validate_catalog,
    validate_signature_envelope,
)


def load_public_keys(path: Path, production: bool) -> dict[str, tuple[str, datetime, datetime | None]]:
    value = json.loads(read_regular_bytes(path, maximum=64 * 1024))
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "keys"} or value.get("schemaVersion") != 1:
        raise CoreReleaseError("public keyring fields/schema are invalid")
    records = value.get("keys")
    if not isinstance(records, list) or not records:
        raise CoreReleaseError("public keyring must contain a non-empty keys array")
    result: dict[str, tuple[str, datetime, datetime | None]] = {}
    for item in records:
        if not isinstance(item, dict) or set(item) != {"keyID", "algorithm", "publicKeyBase64", "status", "notBefore", "notAfter"}:
            raise CoreReleaseError("public keyring item fields differ from schema")
        key_id = item["keyID"]
        if not isinstance(key_id, str) or key_id in result or item["algorithm"] != "ed25519":
            raise CoreReleaseError("public keyring key ID/algorithm is invalid")
        if item["status"] not in {"active", "next", "revoked"}:
            raise CoreReleaseError("public keyring status is invalid")
        try:
            raw = base64.b64decode(item["publicKeyBase64"], validate=True)
        except Exception as error:
            raise CoreReleaseError("public keyring contains invalid Base64") from error
        if len(raw) != 32:
            raise CoreReleaseError("Ed25519 public key must be 32 bytes")
        if production and "TEST" in key_id.upper():
            raise CoreReleaseError("test Core Catalog public key is forbidden in production")
        not_before = parse_time(item["notBefore"], f"key {key_id} notBefore")
        not_after = parse_time(item["notAfter"], f"key {key_id} notAfter") if item["notAfter"] is not None else None
        if not_after is not None and not_after <= not_before:
            raise CoreReleaseError("public keyring validity window is invalid")
        if item["status"] != "revoked":
            result[key_id] = (item["publicKeyBase64"], not_before, not_after)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate deterministic Core Catalog policy and raw Ed25519 signatures")
    parser.add_argument("catalog")
    parser.add_argument("--signatures")
    parser.add_argument("--public-keyring")
    parser.add_argument("--compatibility-report")
    parser.add_argument("--dedicated-host-evidence")
    parser.add_argument("--performance-review")
    parser.add_argument("--prior-catalog")
    parser.add_argument("--required-key-id", action="append", default=[])
    parser.add_argument("--require-exact-key-set", action="store_true")
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        catalog_path = Path(args.catalog)
        raw = read_regular_bytes(catalog_path, maximum=2 * 1024 * 1024)
        prior = read_regular_bytes(Path(args.prior_catalog), maximum=2 * 1024 * 1024) if args.prior_catalog else None
        if bool(args.signatures) != bool(args.public_keyring):
            raise CoreReleaseError("--signatures and --public-keyring must be supplied together")
        if args.production and not args.signatures:
            raise CoreReleaseError("production Core Catalog validation requires signatures and a production public keyring")
        valid_ids: list[str] = []
        envelope_ids: set[str] = set()
        required_ids = set(args.required_key_id)
        if len(required_ids) != len(args.required_key_id):
            raise CoreReleaseError("required Core Catalog key IDs must be unique")
        if args.require_exact_key_set and not required_ids:
            raise CoreReleaseError("exact Core Catalog key-set validation requires key IDs")
        if required_ids and not args.signatures:
            raise CoreReleaseError("required Core Catalog key IDs need a signature envelope")
        keys: dict[str, tuple[str, datetime, datetime | None]] = {}
        if args.signatures:
            # Verify the signature envelope and Ed25519 over the exact server bytes
            # before any Catalog JSON decoding or re-encoding.
            envelope_raw = read_regular_bytes(Path(args.signatures), maximum=64 * 1024)
            envelope = validate_signature_envelope(envelope_raw, raw, production=args.production)
            envelope_ids = {item["keyID"] for item in envelope["signatures"]}
            if args.require_exact_key_set and envelope_ids != required_ids:
                raise CoreReleaseError(
                    "Core Catalog signature envelope differs from the exact reviewed key set"
                )
            keys = load_public_keys(Path(args.public_keyring), args.production)
            helper = Path(__file__).with_name("catalog_crypto.swift")
            with tempfile.TemporaryDirectory(prefix="vela-core-swift-cache.") as crypto_cache:
                Path(crypto_cache).chmod(0o700)
                for signature in envelope["signatures"]:
                    key_id = signature["keyID"]
                    key_record = keys.get(key_id)
                    if key_record is None:
                        continue
                    public_key = key_record[0]
                    result = subprocess.run(
                        ["/usr/bin/swift", "-module-cache-path", crypto_cache, str(helper), "verify", str(catalog_path), public_key, signature["signature"]],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
                    if result.returncode == 0:
                        valid_ids.append(key_id)
            if not valid_ids:
                raise CoreReleaseError("Core Catalog has no valid non-revoked trusted Ed25519 signature")
            if not required_ids.issubset(valid_ids):
                raise CoreReleaseError(
                    "Core Catalog lacks a valid signature from every required key ID"
                )
        catalog = validate_catalog(
            raw,
            compatibility_report=Path(args.compatibility_report) if args.compatibility_report else None,
            dedicated_host_evidence=(
                Path(args.dedicated_host_evidence)
                if args.dedicated_host_evidence
                else None
            ),
            performance_review=(
                Path(args.performance_review) if args.performance_review else None
            ),
            prior_raw=prior,
            production=args.production,
        )
        if valid_ids:
            effective_time = parse_time(catalog["generatedAt"], "catalog generatedAt")
            valid_ids = [
                key_id for key_id in valid_ids
                if effective_time >= keys[key_id][1]
                and (keys[key_id][2] is None or effective_time <= keys[key_id][2])
            ]
            if not valid_ids:
                raise CoreReleaseError("Core Catalog signature key is outside its validity window")
        suffix = f" validKeys={','.join(valid_ids)}" if valid_ids else " policyOnly=true"
        print(f"Core Catalog validation passed: sequence={catalog['sequence']} entries={len(catalog['entries'])}{suffix}")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
