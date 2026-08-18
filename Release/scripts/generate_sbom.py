#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


class SBOMError(ValueError):
    pass


def load_json(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise SBOMError(f"expected a regular JSON file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SBOMError(f"expected a JSON object: {path}")
    return value


def sha256(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise SBOMError(f"expected a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolved_pins(document: dict) -> dict[str, dict]:
    pins = document.get("pins")
    if not isinstance(pins, list):
        raise SBOMError("Package.resolved pins must be an array")
    result: dict[str, dict] = {}
    for pin in pins:
        if not isinstance(pin, dict):
            raise SBOMError("Package.resolved pin must be an object")
        identity = str(pin.get("identity", "")).lower()
        if not identity or identity in result:
            raise SBOMError(f"invalid or duplicate Package.resolved identity: {identity}")
        result[identity] = pin
    return result


def spdx_id(name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    return f"SPDXRef-Package-{normalized}"


def write_immutable(path: Path, value: dict) -> None:
    if path.exists() or path.is_symlink():
        raise SBOMError(f"refusing to overwrite immutable SBOM: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise SBOMError(f"SBOM appeared concurrently; refusing overwrite: {path}") from error
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Generate Vela SPDX 2.3 JSON SBOM")
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--config", default="Release/config/release.json")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--allow-unresolved", action="store_true")
    args = parser.parse_args()

    try:
        root = Path(args.repository_root).resolve()
        config_path = Path(args.config)
        if not config_path.is_absolute():
            config_path = root / config_path
        config = load_json(config_path)
        product = config["product"]
        if args.version != config["versioning"]["marketingVersion"]:
            raise SBOMError("SBOM version differs from release config")
        if re.fullmatch(r"[1-9][0-9]*", args.build) is None:
            raise SBOMError("SBOM build must be a positive integer")

        package_resolved_path = root / config["paths"]["packageResolved"]
        pins = resolved_pins(load_json(package_resolved_path))
        third_party = load_json(root / config["paths"]["thirdPartyComponents"])
        components = third_party.get("components")
        if not isinstance(components, list) or not components:
            raise SBOMError("third-party components are missing")

        commit = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
        namespace_uuid = uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"vela:{args.version}:{args.build}:{commit}:{sha256(package_resolved_path)}",
        )
        document_id = "SPDXRef-DOCUMENT"
        app_id = spdx_id("Vela")
        packages: list[dict] = [
            {
                "SPDXID": app_id,
                "name": "Vela",
                "versionInfo": args.version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "supplier": "Organization: Vela",
            }
        ]
        relationships = [
            {
                "spdxElementId": document_id,
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": app_id,
            }
        ]

        for entry in components:
            if not isinstance(entry, dict):
                raise SBOMError("third-party component entry must be an object")
            name = entry.get("name")
            version = entry.get("version")
            license_declared = entry.get("licenseDeclared")
            download = entry.get("downloadLocation")
            if not all(isinstance(value, str) and value for value in [name, version, license_declared, download]):
                raise SBOMError("third-party component has incomplete metadata")
            if license_declared == "NOASSERTION" and not args.allow_unresolved:
                raise SBOMError(f"{name} has an unresolved license")
            license_path = root / entry["licenseFile"]
            package: dict = {
                "SPDXID": spdx_id(name),
                "name": name,
                "versionInfo": version,
                "downloadLocation": download,
                "filesAnalyzed": False,
                "licenseConcluded": license_declared,
                "licenseDeclared": license_declared,
                "copyrightText": "See packaged upstream license",
                "sourceInfo": f"License SHA-256: {sha256(license_path)}",
            }
            identity = entry.get("packageIdentity")
            if isinstance(identity, str):
                pin = pins.get(identity.lower())
                if pin is None:
                    if not args.allow_unresolved:
                        raise SBOMError(f"Package.resolved is missing {identity}")
                    package["sourceInfo"] += "; Package.resolved pin unavailable"
                else:
                    state = pin.get("state")
                    if not isinstance(state, dict) or state.get("version") != version:
                        if not args.allow_unresolved:
                            raise SBOMError(f"Package.resolved does not pin {identity} {version}")
                        package["sourceInfo"] += "; Package.resolved version mismatch"
                    revision = state.get("revision") if isinstance(state, dict) else None
                    if isinstance(revision, str) and revision:
                        package["sourceInfo"] += f"; resolved revision {revision}"
            manifest_raw = entry.get("manifest")
            if isinstance(manifest_raw, str):
                manifest = load_json(root / manifest_raw)
                archive_hash = manifest.get("archiveSHA256")
                if isinstance(archive_hash, str) and re.fullmatch(r"[0-9a-f]{64}", archive_hash):
                    package["checksums"] = [{"algorithm": "SHA256", "checksumValue": archive_hash}]
            packages.append(package)
            relationships.append(
                {
                    "spdxElementId": app_id,
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": package["SPDXID"],
                }
            )

        sbom = {
            "spdxVersion": "SPDX-2.3",
            "dataLicense": "CC0-1.0",
            "SPDXID": document_id,
            "name": f"Vela-{args.version}-{args.build}",
            "documentNamespace": f"urn:uuid:{namespace_uuid}",
            "creationInfo": {
                "created": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "creators": ["Tool: Vela Release Engineering V0.5"],
            },
            "packages": packages,
            "relationships": relationships,
        }
        serialized = json.dumps(sbom, sort_keys=True)
        if re.search(r"/Users/|PRIVATE KEY|Authorization:", serialized, re.IGNORECASE):
            raise SBOMError("SBOM contains forbidden machine-local or secret material")
        output = Path(args.output)
        write_immutable(output, sbom)
        print(f"Generated SPDX 2.3 SBOM: {output} ({len(packages)} packages)")
        return 0
    except (
        OSError,
        KeyError,
        UnicodeError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        SBOMError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
