#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


class PathSafetyError(ValueError):
    pass


SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def validate_identifier(value: str, label: str) -> str:
    if not isinstance(value, str) or not SAFE_IDENTIFIER.fullmatch(value):
        raise PathSafetyError(
            f"{label} must match {SAFE_IDENTIFIER.pattern!r}: {value!r}"
        )
    if value in {".", ".."}:
        raise PathSafetyError(f"{label} cannot be {value!r}")
    return value


def validate_relative_path(value: str, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PathSafetyError(f"{label} must be a non-empty relative path")
    if "\\" in value:
        raise PathSafetyError(f"{label} must use '/' path separators")
    raw_parts = value.split("/")
    if any(part in {"", ".", ".."} for part in raw_parts):
        raise PathSafetyError(f"{label} escapes its declared root: {value!r}")
    path = Path(*raw_parts)
    if path.is_absolute():
        raise PathSafetyError(f"{label} must be relative: {value!r}")
    return path


def resolve_regular_file(root: Path, value: str, label: str) -> Path:
    relative = validate_relative_path(value, label)
    root_resolved = _resolve_directory(root, f"{label} root")
    candidate = root_resolved.joinpath(*relative.parts)
    _reject_symlink_components(root_resolved, candidate, label)
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as error:
        raise PathSafetyError(f"{label} does not exist: {value!r}") from error
    try:
        resolved.relative_to(root_resolved)
    except ValueError as error:
        raise PathSafetyError(f"{label} resolves outside its root: {value!r}") from error
    if not resolved.is_file():
        raise PathSafetyError(f"{label} is not a regular file: {value!r}")
    return resolved


def inspect_optional_file(root: Path, value: str, label: str) -> Path | None:
    relative = validate_relative_path(value, label)
    root_resolved = _resolve_directory(root, f"{label} root")
    candidate = root_resolved.joinpath(*relative.parts)
    _reject_symlink_components(root_resolved, candidate, label, allow_missing=True)
    if not candidate.exists():
        return None
    return resolve_regular_file(root_resolved, value, label)


def prepare_output_root(root: Path, label: str = "output root") -> Path:
    if root.is_symlink():
        raise PathSafetyError(f"{label} cannot be a symlink: {root}")
    root.mkdir(parents=True, exist_ok=True)
    return _resolve_directory(root, label)


def _resolve_directory(path: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise PathSafetyError(f"{label} does not exist: {path}") from error
    if not resolved.is_dir():
        raise PathSafetyError(f"{label} is not a directory: {path}")
    return resolved


def _reject_symlink_components(
    root: Path,
    candidate: Path,
    label: str,
    allow_missing: bool = False,
) -> None:
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise PathSafetyError(f"{label} escapes its declared root") from error
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise PathSafetyError(f"{label} contains a symlink component: {current}")
        if not current.exists():
            if allow_missing:
                return
            raise PathSafetyError(f"{label} does not exist: {current}")
