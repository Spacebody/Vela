#!/usr/bin/env python3
"""Validate Vela V0.7 source or exported-App acceptance without dependencies."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from v07_documentation import (
    AcceptanceError,
    load_config,
    run_self_test,
    validate_archive,
    validate_source,
)


def emit_failures(mode: str, failures: list[str]) -> int:
    if not failures:
        print(f"Vela V0.7 {mode} acceptance passed.")
        return 0
    print(f"error: Vela V0.7 {mode} acceptance failed:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    return 1


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--source", action="store_true", help="validate repository sources")
    modes.add_argument("--archive", metavar="VELA_APP", help="validate an exported Vela.app")
    modes.add_argument("--self-test", action="store_true", help="run isolated positive/negative fixtures")
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--config", default="Release/config/documentation.json")
    parser.add_argument("--app-version")
    parser.add_argument("--app-build", type=int)
    args = parser.parse_args()
    try:
        if args.self_test:
            run_self_test()
            print("Vela V0.7 acceptance self-test passed.")
            return 0
        if not args.app_version or args.app_build is None:
            raise AcceptanceError("--app-version and --app-build are required")
        root = Path(args.repository_root).resolve(strict=True)
        config = load_config(root, Path(args.config))
        if args.source:
            return emit_failures(
                "source",
                validate_source(root, config, args.app_version, args.app_build),
            )
        return emit_failures(
            "archive",
            validate_archive(
                root,
                config,
                Path(args.archive),
                args.app_version,
                args.app_build,
            ),
        )
    except (AcceptanceError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
