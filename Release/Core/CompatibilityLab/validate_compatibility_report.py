#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from compatibility_lab import CompatibilityError, load_json, validate_report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Vela Core compatibility report")
    parser.add_argument("report")
    parser.add_argument("--core-id")
    parser.add_argument("--dedicated-host-evidence")
    parser.add_argument("--performance-review")
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    try:
        report = validate_report(
            load_json(Path(args.report)),
            production=args.production,
            expected_core_id=args.core_id,
            dedicated_host_evidence_path=(
                Path(args.dedicated_host_evidence)
                if args.dedicated_host_evidence
                else None
            ),
            performance_review_path=(
                Path(args.performance_review) if args.performance_review else None
            ),
        )
        print(
            f"Compatibility report validated: coreID={report['coreID']} "
            f"suite={report['suiteVersion']} result={report['result']}"
        )
        return 0
    except (CompatibilityError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
