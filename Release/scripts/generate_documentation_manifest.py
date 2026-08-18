#!/usr/bin/env python3
"""Generate or verify the deterministic V0.7 documentation manifest."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from v07_documentation import (
    AcceptanceError,
    atomic_write,
    canonical_json_bytes,
    configured_epoch,
    documentation_manifest,
    load_config,
)


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Generate a SOURCE_DATE_EPOCH-stable VelaDocumentationManifest.json"
    )
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--config", default="Release/config/documentation.json")
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--app-build", required=True, type=int)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="compare output bytes without modifying the file",
    )
    args = parser.parse_args()
    try:
        root = Path(args.repository_root).resolve(strict=True)
        config = load_config(root, Path(args.config))
        epoch = configured_epoch(config, require_environment=True)
        raw = canonical_json_bytes(
            documentation_manifest(
                root,
                config,
                args.app_version,
                args.app_build,
                epoch,
            )
        )
        output = Path(args.output)
        if not output.is_absolute():
            output = root / output
        if args.verify:
            if not output.is_file() or output.is_symlink() or output.read_bytes() != raw:
                raise AcceptanceError(
                    "documentation manifest output differs from its deterministic rebuild"
                )
            print(f"Verified deterministic documentation manifest: {output}")
        else:
            atomic_write(output, raw)
            print(f"Generated deterministic documentation manifest: {output}")
        return 0
    except (AcceptanceError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
