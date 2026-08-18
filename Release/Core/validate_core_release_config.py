#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    load_json,
    production_https_url_issue,
    validate_compatibility,
    validate_https_url,
    validate_seed,
)
from core_catalog_distribution import load_catalog_distribution
from generate_embedded_core_trust_roots import (
    TrustRootGenerationError,
    load_manifest,
    render,
)


MARKETING_VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def parse_marketing_version(value: object, *, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise CoreReleaseError(f"{label} must be a major.minor.patch string")
    match = MARKETING_VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise CoreReleaseError(f"{label} must be canonical major.minor.patch")
    return tuple(int(component) for component in match.groups())


def app_meets_core_compatibility_floor(current: object, floor: object) -> bool:
    return parse_marketing_version(
        current,
        label="main App release version",
    ) >= parse_marketing_version(
        floor,
        label="Core compatibility floor",
    )


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    default_config = Path(__file__).with_name("config") / "core-release.json"
    parser = argparse.ArgumentParser(description="Validate Vela 0.6 Core release configuration")
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--config", default=str(default_config))
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    blockers: list[str] = []
    try:
        root = Path(args.repository_root).resolve(strict=True)
        config = load_json(Path(args.config), maximum=256 * 1024)
        if set(config) != {"schemaVersion", "product", "core", "catalog", "signing", "paths", "stopShipReason"} or config["schemaVersion"] != 1:
            raise CoreReleaseError("Core release configuration fields/schema are invalid")
        product = config["product"]
        if product != {
            "velaVersion": "0.6.0",
            "velaBuild": 2026071302,
            "bundleIdentifier": "dev.yilin.Vela.MihomoCore",
            "teamIdentifier": "2E56T94S33",
            "minimumMacOS": "15.0",
            "architecture": "arm64",
        }:
            raise CoreReleaseError("Core release product contract must target Vela 0.6.0 build 2026071302 arm64/macOS 15")
        catalog = config["catalog"]
        expected_catalog_fields = {
            "operation",
            "baseURL",
            "catalogURL",
            "catalogSignaturesURL",
            "releaseNotesURL",
            "sequence",
            "priorCatalogSequence",
            "priorCatalogURL",
            "priorCatalogSHA256",
            "status",
            "blockReason",
            "statusTransitions",
            "generatedAt",
            "expiresAt",
            "publishedAt",
            "keySetVersion",
            "keyID",
            "rotationKeyID",
            "publicKeyring",
        }
        if not isinstance(catalog, dict) or set(catalog) != expected_catalog_fields:
            raise CoreReleaseError("Core Catalog release fields differ from the fixed schema")
        operation = catalog.get("operation")
        if operation not in {"full", "incident"}:
            raise CoreReleaseError("Core Catalog operation must be full or incident")
        core = config["core"]
        if set(core) != {
            "coreID",
            "upstreamVersion",
            "packageRevision",
            "seed",
            "compatibilityReport",
            "dedicatedHostEvidence",
            "performanceReview",
            "license",
        }:
            raise CoreReleaseError("Core release fields differ from the fixed schema")
        if core["coreID"] != "v1.19.28-r1" or core["upstreamVersion"] != "v1.19.28" or core["packageRevision"] != 1:
            raise CoreReleaseError("Core release must use the reviewed v1.19.28-r1 seed")
        seed_path = root / core["seed"]
        validate_seed(load_json(seed_path, maximum=64 * 1024))
        license_path = root / core["license"]
        if not license_path.is_file() or license_path.is_symlink():
            raise CoreReleaseError("Core GPL license material is missing or unsafe")
        evidence_paths: dict[str, Path | None] = {}
        for field, label in (
            ("dedicatedHostEvidence", "dedicated-host compatibility evidence"),
            ("performanceReview", "performance review evidence"),
        ):
            configured = core.get(field)
            if configured is None:
                if operation == "full":
                    blockers.append(f"reviewed {label} is not configured")
                evidence_paths[field] = None
            else:
                path = root / configured
                if not path.is_file() or path.is_symlink():
                    raise CoreReleaseError(f"configured {label} is missing or unsafe")
                evidence_paths[field] = path
        report = core.get("compatibilityReport")
        if report is None:
            if operation == "full":
                blockers.append("reviewed passed compatibility report is not configured")
        else:
            report_path = root / report
            if not report_path.is_file() or report_path.is_symlink():
                raise CoreReleaseError("configured compatibility report is missing or unsafe")
            compatibility_report = validate_compatibility(
                load_json(report_path, maximum=2 * 1024 * 1024),
                expected_core_id=core["coreID"],
                production=(
                    args.production
                    and evidence_paths["dedicatedHostEvidence"] is not None
                    and evidence_paths["performanceReview"] is not None
                ),
                dedicated_host_evidence=evidence_paths["dedicatedHostEvidence"],
                performance_review=evidence_paths["performanceReview"],
            )
            if compatibility_report["result"] != "passed":
                raise CoreReleaseError("configured compatibility report did not pass")
        if catalog.get("status") not in {"available", "recommended", "blocked", "withdrawn"}:
            raise CoreReleaseError("configured Catalog status is invalid")
        if operation == "incident" and catalog["status"] not in {"blocked", "withdrawn"}:
            raise CoreReleaseError("catalog-only incident operation must be blocked or withdrawn")
        block_reason = catalog.get("blockReason")
        if catalog["status"] in {"blocked", "withdrawn"}:
            if (
                not isinstance(block_reason, str)
                or not block_reason.strip()
                or len(block_reason) > 1024
            ):
                raise CoreReleaseError(
                    "blocked/withdrawn configured Core status requires a bounded reason"
                )
        elif block_reason is not None:
            raise CoreReleaseError(
                "available/recommended configured Core status must not have a reason"
            )
        transitions = catalog.get("statusTransitions")
        if not isinstance(transitions, list) or len(transitions) > 100:
            raise CoreReleaseError("Catalog status transitions must be a bounded array")
        if operation == "incident" and transitions:
            raise CoreReleaseError(
                "catalog-only incident operation targets the configured Core directly and forbids statusTransitions"
            )
        transition_ids: set[str] = set()
        for transition in transitions:
            if not isinstance(transition, dict) or set(transition) != {
                "coreID", "status", "blockReason",
            }:
                raise CoreReleaseError("Catalog status transition fields are invalid")
            transition_id = transition["coreID"]
            transition_status = transition["status"]
            transition_reason = transition["blockReason"]
            if (
                not isinstance(transition_id, str)
                or transition_id in transition_ids
                or transition_id == core["coreID"]
            ):
                raise CoreReleaseError(
                    "Catalog status transitions must uniquely target prior Core IDs"
                )
            transition_ids.add(transition_id)
            if transition_status not in {"available", "recommended", "blocked", "withdrawn"}:
                raise CoreReleaseError("Catalog status transition has an invalid status")
            if transition_status in {"blocked", "withdrawn"}:
                if (
                    not isinstance(transition_reason, str)
                    or not transition_reason.strip()
                    or len(transition_reason) > 1024
                ):
                    raise CoreReleaseError(
                        "terminal Catalog status transition requires a bounded reason"
                    )
            elif transition_reason is not None:
                raise CoreReleaseError(
                    "non-terminal Catalog status transition must not have a reason"
                )
        _, distribution_blockers = load_catalog_distribution(
            Path(args.config),
            production=False,
        )
        blockers.extend(distribution_blockers)
        release_notes_url = catalog.get("releaseNotesURL")
        if release_notes_url is None:
            if operation == "full":
                blockers.append("production Catalog releaseNotesURL is not configured")
        else:
            release_notes_url = validate_https_url(
                release_notes_url,
                "Catalog releaseNotesURL",
            )
            if issue := production_https_url_issue(release_notes_url):
                blockers.append(
                    "production Catalog releaseNotesURL is not a public endpoint "
                    f"({issue})"
                )
        required_catalog_fields = [
            "sequence", "generatedAt", "expiresAt", "keyID", "publicKeyring",
        ]
        if operation == "full":
            required_catalog_fields.append("publishedAt")
        for field in required_catalog_fields:
            if catalog.get(field) is None:
                blockers.append(f"production Catalog {field} is not configured")
        try:
            embedded_manifest = load_manifest(
                root / "Release/Core/config/embedded-core-keyring.json"
            )
        except TrustRootGenerationError as error:
            raise CoreReleaseError(str(error)) from error
        generated_roots = root / "VelaIPC/CoreCatalogTrust.swift"
        if generated_roots.is_symlink() or not generated_roots.is_file():
            raise CoreReleaseError("generated embedded Core trust-root source is missing or unsafe")
        if generated_roots.read_text(encoding="utf-8") != render(embedded_manifest):
            raise CoreReleaseError(
                "App/Helper embedded Core trust roots differ from the canonical release manifest"
            )
        if catalog.get("keySetVersion") != embedded_manifest["keySetVersion"]:
            raise CoreReleaseError(
                "Catalog key-set version differs from App/Helper embedded trust roots"
            )
        embedded_keys = embedded_manifest["keys"]
        if not embedded_keys:
            blockers.append("embedded production Core trust roots are not provisioned")
        if isinstance(catalog.get("keyID"), str) and "TEST" in catalog["keyID"].upper():
            raise CoreReleaseError("test Core Catalog key ID is forbidden in release configuration")
        rotation_key_id = catalog.get("rotationKeyID")
        if rotation_key_id is not None:
            if (
                not isinstance(rotation_key_id, str)
                or not rotation_key_id
                or len(rotation_key_id) > 128
                or "TEST" in rotation_key_id.upper()
            ):
                raise CoreReleaseError("Core Catalog rotation key ID is invalid")
            if rotation_key_id == catalog.get("keyID"):
                raise CoreReleaseError("Core Catalog rotation key must differ from the primary key")
        public_keyring = catalog.get("publicKeyring")
        if isinstance(public_keyring, str):
            keyring_path = root / public_keyring
            if not keyring_path.is_file() or keyring_path.is_symlink():
                raise CoreReleaseError("production Core public keyring is missing or unsafe")
            public_keys = load_json(keyring_path, maximum=64 * 1024)
            if public_keys != {
                "schemaVersion": 1,
                "keys": embedded_keys,
            }:
                raise CoreReleaseError(
                    "production Core public keyring differs from App/Helper embedded trust roots"
                )
            accepted_key_ids = {
                item["keyID"]
                for item in embedded_keys
                if item["status"] in {"active", "next"}
            }
            if catalog.get("keyID") not in accepted_key_ids:
                raise CoreReleaseError(
                    "Catalog signing key is not active/next in embedded App/Helper roots"
                )
            if rotation_key_id is not None:
                statuses = {
                    item["keyID"]: item["status"]
                    for item in embedded_keys
                }
                if rotation_key_id not in accepted_key_ids:
                    raise CoreReleaseError(
                        "Catalog rotation key is not active/next in embedded App/Helper roots"
                    )
                if {
                    statuses[catalog["keyID"]],
                    statuses[rotation_key_id],
                } != {"active", "next"}:
                    raise CoreReleaseError(
                        "Catalog dual-sign rotation must pair one active and one next key"
                    )
        signing = config["signing"]
        if signing.get("developerIDIdentity") is None:
            if operation == "full":
                blockers.append("Developer ID Application identity is not configured")
        elif not str(signing["developerIDIdentity"]).startswith("Developer ID Application:"):
            raise CoreReleaseError("Core signing identity must be Developer ID Application")
        if set(signing) != {"developerIDIdentity", "notaryProfilePrefix"}:
            raise CoreReleaseError("Core signing fields differ from the fixed schema")
        notary_profile_prefix = signing.get("notaryProfilePrefix")
        if notary_profile_prefix is None:
            if operation == "full":
                blockers.append("protected per-run notary profile prefix is not configured")
        elif re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?",
            str(notary_profile_prefix),
        ) is None:
            raise CoreReleaseError("notary profile prefix contains unsafe characters")
        main_release = load_json(root / "Release/config/release.json", maximum=256 * 1024)
        main_versioning = main_release.get("versioning")
        if not isinstance(main_versioning, dict):
            raise CoreReleaseError("main App release versioning configuration is invalid")
        main_app_version = main_versioning.get("marketingVersion")
        core_compatibility_floor = product["velaVersion"]
        if not app_meets_core_compatibility_floor(
            main_app_version,
            core_compatibility_floor,
        ):
            blockers.append(
                f"main App release version {main_app_version!r} is below Core "
                f"compatibility floor {core_compatibility_floor}"
            )
        compatibility = load_json(root / "Release/config/compatibility.json", maximum=256 * 1024)
        helper_protocol = compatibility.get("helperProtocol", {})
        if helper_protocol.get("minimum") != 2 or helper_protocol.get("maximum") != 2:
            blockers.append("main release compatibility does not yet declare Helper protocol 2")
        if args.production and blockers:
            raise CoreReleaseError("production Core release is blocked: " + "; ".join(blockers))
        print("Vela 0.6 Core release configuration structure passed.")
        if blockers:
            print(f"Production Core release remains fail-closed with {len(blockers)} blocker(s):")
            for blocker in blockers:
                print(f"- {blocker}")
        else:
            print("Production Core release configuration has no static blockers.")
        return 0
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        CoreReleaseError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
