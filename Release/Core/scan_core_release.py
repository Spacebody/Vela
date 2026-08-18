#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


RULES = [
    ("latest endpoint", re.compile(r"(?:releases|download)/latest(?:/|\b)", re.IGNORECASE)),
    (
        "test Core key",
        re.compile(
            r"(?:key.?id|core.?catalog.?key)[^\n]{0,96}\btest(?:[-_.]|\b)",
            re.IGNORECASE,
        ),
    ),
    ("private key PEM", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("private key field", re.compile(r"(?:privateKeySeedHex|private[_-]?key|secret[_-]?key)\s*[=:]", re.IGNORECASE)),
    ("credential-bearing URL", re.compile(r"https?://[^\s/:]+:[^\s/@]+@", re.IGNORECASE)),
    ("authorization header", re.compile(r"\bAuthorization\s*:\s*(?:Bearer|Basic)\s+", re.IGNORECASE)),
    ("GitHub token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b")),
    ("Sparkle secret", re.compile(r"sparkle[^\n]{0,40}(?:private|secret)[^\n]{0,20}(?:key|=)", re.IGNORECASE)),
    ("Core placeholder", re.compile(r"__(?:CORE|CATALOG|DEVELOPER|NOTARY)_[A-Z0-9_]+__")),
    ("insecure Core URL", re.compile(r"http://[^\s]*cores", re.IGNORECASE)),
    ("absolute user path", re.compile(r"/Users/[^/\s]+/")),
]


def files(root: Path):
    if root.is_symlink():
        raise ValueError(f"scan root must not be a symlink: {root}")
    if root.is_file():
        yield root
    elif root.is_dir():
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"release output contains a symlink: {path}")
            if path.is_file():
                yield path
    else:
        raise ValueError(f"scan root does not exist: {root}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan Core release output without echoing secret contents")
    parser.add_argument("roots", nargs="+")
    parser.add_argument("--maximum-text-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()
    findings: list[tuple[Path, int, str]] = []
    scanned = 0
    try:
        for root_name in args.roots:
            for path in files(Path(root_name)):
                lowered = path.name.lower()
                if lowered.endswith((".p12", ".p8", ".key", ".keychain", ".keychain-db")) or lowered in {"authkey", "credentials"}:
                    findings.append((path, 0, "credential-bearing filename"))
                    continue
                with path.open("rb") as handle:
                    prefix = handle.read(8192)
                if b"\x00" in prefix:
                    continue
                if path.stat().st_size > args.maximum_text_bytes:
                    raise ValueError(f"text file exceeds scan limit: {path}")
                text = path.read_text(encoding="utf-8", errors="replace")
                scanned += 1
                for line_number, line in enumerate(text.splitlines(), 1):
                    for name, pattern in RULES:
                        if pattern.search(line):
                            findings.append((path, line_number, name))
        for path, line, name in findings:
            print(f"finding: {path}:{line}: {name}", file=sys.stderr)
        if findings:
            print(f"error: Core release scan found {len(findings)} forbidden pattern(s)", file=sys.stderr)
            return 1
        print(f"Core release scan passed: {scanned} text file(s)")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
