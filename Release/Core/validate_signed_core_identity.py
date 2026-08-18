#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_release_lib import CoreReleaseError, read_regular_bytes
from signed_core_identity import validate_signed_core_identity


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate final post-notarization Core identity")
    parser.add_argument("identity")
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--compatibility-report", required=True)
    parser.add_argument("--upstream-payload", required=True)
    args = parser.parse_args()
    try:
        value = validate_signed_core_identity(
            read_regular_bytes(Path(args.identity), maximum=2 * 1024 * 1024),
            Path(args.bundle),
            Path(args.compatibility_report),
            Path(args.upstream_payload),
        )
        print(
            "Final signed Core identity validated: "
            f"coreID={value['coreID']} executableSHA256={value['signedExecutableSHA256']}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
