#!/usr/bin/env python3
"""Validate the fixed Core Catalog distribution contract used by App and CI."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from core_release_lib import (
    CoreReleaseError,
    SHA256_PATTERN,
    load_json,
    production_https_url_issue,
    validate_https_url,
)


CATALOG_URL_KEY = "VelaCoreCatalogURL"
SIGNATURES_URL_KEY = "VelaCoreCatalogSignaturesURL"


def _fixed_https_url(value: Any, label: str) -> str:
    url = validate_https_url(value, label)
    parsed = urlparse(url)
    try:
        port = parsed.port
    except ValueError as error:
        raise CoreReleaseError(f"{label} has an invalid port") from error
    if parsed.query or parsed.params:
        raise CoreReleaseError(f"{label} must not contain query parameters")
    if port not in {None, 443}:
        raise CoreReleaseError(f"{label} must use the default HTTPS port")
    if parsed.path.endswith("/"):
        raise CoreReleaseError(f"{label} must not end with a slash")
    return url


def load_catalog_distribution(
    config_path: Path,
    *,
    production: bool,
) -> tuple[dict[str, Any], list[str]]:
    config = load_json(config_path, maximum=256 * 1024)
    catalog = config.get("catalog")
    if not isinstance(catalog, dict):
        raise CoreReleaseError("Core release config catalog must be an object")

    blockers: list[str] = []
    result: dict[str, Any] = {}
    for field, label in [
        ("baseURL", "Core distribution base URL"),
        ("catalogURL", "Core Catalog URL"),
        ("catalogSignaturesURL", "Core Catalog signatures URL"),
    ]:
        value = catalog.get(field)
        if value is None or value == "":
            blockers.append(f"production {label} is not configured")
            result[field] = None
            continue
        url = _fixed_https_url(value, label)
        if issue := production_https_url_issue(url):
            blockers.append(
                f"production {label} is not a public endpoint ({issue})"
            )
        result[field] = url

    base_url = result.get("baseURL")
    catalog_url = result.get("catalogURL")
    signatures_url = result.get("catalogSignaturesURL")
    if base_url is not None and catalog_url is not None:
        expected = f"{base_url}/core-catalog.json"
        if catalog_url != expected:
            raise CoreReleaseError(f"Core Catalog URL must be exactly {expected}")
    if base_url is not None and signatures_url is not None:
        expected = f"{base_url}/core-catalog.signatures.json"
        if signatures_url != expected:
            raise CoreReleaseError(f"Core Catalog signatures URL must be exactly {expected}")

    sequence = catalog.get("sequence")
    if sequence is not None and (
        not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 1
    ):
        raise CoreReleaseError("Core Catalog sequence must be a positive integer")
    result["sequence"] = sequence

    prior_url_value = catalog.get("priorCatalogURL")
    prior_sha_value = catalog.get("priorCatalogSHA256")
    prior_sequence_value = catalog.get("priorCatalogSequence")
    if sequence is None:
        if (
            prior_sequence_value is not None
            or prior_url_value is not None
            or prior_sha_value is not None
        ):
            raise CoreReleaseError(
                "prior Catalog provenance may not be configured before Catalog sequence"
            )
        result["priorCatalogSequence"] = None
        result["priorCatalogURL"] = None
        result["priorCatalogSHA256"] = None
    elif sequence == 1:
        if (
            prior_sequence_value is not None
            or prior_url_value is not None
            or prior_sha_value is not None
        ):
            raise CoreReleaseError("Catalog sequence 1 must not configure a prior Catalog")
        result["priorCatalogSequence"] = None
        result["priorCatalogURL"] = None
        result["priorCatalogSHA256"] = None
    else:
        if prior_sequence_value is None:
            blockers.append("production immutable prior Core Catalog sequence is not configured")
            prior_sequence = None
        elif (
            not isinstance(prior_sequence_value, int)
            or isinstance(prior_sequence_value, bool)
            or prior_sequence_value < 1
            or prior_sequence_value >= sequence
        ):
            raise CoreReleaseError(
                "immutable prior Core Catalog sequence must be positive and lower than the new sequence"
            )
        else:
            prior_sequence = prior_sequence_value
        if prior_url_value is None or prior_url_value == "":
            blockers.append("production immutable prior Core Catalog URL is not configured")
            prior_url = None
        else:
            prior_url = _fixed_https_url(
                prior_url_value,
                "immutable prior Core Catalog URL",
            )
            if issue := production_https_url_issue(prior_url):
                blockers.append(
                    "production immutable prior Core Catalog URL is not a public endpoint "
                    f"({issue})"
                )
        if prior_sha_value is None or prior_sha_value == "":
            blockers.append("production immutable prior Core Catalog SHA-256 is not configured")
            prior_sha = None
        elif not isinstance(prior_sha_value, str) or SHA256_PATTERN.fullmatch(
            prior_sha_value
        ) is None:
            raise CoreReleaseError(
                "immutable prior Core Catalog SHA-256 must be lowercase SHA-256"
            )
        else:
            prior_sha = prior_sha_value
        if base_url is not None and prior_url is not None and prior_sequence is not None:
            expected = (
                f"{base_url}/catalog-history/sequence-{prior_sequence}/core-catalog.json"
            )
            if prior_url != expected:
                raise CoreReleaseError(
                    f"immutable prior Core Catalog URL must be exactly {expected}"
                )
        result["priorCatalogSequence"] = prior_sequence
        result["priorCatalogURL"] = prior_url
        result["priorCatalogSHA256"] = prior_sha

    if production and blockers:
        raise CoreReleaseError(
            "production Core Catalog distribution is blocked: " + "; ".join(blockers)
        )
    return result, blockers


def validate_bundled_info(
    info_path: Path,
    distribution: dict[str, Any],
    *,
    production: bool,
) -> None:
    if not info_path.is_file() or info_path.is_symlink():
        raise CoreReleaseError("App Info.plist is missing or unsafe")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if not isinstance(info, dict):
        raise CoreReleaseError("App Info.plist root must be a dictionary")
    for key, field, label in [
        (CATALOG_URL_KEY, "catalogURL", "Core Catalog URL"),
        (SIGNATURES_URL_KEY, "catalogSignaturesURL", "Core Catalog signatures URL"),
    ]:
        actual = info.get(key)
        expected = distribution.get(field)
        if not production and actual in {None, ""}:
            continue
        if expected is None:
            if actual not in {None, ""}:
                raise CoreReleaseError(
                    f"bundled {label} must remain empty while distribution is unconfigured"
                )
            if production:
                raise CoreReleaseError(f"production App is missing bundled {label}")
        elif actual != expected:
            raise CoreReleaseError(
                f"bundled {label} differs from the reviewed Core release configuration"
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate fixed Vela Core Catalog endpoints and prior-Catalog provenance"
    )
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name("config") / "core-release.json"),
    )
    parser.add_argument("--info-plist")
    parser.add_argument("--production", action="store_true")
    parser.add_argument(
        "--emit",
        choices=[
            "baseURL",
            "catalogURL",
            "catalogSignaturesURL",
            "sequence",
            "priorCatalogSequence",
            "priorCatalogURL",
            "priorCatalogSHA256",
        ],
    )
    args = parser.parse_args()
    try:
        distribution, blockers = load_catalog_distribution(
            Path(args.config),
            production=args.production,
        )
        if args.info_plist:
            validate_bundled_info(
                Path(args.info_plist),
                distribution,
                production=args.production,
            )
        if args.emit:
            value = distribution.get(args.emit)
            if value is None:
                raise CoreReleaseError(
                    f"Core Catalog distribution value is unconfigured: {args.emit}"
                )
            print(value)
        else:
            print("Core Catalog distribution structure passed.")
            if blockers:
                print(
                    f"Production Core Catalog distribution remains fail-closed with {len(blockers)} blocker(s):"
                )
                for blocker in blockers:
                    print(f"- {blocker}")
            else:
                print("Production Core Catalog distribution has no static blockers.")
        return 0
    except (OSError, UnicodeError, plistlib.InvalidFileException, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
