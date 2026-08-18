#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    ROLE_MODES,
    ROLE_PATHS,
    atomic_write,
    canonical_json_bytes,
    sha256_file,
    validate_file_index,
    validate_https_url,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the fixed seven-file signed Core index")
    parser.add_argument("bundle")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        bundle = Path(args.bundle)
        if not bundle.is_dir() or bundle.is_symlink() or bundle.name != "VelaMihomoCore.bundle":
            raise CoreReleaseError("bundle must be a regular VelaMihomoCore.bundle directory")
        base_url = validate_https_url(args.base_url.rstrip("/"), "base URL")
        files = []
        for role, relative in ROLE_PATHS.items():
            path = bundle / relative
            if not path.is_file() or path.is_symlink():
                raise CoreReleaseError(f"missing or unsafe fixed Core file: {relative}")
            actual_mode = stat.S_IMODE(path.stat().st_mode)
            expected_mode = int(ROLE_MODES[role], 8)
            if actual_mode != expected_mode:
                raise CoreReleaseError(f"invalid mode for {relative}: expected {ROLE_MODES[role]}")
            files.append({
                "role": role,
                "relativePath": relative,
                "url": f"{base_url}/{relative}",
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
                "mode": ROLE_MODES[role],
            })
        validate_file_index(files)
        atomic_write(Path(args.output), canonical_json_bytes(files))
        print(f"Generated fixed Core file index: {args.output} files={len(files)}")
        return 0
    except (OSError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
