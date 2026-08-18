#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_release_evidence import validate_evidence_archive
from core_release_lib import CoreReleaseError


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate private Core release evidence archive")
    parser.add_argument("archive")
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    try:
        manifest = validate_evidence_archive(Path(args.archive), Path(args.manifest))
        print(
            "Private Core release evidence validated: "
            f"operation={manifest['operation']} files={len(manifest['files'])}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
