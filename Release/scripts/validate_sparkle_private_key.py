#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import binascii
import sys
from pathlib import Path


class KeyError(ValueError):
    pass


def validate(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise KeyError("Sparkle EdDSA key must be a regular non-symlink file")
    try:
        encoded = path.read_text(encoding="utf-8").strip()
        secret = base64.b64decode(encoded, validate=True)
    except (OSError, UnicodeError, binascii.Error, ValueError) as error:
        raise KeyError("Sparkle EdDSA key file is not canonical Base64 text") from error
    # Sparkle 2.9.4 accepts a 64-byte current-format secret or the 96-byte
    # legacy private+public representation. A raw 32-byte seed is not an
    # importable sign_update/generate_appcast key file.
    if len(secret) not in {64, 96}:
        raise KeyError(
            "Sparkle EdDSA key must decode to a 64-byte key or 96-byte legacy key"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Sparkle 2.9.4 EdDSA key file")
    parser.add_argument("key_file")
    args = parser.parse_args()
    try:
        validate(Path(args.key_file))
        print("Sparkle EdDSA private-key format passed.")
        return 0
    except KeyError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
