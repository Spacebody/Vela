#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import subprocess
from pathlib import Path

from schema_validation import load_and_validate

ROOT = Path(__file__).resolve().parents[1]


def git_paths(*arguments: str) -> list[str]:
    return subprocess.check_output(
        ["/usr/bin/git", *arguments],
        text=True,
    ).splitlines()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("page_contract")
    parser.add_argument("--base")
    parser.add_argument("--paths-file")
    args = parser.parse_args()

    contract = load_and_validate(
        Path(args.page_contract),
        ROOT / "schemas/page-contract.schema.json",
    )
    allowed = contract["allowedPaths"]

    if args.paths_file:
        changed = [
            line.strip()
            for line in Path(args.paths_file).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    else:
        candidates = []
        if args.base:
            candidates.extend(git_paths("diff", "--name-only", f"{args.base}...HEAD"))
        candidates.extend(git_paths("diff", "--name-only"))
        candidates.extend(git_paths("diff", "--cached", "--name-only"))
        candidates.extend(git_paths("ls-files", "--others", "--exclude-standard"))
        changed = list(dict.fromkeys(path for path in candidates if path))

    violations = [
        path
        for path in changed
        if not any(fnmatch.fnmatch(path, pattern) for pattern in allowed)
    ]
    for path in changed:
        status = "allowed" if path not in violations else "VIOLATION"
        print(f"{status}: {path}")

    if violations:
        raise SystemExit(
            "Changed paths exceed the page contract:\n- "
            + "\n- ".join(violations)
        )
    print("Changed path validation passed.")


if __name__ == "__main__":
    main()
