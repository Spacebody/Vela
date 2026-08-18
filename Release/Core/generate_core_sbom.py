#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    load_json,
    read_regular_bytes,
    parse_time,
    sha256_bytes,
    validate_file_index,
    validate_seed,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an SPDX 2.3 manifest for a signed Mihomo Core release")
    parser.add_argument("--seed", required=True)
    parser.add_argument("--file-index", required=True)
    parser.add_argument("--core-id", required=True)
    parser.add_argument("--created-at", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        seed = validate_seed(load_json(Path(args.seed), maximum=64 * 1024))
        parse_time(args.created_at, "SBOM createdAt")
        index_raw = read_regular_bytes(Path(args.file_index), maximum=1024 * 1024)
        files = validate_file_index(json.loads(index_raw))
        namespace = uuid.uuid5(uuid.NAMESPACE_URL, f"vela-core:{args.core_id}:{seed['commit']}:{sha256_bytes(index_raw)}")
        sbom = {
            "spdxVersion": "SPDX-2.3",
            "dataLicense": "CC0-1.0",
            "SPDXID": "SPDXRef-DOCUMENT",
            "name": f"VelaMihomoCore-{args.core_id}",
            "documentNamespace": f"urn:uuid:{namespace}",
            "creationInfo": {"created": args.created_at, "creators": ["Tool: Vela Core Release Engineering 0.6"]},
            "packages": [{
                "SPDXID": "SPDXRef-Package-Mihomo",
                "name": "Mihomo",
                "versionInfo": seed["version"],
                "downloadLocation": seed["assetURL"],
                "filesAnalyzed": False,
                "licenseConcluded": "GPL-3.0-only",
                "licenseDeclared": "GPL-3.0-only",
                "copyrightText": "See packaged upstream LICENSE",
                "checksums": [{"algorithm": "SHA256", "checksumValue": seed["archiveSHA256"]}],
                "sourceInfo": f"Exact commit {seed['commit']}; corresponding source {seed['sourceURL']}; Vela does not modify upstream bytes",
            }],
            "externalDocumentRefs": [],
            "annotations": [{
                "annotationType": "OTHER",
                "annotator": "Tool: Vela Core Release Engineering 0.6",
                "annotationDate": args.created_at,
                "comment": f"Signed Core fixed-file index SHA-256 {sha256_bytes(index_raw)} with {len(files)} files",
            }],
            "relationships": [{
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": "SPDXRef-Package-Mihomo",
            }],
        }
        atomic_write(Path(args.output), canonical_json_bytes(sbom))
        print(f"Generated Core SPDX 2.3 SBOM: {args.output}")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
