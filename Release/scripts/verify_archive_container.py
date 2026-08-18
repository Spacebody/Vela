#!/usr/bin/env python3
"""Safely replay a sealed xcarchive ZIP against its full-tree/dSYM receipt."""

from __future__ import annotations

import argparse
import os
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath


MAX_ENTRIES = 200_000
MAX_FILE_SIZE = 4 * 1024 * 1024 * 1024
MAX_TOTAL_SIZE = 16 * 1024 * 1024 * 1024
CHUNK_SIZE = 1024 * 1024


class ArchiveContainerError(ValueError):
    pass


def regular_file(path: Path, *, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ArchiveContainerError(f"{label} must be a regular non-symlink file: {path}")
    return path


def safe_member(info: zipfile.ZipInfo) -> tuple[PurePosixPath, bool]:
    name = info.filename
    if (
        not name
        or "\\" in name
        or unicodedata.normalize("NFC", name) != name
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
    ):
        raise ArchiveContainerError(f"archive contains an unsafe member name: {name!r}")
    path = PurePosixPath(name.rstrip("/"))
    if (
        path.is_absolute()
        or not path.parts
        or "." in path.parts
        or ".." in path.parts
        or path.as_posix() != name.rstrip("/")
        or path.parts[0] != "Vela.xcarchive"
    ):
        raise ArchiveContainerError(f"archive member escapes Vela.xcarchive: {name!r}")
    if info.flag_bits & 0x1:
        raise ArchiveContainerError(f"encrypted archive members are forbidden: {name!r}")

    unix_mode = info.external_attr >> 16
    file_type = stat.S_IFMT(unix_mode)
    is_directory = info.is_dir() or name.endswith("/")
    if file_type == stat.S_IFLNK:
        raise ArchiveContainerError(f"archive contains a symbolic link: {name!r}")
    if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
        raise ArchiveContainerError(f"archive contains a special file: {name!r}")
    if is_directory and file_type == stat.S_IFREG:
        raise ArchiveContainerError(f"archive directory has file metadata: {name!r}")
    if not is_directory and file_type == stat.S_IFDIR:
        raise ArchiveContainerError(f"archive file has directory metadata: {name!r}")
    if info.file_size < 0 or info.file_size > MAX_FILE_SIZE:
        raise ArchiveContainerError(f"archive member is too large: {name!r}")
    return path, is_directory


def extract_archive(container: Path, destination: Path) -> Path:
    seen: set[str] = set()
    seen_folded: set[str] = set()
    total_size = 0
    extracted_files = 0
    try:
        with zipfile.ZipFile(container) as archive:
            members = archive.infolist()
            if not members or len(members) > MAX_ENTRIES:
                raise ArchiveContainerError("archive member count is empty or exceeds policy")
            checked: list[tuple[zipfile.ZipInfo, PurePosixPath, bool]] = []
            for info in members:
                path, is_directory = safe_member(info)
                normalized = path.as_posix()
                folded = normalized.casefold()
                if normalized in seen or folded in seen_folded:
                    raise ArchiveContainerError(
                        f"archive contains duplicate or case-colliding members: {info.filename!r}"
                    )
                seen.add(normalized)
                seen_folded.add(folded)
                if not is_directory:
                    total_size += info.file_size
                    if total_size > MAX_TOTAL_SIZE:
                        raise ArchiveContainerError("archive uncompressed size exceeds policy")
                checked.append((info, path, is_directory))

            for info, member, is_directory in sorted(
                checked, key=lambda item: (len(item[1].parts), item[1].as_posix())
            ):
                target = destination.joinpath(*member.parts)
                if is_directory:
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    if target.is_symlink() or not target.is_dir():
                        raise ArchiveContainerError(f"unsafe extracted directory: {member}")
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                descriptor = os.open(
                    target,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                )
                written = 0
                try:
                    with archive.open(info, "r") as source, os.fdopen(descriptor, "wb") as output:
                        descriptor = -1
                        while True:
                            chunk = source.read(CHUNK_SIZE)
                            if not chunk:
                                break
                            written += len(chunk)
                            if written > info.file_size:
                                raise ArchiveContainerError(
                                    f"archive member expanded beyond declared size: {member}"
                                )
                            output.write(chunk)
                        output.flush()
                        os.fsync(output.fileno())
                finally:
                    if descriptor >= 0:
                        os.close(descriptor)
                if written != info.file_size:
                    raise ArchiveContainerError(
                        f"archive member size changed during extraction: {member}"
                    )
                extracted_files += 1
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise ArchiveContainerError(f"invalid xcarchive ZIP: {error}") from error

    archive_root = destination / "Vela.xcarchive"
    if not archive_root.is_dir() or archive_root.is_symlink() or extracted_files == 0:
        raise ArchiveContainerError("archive did not extract one regular Vela.xcarchive tree")
    return archive_root


def run_inventory(
    tool: Path,
    *,
    archive: Path,
    receipt: Path,
    public_contract: Path | None,
    required: list[str],
) -> None:
    arguments = [
        sys.executable,
        str(tool),
        "--archive",
        str(archive),
        "--verify-receipt",
        str(receipt),
    ]
    if public_contract is not None:
        arguments.extend(("--public-contract", str(public_contract)))
    for name in required:
        arguments.extend(("--require", name))
    result = subprocess.run(arguments, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "inventory verification failed"
        raise ArchiveContainerError(detail)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove that a sealed xcarchive ZIP replays to the retained tree/dSYM receipt"
    )
    parser.add_argument("--archive-zip", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--public-contract")
    parser.add_argument("--live-archive")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()

    try:
        container = regular_file(Path(args.archive_zip), label="xcarchive ZIP")
        receipt = regular_file(Path(args.receipt), label="dSYM/tree receipt")
        public_contract = (
            regular_file(Path(args.public_contract), label="public contract")
            if args.public_contract
            else None
        )
        tool = regular_file(
            Path(__file__).resolve().parent / "inventory_dsyms.py",
            label="tracked dSYM inventory tool",
        )
        if args.live_archive:
            live_archive = Path(args.live_archive)
            if not live_archive.is_dir() or live_archive.is_symlink():
                raise ArchiveContainerError("live xcarchive must be a regular directory")
            run_inventory(
                tool,
                archive=live_archive,
                receipt=receipt,
                public_contract=public_contract,
                required=args.require,
            )

        with tempfile.TemporaryDirectory(prefix="vela-xcarchive-replay-") as raw:
            extraction_root = Path(raw)
            os.chmod(extraction_root, 0o700)
            extracted_archive = extract_archive(container, extraction_root)
            run_inventory(
                tool,
                archive=extracted_archive,
                receipt=receipt,
                public_contract=public_contract,
                required=args.require,
            )
        print("Sealed xcarchive ZIP exactly replays the retained full-tree/dSYM receipt.")
        return 0
    except (ArchiveContainerError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
