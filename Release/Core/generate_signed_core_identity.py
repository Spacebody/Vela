#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_release_lib import CoreReleaseError, atomic_write, canonical_json_bytes
from signed_core_identity import build_signed_core_identity


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate final post-notarization Core identity")
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--compatibility-report", required=True)
    parser.add_argument("--upstream-payload", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        identity = build_signed_core_identity(
            Path(args.bundle), Path(args.compatibility_report), Path(args.upstream_payload)
        )
        atomic_write(Path(args.output), canonical_json_bytes(identity), mode=0o600)
        print(
            "Generated final signed Core identity: "
            f"coreID={identity['coreID']} executableSHA256={identity['signedExecutableSHA256']}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
