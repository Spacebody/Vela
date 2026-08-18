#!/usr/bin/env python3
"""Validate and print Vela's canonical protected promotion-evidence root."""

from __future__ import annotations

import argparse
import os
import stat
from pathlib import Path

from _common import GateError, main_error
from candidate_stage_common import secure_private_evidence_root


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument(
        "--direct-file",
        action="append",
        default=[],
        help="Require a consumed or new file path to be directly below root/private",
    )
    args = parser.parse_args()
    try:
        root = secure_private_evidence_root(args.root, label="protected evidence root")
        private = root / "private"
        for raw in args.direct_file:
            supplied = Path(raw)
            if ".." in supplied.parts:
                raise GateError(f"protected evidence path may not contain '..': {raw}")
            candidate = Path(os.path.abspath(supplied))
            try:
                parent = candidate.parent.resolve(strict=True)
            except OSError as error:
                raise GateError(
                    f"protected evidence path parent is missing or unsafe: {candidate.parent}"
                ) from error
            if parent != private:
                raise GateError(
                    f"protected evidence file must be directly below {private}: {candidate}"
                )
            if candidate.is_symlink():
                raise GateError(f"protected evidence file must not be a symlink: {candidate}")
            if candidate.exists():
                metadata = candidate.lstat()
                if not stat.S_ISREG(metadata.st_mode):
                    raise GateError(
                        f"protected evidence input must be a regular file: {candidate}"
                    )
                if metadata.st_uid != os.geteuid():
                    raise GateError(
                        f"protected evidence input must be owned by the release user: {candidate}"
                    )
                if stat.S_IMODE(metadata.st_mode) != 0o600:
                    raise GateError(
                        f"protected evidence input permissions must be 0600: {candidate}"
                    )
        print(root)
        return 0
    except (GateError, OSError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
