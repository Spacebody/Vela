#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from core_release_evidence import create_evidence_archive, validate_evidence_archive
from core_release_lib import CoreReleaseError


def main() -> int:
    parser = argparse.ArgumentParser(description="Create complete private Core release evidence")
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--public-directory", required=True)
    parser.add_argument("--prepared-directory")
    parser.add_argument("--prior-catalog")
    parser.add_argument("--archive-output", required=True)
    parser.add_argument("--manifest-output", required=True)
    args = parser.parse_args()
    try:
        archive = Path(args.archive_output)
        manifest_path = Path(args.manifest_output)
        manifest = create_evidence_archive(
            repository_root=Path(args.repository_root),
            config_path=Path(args.config),
            public_directory=Path(args.public_directory),
            prepared_directory=(
                Path(args.prepared_directory) if args.prepared_directory else None
            ),
            prior_catalog=Path(args.prior_catalog) if args.prior_catalog else None,
            archive_output=archive,
            manifest_output=manifest_path,
        )
        validate_evidence_archive(archive, manifest_path)
        print(
            "Created and validated private Core release evidence: "
            f"operation={manifest['operation']} files={len(manifest['files'])} archive={archive}"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
