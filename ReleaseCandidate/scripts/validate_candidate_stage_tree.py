#!/usr/bin/env python3
"""Validate a retained candidate tree without rejecting legitimate bundle links."""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path


class TreeError(ValueError):
    pass


ALLOWED_LINK_ROOTS = (
    Path("build/Vela.xcarchive"),
    Path("export/Vela.app"),
)


def contained(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def allowed_link_root(relative: Path) -> Path | None:
    for allowed in ALLOWED_LINK_ROOTS:
        if relative == allowed or contained(relative, allowed):
            return allowed
    return None


def validate(root: Path) -> tuple[int, int, int]:
    if not root.is_dir() or root.is_symlink():
        raise TreeError(f"candidate stage must be a regular non-symlink directory: {root}")
    root = root.resolve(strict=True)
    counts = {"files": 0, "directories": 0, "symlinks": 0}

    def visit(directory: Path) -> None:
        counts["directories"] += 1
        before = directory.lstat()
        if stat.S_IMODE(before.st_mode) & 0o022:
            raise TreeError(f"candidate directory is group/world writable: {directory}")
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_IMODE(metadata.st_mode) & 0o022:
                raise TreeError(f"candidate entry is group/world writable: {path}")
            relative = path.relative_to(root)
            if stat.S_ISDIR(metadata.st_mode):
                visit(path)
            elif stat.S_ISREG(metadata.st_mode):
                counts["files"] += 1
            elif stat.S_ISLNK(metadata.st_mode):
                link_root_relative = allowed_link_root(relative)
                if link_root_relative is None:
                    raise TreeError(f"candidate symlink is outside an allowed bundle: {relative}")
                target_text = os.readlink(path)
                if os.path.isabs(target_text):
                    raise TreeError(f"candidate symlink target must be relative: {relative}")
                try:
                    resolved = path.resolve(strict=True)
                except OSError as error:
                    raise TreeError(f"candidate symlink is dangling: {relative}: {error}") from error
                link_root = root / link_root_relative
                if not contained(resolved, link_root):
                    raise TreeError(f"candidate symlink escapes its signed bundle: {relative}")
                counts["symlinks"] += 1
            else:
                raise TreeError(f"candidate tree contains a special file: {relative}")
        after = directory.lstat()
        if (before.st_dev, before.st_ino, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_mtime_ns,
        ):
            raise TreeError(f"candidate directory changed while it was enumerated: {directory}")

    visit(root)
    return counts["files"], counts["directories"], counts["symlinks"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate_stage")
    args = parser.parse_args()
    try:
        files, directories, symlinks = validate(Path(args.candidate_stage))
        print(
            "Candidate-stage tree passed: "
            f"{files} files, {directories} directories, {symlinks} contained bundle symlinks."
        )
        return 0
    except (OSError, TreeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
