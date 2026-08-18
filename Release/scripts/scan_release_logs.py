#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern[str]


RULES = [
    Rule("private key material", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    Rule("PKCS12 material", re.compile(r"-----BEGIN PKCS12-----")),
    Rule("authorization header", re.compile(r"\bAuthorization\s*:\s*(?:Bearer|Basic)\s+", re.IGNORECASE)),
    Rule("GitHub token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b")),
    Rule("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    Rule("credential-bearing URL", re.compile(r"https?://[^\s/:]+:[^\s/@]+@", re.IGNORECASE)),
    Rule("controller secret", re.compile(r"\b(?:CLASH_OVERRIDE_SECRET|controllerSecret)\s*[=:]", re.IGNORECASE)),
    Rule("Sparkle private key", re.compile(r"sparkle[^\n]{0,40}(?:private|secret)[^\n]{0,20}(?:key|=)", re.IGNORECASE)),
    Rule("Sparkle public-key placeholder", re.compile(r"__SPARKLE_ED25519_PUBLIC_KEY__")),
    Rule("update-domain placeholder", re.compile(r"updates\.(?:__DOMAIN__|example\.invalid)")),
    Rule("generic placeholder", re.compile(r"__[A-Z][A-Z0-9_]{2,}__")),
    Rule("absolute user path", re.compile(r"/Users/[^/\s]+/")),
]


def files_under(root: Path):
    if root.is_symlink():
        raise ValueError(f"scan root must not be a symlink: {root}")
    if root.is_file():
        yield root
        return
    if not root.is_dir():
        raise ValueError(f"scan root does not exist: {root}")
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        yield path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scan explicit release output/log roots without echoing matched secrets"
    )
    parser.add_argument("roots", nargs="+", help="Release staging/output files or directories")
    parser.add_argument("--maximum-file-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()
    if args.maximum_file_bytes <= 0:
        print("error: --maximum-file-bytes must be positive", file=sys.stderr)
        return 1

    findings: list[tuple[Path, int, str]] = []
    scanned = 0
    try:
        for raw_root in args.roots:
            root = Path(raw_root)
            for path in files_under(root):
                size = path.stat().st_size
                with path.open("rb") as handle:
                    prefix = handle.read(8192)
                if b"\x00" in prefix:
                    continue
                if size > args.maximum_file_bytes:
                    raise ValueError(
                        f"text file exceeds scan limit and cannot be skipped safely: {path}"
                    )
                data = path.read_bytes()
                text = data.decode("utf-8", errors="replace")
                scanned += 1
                for line_number, line in enumerate(text.splitlines(), 1):
                    for rule in RULES:
                        if rule.pattern.search(line):
                            findings.append((path, line_number, rule.name))
        if findings:
            for path, line_number, rule_name in findings:
                # Deliberately omit line content: a scanner must not copy a secret into CI logs.
                print(f"finding: {path}:{line_number}: {rule_name}", file=sys.stderr)
            print(f"error: release scan found {len(findings)} forbidden pattern(s)", file=sys.stderr)
            return 1
        print(f"Release log/output scan passed: {scanned} text file(s)")
        return 0
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
