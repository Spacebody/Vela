#!/usr/bin/env python3
"""Bind a release request to the version/build frozen in tagged source."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class IdentityError(ValueError):
    pass


def load_object(path: Path, label: str) -> dict:
    if not path.is_file() or path.is_symlink():
        raise IdentityError(f"{label} must be a regular non-symlink file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IdentityError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise IdentityError(f"{label} must contain a JSON object")
    return value


def release_settings(project: Path) -> list[dict[str, str]]:
    if not project.is_file() or project.is_symlink():
        raise IdentityError(f"Xcode project file is missing or unsafe: {project}")
    text = project.read_text(encoding="utf-8")
    blocks = re.findall(
        r"/\* Release \*/\s*=\s*\{.*?buildSettings\s*=\s*\{(.*?)"
        r"\n\s*\};\s*name\s*=\s*Release;\s*\};",
        text,
        re.S,
    )
    values: list[dict[str, str]] = []
    for block in blocks:
        settings = {
            name: raw.strip().strip('"')
            for name, raw in re.findall(
                r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*([^;]+);\s*$", block, re.M
            )
        }
        if "PRODUCT_BUNDLE_IDENTIFIER" in settings:
            values.append(settings)
    if not values:
        raise IdentityError("Xcode project contains no product Release configurations")
    return values


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Require requested release identity to equal the tagged source freeze"
    )
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--release-config", default="Release/config/release.json")
    parser.add_argument(
        "--architecture-freeze",
        default="Hardening/config/architecture-freeze.json",
    )
    parser.add_argument(
        "--project-file",
        default="Vela.xcodeproj/project.pbxproj",
    )
    args = parser.parse_args()

    try:
        root = Path(args.repository_root).resolve()
        release = load_object(root / args.release_config, "release config")
        architecture = load_object(root / args.architecture_freeze, "architecture freeze")
        configured_version = release.get("versioning", {}).get("marketingVersion")
        product = architecture.get("product")
        if not isinstance(product, dict):
            raise IdentityError("architecture freeze has no product identity")

        expected = (args.version, str(args.build))
        identities = {
            "release config": (configured_version, str(args.build)),
            "architecture freeze": (
                product.get("marketingVersion"),
                str(product.get("build")),
            ),
        }
        for label, actual in identities.items():
            if actual != expected:
                raise IdentityError(
                    f"{label} identity {actual[0]} ({actual[1]}) differs from "
                    f"requested {expected[0]} ({expected[1]})"
                )

        products = release_settings(root / args.project_file)
        main_bundle = release.get("product", {}).get("bundleIdentifier")
        if not isinstance(main_bundle, str) or not main_bundle:
            raise IdentityError("release config has no product bundle identifier")
        main_matches = [
            item for item in products if item.get("PRODUCT_BUNDLE_IDENTIFIER") == main_bundle
        ]
        if len(main_matches) != 1:
            raise IdentityError(
                f"expected one Release configuration for {main_bundle}, found {len(main_matches)}"
            )

        for settings in products:
            identifier = settings["PRODUCT_BUNDLE_IDENTIFIER"]
            actual = (
                settings.get("MARKETING_VERSION"),
                settings.get("CURRENT_PROJECT_VERSION"),
            )
            if actual != expected:
                raise IdentityError(
                    f"Release configuration {identifier} identity {actual[0]} ({actual[1]}) "
                    f"differs from requested {expected[0]} ({expected[1]})"
                )

        print(
            f"Tagged source identity passed: {args.version} ({args.build}); "
            f"{len(products)} Release product configurations agree."
        )
        return 0
    except (IdentityError, OSError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
