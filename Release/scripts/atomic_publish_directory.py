#!/usr/bin/env python3
"""Atomically publish a directory on macOS without replacing a destination."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import platform
import stat
import sys
from pathlib import Path


RENAME_EXCL = 0x00000004


class PublishError(ValueError):
    pass


def open_bound_directory(path: Path, *, label: str) -> int:
    if not path.is_dir() or path.is_symlink():
        raise PublishError(f"{label} is missing or unsafe: {path}")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    current = path.lstat()
    if not stat.S_ISDIR(opened.st_mode) or (
        opened.st_dev,
        opened.st_ino,
    ) != (current.st_dev, current.st_ino):
        os.close(descriptor)
        raise PublishError(f"{label} changed while it was opened: {path}")
    return descriptor


def relative_metadata(descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_directory_binding(path: Path, descriptor: int, *, label: str) -> None:
    current = path.lstat()
    opened = os.fstat(descriptor)
    if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
        raise PublishError(f"{label} changed during exclusive publication: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()

    try:
        if platform.system() != "Darwin":
            raise PublishError("exclusive candidate publication requires macOS renameatx_np")
        source = Path(args.source)
        destination = Path(args.destination)
        if source.name in {"", ".", ".."} or destination.name in {"", ".", ".."}:
            raise PublishError("source and destination must name child directories")
        if not source.is_dir() or source.is_symlink():
            raise PublishError(f"source must be a regular non-symlink directory: {source}")
        if destination.exists() or destination.is_symlink():
            raise PublishError(f"destination already exists: {destination}")
        parent = destination.parent
        source_parent = source.parent
        source_parent_fd = open_bound_directory(source_parent, label="source parent")
        try:
            destination_parent_fd = open_bound_directory(parent, label="destination parent")
            try:
                source_parent_metadata = os.fstat(source_parent_fd)
                destination_parent_metadata = os.fstat(destination_parent_fd)
                if (
                    source_parent_metadata.st_dev,
                    source_parent_metadata.st_ino,
                ) != (
                    destination_parent_metadata.st_dev,
                    destination_parent_metadata.st_ino,
                ):
                    raise PublishError("source and destination must share the exact parent directory")
                source_before = relative_metadata(source_parent_fd, source.name)
                if source_before is None or not stat.S_ISDIR(source_before.st_mode):
                    raise PublishError("source changed before exclusive publication")
                if relative_metadata(destination_parent_fd, destination.name) is not None:
                    raise PublishError(f"destination already exists: {destination}")

                libc = ctypes.CDLL(None, use_errno=True)
                rename = libc.renameatx_np
                rename.argtypes = [
                    ctypes.c_int,
                    ctypes.c_char_p,
                    ctypes.c_int,
                    ctypes.c_char_p,
                    ctypes.c_uint,
                ]
                rename.restype = ctypes.c_int
                result = rename(
                    source_parent_fd,
                    os.fsencode(source.name),
                    destination_parent_fd,
                    os.fsencode(destination.name),
                    RENAME_EXCL,
                )
                if result != 0:
                    code = ctypes.get_errno()
                    if code in {errno.EEXIST, errno.ENOTEMPTY}:
                        raise PublishError(f"destination appeared concurrently: {destination}")
                    raise PublishError(f"exclusive rename failed: {os.strerror(code)}")

                if relative_metadata(source_parent_fd, source.name) is not None:
                    raise PublishError("source still exists after exclusive publication")
                destination_after = relative_metadata(destination_parent_fd, destination.name)
                if destination_after is None or not stat.S_ISDIR(destination_after.st_mode) or (
                    destination_after.st_dev,
                    destination_after.st_ino,
                ) != (source_before.st_dev, source_before.st_ino):
                    raise PublishError("published destination is not the exact source directory")
                require_directory_binding(source_parent, source_parent_fd, label="source parent")
                require_directory_binding(parent, destination_parent_fd, label="destination parent")
            finally:
                os.close(destination_parent_fd)
        finally:
            os.close(source_parent_fd)
        print(destination)
        return 0
    except (OSError, PublishError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
