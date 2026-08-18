#!/usr/bin/env python3
"""Create a stable crash signature from already-symbolicated, sanitized frames."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

from json_schema import SchemaError, validate


FRAME = re.compile(r"^[A-Za-z_$][A-Za-z0-9_.$<>:+()-]{0,199}$")
SENSITIVE_SYMBOL = re.compile(r"(?i)(?:authorization|bearer|password|secret|token|apikey|credential)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--component", choices=["Vela", "VelaHelper", "vela", "mihomo", "Sparkle", "testHarness"], required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--exception", required=True)
    parser.add_argument("--category", choices=["launch", "stateTransition", "xpc", "configuration", "ui", "update", "core", "migration", "resourceExhaustion", "upstreamMihomo", "unknown"], required=True)
    parser.add_argument("--frame", action="append", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", args.exception):
            raise ValueError("exception must be a stable type/signal without raw detail")
        if not 1 <= len(args.frame) <= 8 or any(
            FRAME.fullmatch(frame) is None or SENSITIVE_SYMBOL.search(frame)
            for frame in args.frame
        ):
            raise ValueError("frames must be 1-8 sanitized application symbols without paths/addresses")
        signature_input = "\n".join(
            ["schema=1", args.component, args.exception, str(args.build), args.category, *args.frame]
        ).encode()
        result = {
            "schemaVersion": 1,
            "component": args.component,
            "build": args.build,
            "exception": args.exception,
            "category": args.category,
            "topApplicationFrames": args.frame,
            "signatureSHA256": hashlib.sha256(signature_input).hexdigest(),
            "containsUserData": False,
        }
        schema = json.loads(
            (Path(__file__).resolve().parents[1] / "schemas/crash-signature.schema.json").read_text(encoding="utf-8")
        )
        validate(result, schema)
        output = Path(args.output)
        if output.exists():
            raise ValueError(f"refusing to overwrite {output}")
        output.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except (OSError, ValueError, json.JSONDecodeError, SchemaError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
