#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


REQUIRED_HEADINGS = [
    "Fixed",
    "Security",
    "Reliability",
    "Migration",
    "Accessibility",
    "Localization",
    "Documentation",
    "Known Issues",
    "Upgrade Notes",
]
CANDIDATE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-rc\.([1-9][0-9]*))?$"
)


def expected_title(candidate_version: str) -> str:
    match = CANDIDATE_VERSION.fullmatch(candidate_version)
    if match is None:
        raise ValueError("candidate version must be stable SemVer or use the exact rc.N prerelease")
    base = ".".join(match.group(index) for index in range(1, 4))
    sequence = match.group(4)
    return f"# Vela {base}" + (f" RC {sequence}" if sequence else "")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Vela Markdown release notes")
    parser.add_argument("notes")
    parser.add_argument("--candidate-version")
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()

    path = Path(args.notes)
    if not path.is_file() or path.is_symlink():
        print(f"error: expected a regular release-notes file: {path}", file=sys.stderr)
        return 1
    if path.stat().st_size > 512 * 1024:
        print("error: release notes exceed 512 KiB", file=sys.stderr)
        return 1
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        print(f"error: could not read UTF-8 release notes: {error}", file=sys.stderr)
        return 1
    lower = text.lower()
    if "\x00" in text:
        print("error: release notes contain a NUL byte", file=sys.stderr)
        return 1

    try:
        title = expected_title(args.candidate_version) if args.candidate_version else "# Vela "
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    first_line = text.splitlines()[0] if text.splitlines() else ""
    if args.candidate_version:
        if first_line != title:
            print(f"error: first line must be {title!r}", file=sys.stderr)
            return 1
    elif not first_line.startswith(title):
        print("error: first line must start with '# Vela '", file=sys.stderr)
        return 1

    headings = re.findall(r"^##\s+(.+?)\s*$", text, re.MULTILINE)
    if headings != REQUIRED_HEADINGS:
        print(
            f"error: release-note headings must be exactly {REQUIRED_HEADINGS}; got {headings}",
            file=sys.stderr,
        )
        return 1

    forbidden = ["<script", "<iframe", "<img", "javascript:", "data:", "http://"]
    for token in forbidden:
        if token in lower:
            print(f"error: forbidden release-note content: {token}", file=sys.stderr)
            return 1

    for match in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", text):
        raw_url = match.group(1).strip().split()[0].strip("<>")
        parsed = urlparse(raw_url)
        if parsed.scheme != "https" or not parsed.hostname:
            print(f"error: Markdown link must be HTTPS: {raw_url}", file=sys.stderr)
            return 1
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            print(f"error: release-note link may not contain credentials/query/fragment: {raw_url}", file=sys.stderr)
            return 1

    required_phrases = ["macOS 15", "Apple Silicon", "Mihomo v1.19.29"]
    for phrase in required_phrases:
        if phrase not in text:
            print(f"error: missing compatibility text: {phrase}", file=sys.stderr)
            return 1

    if args.production:
        if args.candidate_version is None:
            print("error: production release notes require --candidate-version", file=sys.stderr)
            return 1
        placeholder_patterns = [r"__[^\n]+__", r"\bTODO\b", r"\bTBD\b", r"(?m)^-\s*$"]
        for pattern in placeholder_patterns:
            if re.search(pattern, text, re.IGNORECASE):
                print(f"error: production release notes contain placeholder pattern: {pattern}", file=sys.stderr)
                return 1

    print(f"Release notes validation passed: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
