#!/usr/bin/env python3
"""Generate or verify the App's V1 release-candidate resources from frozen sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

from _common import GateError, load_json, main_error, validate_schema


def regular(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"{label} must be a regular non-symlink file: {path}")
    return path


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return sha256_bytes(encoded)


def encoded_json(value: dict) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def component(architecture: dict, name: str) -> dict:
    matches = [item for item in architecture["bundledComponents"] if item.get("name") == name]
    if len(matches) != 1:
        raise GateError(f"architecture must contain exactly one {name} component")
    return matches[0]


def expected(root: Path) -> tuple[dict, bytes, bytes]:
    contract_path = regular(
        root / "Contracts/v1/public-contract-freeze.json", "public contract"
    )
    hashes = load_json(root / "Contracts/v1/hashes.json", label="contract hashes")
    architecture_path = regular(
        root / "Hardening/config/architecture-freeze.json", "architecture freeze"
    )
    architecture = load_json(architecture_path, label="architecture freeze")
    limitations_path = regular(
        root / "ReleaseCandidate/config/known-limitations.json", "known limitations"
    )
    limitations = load_json(limitations_path, label="known limitations")
    validate_schema(limitations, "known-limitations.schema.json")

    contract_bytes = contract_path.read_bytes()
    contract = load_json(contract_path, label="public contract")
    canonical_contract_sha = canonical_sha256(contract)
    if hashes.get("publicContract") != contract_path.name:
        raise GateError("contract hash manifest names a different public contract")
    if hashes.get("publicContractSHA256") != canonical_contract_sha:
        raise GateError("contract hash manifest differs from canonical public-contract bytes")

    product = architecture["product"]
    helper = architecture["protocols"]["helper"]
    automation = architecture["protocols"]["automation"]
    marketing_version = product["marketingVersion"]
    if limitations["version"] != marketing_version:
        raise GateError("known-limitations version differs from the architecture product")
    mihomo = component(architecture, "mihomo")
    sparkle = component(architecture, "Sparkle")
    baseline = {
        "schemaVersion": 1,
        "marketingVersion": marketing_version,
        "platform": {
            "minimumMacOS": product["minimumMacOS"],
            "architectures": product["architectures"],
        },
        "components": {
            "mihomo": mihomo["version"],
            "sparkle": sparkle["version"],
        },
        "publicContractSHA256": canonical_contract_sha,
        "publicContractFileSHA256": sha256_bytes(contract_bytes),
        "architectureFreezeSHA256": sha256_bytes(architecture_path.read_bytes()),
        "dataSchemaVersion": architecture["schemas"]["rootData"],
        "helperProtocol": {
            "minimum": helper["minimum"],
            "maximum": helper["maximum"],
        },
        "automationProtocol": (
            None
            if automation is None
            else {"minimum": automation["minimum"], "maximum": automation["maximum"]}
        ),
        "publicContractResource": "public-contract-freeze.json",
        "knownLimitationsResource": "known-limitations.json",
    }
    return baseline, contract_bytes, limitations_path.read_bytes()


def replace(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise GateError(f"refusing unsafe App resource path: {path}")
    descriptor, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(raw)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        root = Path(args.repository_root).resolve()
        baseline, contract, limitations = expected(root)
        resources = root / "Vela/Resources/ReleaseCandidate"
        expected_files = {
            resources / "baseline.json": encoded_json(baseline),
            resources / "public-contract-freeze.json": contract,
            resources / "known-limitations.json": limitations,
        }
        if args.write:
            for path, value in expected_files.items():
                replace(path, value)
            print("Generated deterministic V1 App release-candidate resources.")
            return 0
        for path, value in expected_files.items():
            regular(path, "bundled release-candidate resource")
            if path.read_bytes() != value:
                raise GateError(f"bundled release-candidate resource drifted: {path}")
        print("V1 App release-candidate resources match frozen source bytes.")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
