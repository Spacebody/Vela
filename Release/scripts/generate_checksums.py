#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def safe_relative_name(value: str) -> Path:
    if "\\" in value or "\n" in value or "\r" in value:
        raise ValueError("checksum filename contains an unsafe character")
    path = Path(value)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"checksum filename must be a safe relative path: {value}")
    return path


def reject_symlink_path(root: Path, relative: Path) -> Path:
    candidate = root
    for part in relative.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise ValueError(f"checksum path traverses a symlink: {relative.as_posix()}")
    return candidate


def generate(output: Path, artifacts: list[Path], base_dir: Path | None = None) -> None:
    if not artifacts:
        raise ValueError("at least one artifact is required")
    if output.exists() or output.is_symlink():
        raise ValueError(f"refusing to overwrite immutable checksum output: {output}")
    root: Path | None = None
    if base_dir is not None:
        if not base_dir.is_dir() or base_dir.is_symlink():
            raise ValueError(f"checksum base directory is unsafe: {base_dir}")
        root = base_dir.resolve()
    names: set[str] = set()
    rows: list[str] = []
    records: list[tuple[str, Path]] = []
    for artifact in artifacts:
        if not regular_file(artifact):
            raise ValueError(f"artifact must be a regular non-symlink file: {artifact}")
        if root is None:
            name = artifact.name
        else:
            try:
                relative = artifact.resolve().relative_to(root)
            except ValueError as error:
                raise ValueError(f"artifact escapes checksum base directory: {artifact}") from error
            safe_relative_name(relative.as_posix())
            reject_symlink_path(root, relative)
            name = relative.as_posix()
        if name in names:
            raise ValueError(f"duplicate artifact path: {name}")
        names.add(name)
        records.append((name, artifact))
    for name, artifact in sorted(records):
        rows.append(f"{sha256(artifact)}  {name}\n")

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise ValueError(f"checksum output parent is unsafe: {output.parent}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", dir=output.parent, text=True
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.writelines(rows)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        try:
            os.link(temporary, output)
        except FileExistsError as error:
            raise ValueError(
                f"checksum output appeared concurrently; refusing overwrite: {output}"
            ) from error
    finally:
        if temporary.exists():
            temporary.unlink()


def verify(checksums: Path, base_dir: Path, require_complete: bool = False) -> None:
    if not regular_file(checksums):
        raise ValueError(f"checksums must be a regular non-symlink file: {checksums}")
    if not base_dir.is_dir() or base_dir.is_symlink():
        raise ValueError(f"checksum base directory is unsafe: {base_dir}")
    root = base_dir.resolve()
    seen: set[str] = set()
    for line_number, line in enumerate(checksums.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        pieces = line.split("  ", 1)
        if len(pieces) != 2 or len(pieces[0]) != 64:
            raise ValueError(f"invalid checksum row at line {line_number}")
        digest, name = pieces
        if re_full_sha256(digest) is False:
            raise ValueError(f"invalid SHA-256 at line {line_number}")
        relative = safe_relative_name(name)
        if name in seen:
            raise ValueError(f"duplicate checksum filename at line {line_number}")
        seen.add(name)
        artifact = reject_symlink_path(root, relative)
        if not regular_file(artifact):
            raise ValueError(f"checksum artifact is missing or unsafe: {name}")
        actual = sha256(artifact)
        if actual != digest:
            raise ValueError(f"checksum mismatch: {name}")
    if require_complete:
        checksum_path = checksums.resolve()
        actual_files: set[str] = set()
        for artifact in sorted(root.rglob("*")):
            if artifact.is_symlink():
                raise ValueError(f"checksum base directory contains a symlink: {artifact}")
            if not artifact.is_file() or artifact.resolve() == checksum_path:
                continue
            relative = artifact.relative_to(root).as_posix()
            safe_relative_name(relative)
            actual_files.add(relative)
        if actual_files != seen:
            missing = sorted(actual_files - seen)
            unknown = sorted(seen - actual_files)
            raise ValueError(
                "checksum inventory is not complete"
                f"; unhashed={missing or 'none'}; missing={unknown or 'none'}"
            )


def re_full_sha256(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate or verify Vela SHA-256 checksums")
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--output", required=True)
    generate_parser.add_argument("--base-dir")
    generate_parser.add_argument("artifacts", nargs="+")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--checksums", required=True)
    verify_parser.add_argument("--base-dir", required=True)
    verify_parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()

    try:
        if args.command == "generate":
            output = Path(args.output)
            generate(
                output,
                [Path(value) for value in args.artifacts],
                Path(args.base_dir) if args.base_dir else None,
            )
            print(f"Wrote immutable checksums: {output}")
        else:
            verify(
                Path(args.checksums),
                Path(args.base_dir),
                require_complete=args.require_complete,
            )
            print(f"Checksums verified: {args.checksums}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
