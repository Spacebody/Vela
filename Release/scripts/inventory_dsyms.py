#!/usr/bin/env python3
"""Bind every published Vela Mach-O UUID to exactly one retained dSYM."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


UUID_PATTERN = re.compile(
    r"^UUID: ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) \(([^)]+)\) .+$"
)
JSON_LIMIT = 4 * 1024 * 1024
DWARFDUMP = Path("/usr/bin/dwarfdump")
PRODUCT_SPECS = (
    (
        "Vela",
        PurePosixPath("Products/Applications/Vela.app/Contents/MacOS/Vela"),
    ),
    (
        "VelaHelper",
        PurePosixPath(
            "Products/Applications/Vela.app/Contents/Library/LaunchServices/VelaHelper"
        ),
    ),
)
CLI_SPEC = (
    "vela",
    PurePosixPath("Products/Applications/Vela.app/Contents/Helpers/vela"),
)


class InventoryError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(path: Path, *, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise InventoryError(f"{label} must be a regular non-symlink file: {path}")
    return path


def file_record(path: Path) -> dict[str, Any]:
    return {
        "filename": path.name,
        "size": path.stat().st_size,
        "sha256": sha256(path),
    }


def archive_tree_record(archive: Path) -> dict[str, Any]:
    """Digest every retained archive path so a sealed ZIP can prove tree equality."""
    rows: list[str] = []
    file_count = 0
    directory_count = 0
    total_size = 0
    for path in sorted(archive.rglob("*"), key=lambda value: value.relative_to(archive).as_posix()):
        relative = path.relative_to(archive).as_posix()
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise InventoryError(f"archive tree contains a symlink: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            directory_count += 1
            rows.append(f"directory\0{relative}\0\n")
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise InventoryError(f"archive tree contains a special file: {relative}")
        file_count += 1
        total_size += metadata.st_size
        rows.append(f"file\0{relative}\0{metadata.st_size}\0{sha256(path)}\n")
    if file_count == 0 or directory_count == 0:
        raise InventoryError("archive tree inventory is empty")
    digest = hashlib.sha256("".join(rows).encode("utf-8")).hexdigest()
    return {
        "fileCount": file_count,
        "directoryCount": directory_count,
        "totalSize": total_size,
        "sha256": digest,
    }


def write_immutable(path: Path, value: dict[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        raise InventoryError(f"refusing to overwrite immutable dSYM inventory: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise InventoryError(f"dSYM inventory output parent is unsafe: {path.parent}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise InventoryError(f"dSYM inventory appeared concurrently: {path}") from error
    finally:
        temporary.unlink(missing_ok=True)


def load_json(path: Path, *, label: str) -> dict[str, Any]:
    regular_file(path, label=label)
    if path.stat().st_size <= 0 or path.stat().st_size > JSON_LIMIT:
        raise InventoryError(f"{label} must be between 1 byte and {JSON_LIMIT} bytes")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InventoryError(f"invalid {label}: {error}") from error
    if not isinstance(value, dict):
        raise InventoryError(f"{label} must contain a JSON object")
    return value


def public_contract(path: Path) -> tuple[str, dict[str, Any]]:
    value = load_json(path, label="public contract")
    cli = value.get("cli")
    availability = cli.get("availability") if isinstance(cli, dict) else None
    absent_surfaces = value.get("absentSurfaces")
    identifiers = value.get("identifiers")
    cli_identifier = identifiers.get("cli") if isinstance(identifiers, dict) else None
    if availability == "absent":
        if (
            not isinstance(absent_surfaces, list)
            or "productionCLI" not in absent_surfaces
            or cli_identifier is not None
        ):
            raise InventoryError("public contract has an inconsistent absent CLI freeze")
    elif availability == "present":
        if (
            not isinstance(absent_surfaces, list)
            or "productionCLI" in absent_surfaces
            or not isinstance(cli_identifier, str)
            or not cli_identifier
        ):
            raise InventoryError("public contract has an inconsistent present CLI freeze")
    else:
        raise InventoryError("public contract CLI availability must be absent or present")
    return availability, file_record(path)


def macho_uuids(path: Path, *, label: str) -> list[dict[str, str]]:
    regular_file(path, label=label)
    try:
        output = subprocess.check_output(
            [str(DWARFDUMP), "--uuid", str(path)],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as error:
        raise InventoryError(f"dwarfdump failed for {label}") from error
    values: list[tuple[str, str]] = []
    for line in output.splitlines():
        match = UUID_PATTERN.fullmatch(line.strip())
        if match is not None:
            uuid = match.group(1).upper()
            architecture = match.group(2)
            if not architecture or any(character.isspace() for character in architecture):
                raise InventoryError(f"dwarfdump returned an unsafe architecture for {label}")
            values.append((uuid, architecture))
    if not values:
        raise InventoryError(f"dwarfdump returned no UUID for {label}")
    if len(values) != len(set(values)):
        raise InventoryError(f"dwarfdump returned duplicate UUID evidence for {label}")
    return [
        {"uuid": uuid, "architecture": architecture}
        for uuid, architecture in sorted(values)
    ]


def dSYM_records(archive: Path) -> list[dict[str, Any]]:
    dsym_root = archive / "dSYMs"
    if not dsym_root.is_dir() or dsym_root.is_symlink():
        raise InventoryError("archive is missing a regular dSYMs directory")
    records: list[dict[str, Any]] = []
    names: set[str] = set()
    for candidate in sorted(dsym_root.iterdir()):
        if candidate.suffix != ".dSYM":
            continue
        if not candidate.is_dir() or candidate.is_symlink():
            raise InventoryError(f"dSYM must be a regular non-symlink directory: {candidate}")
        dwarf_root = candidate / "Contents/Resources/DWARF"
        if not dwarf_root.is_dir() or dwarf_root.is_symlink():
            raise InventoryError(f"dSYM has no regular DWARF directory: {candidate.name}")
        dwarf_files = sorted(dwarf_root.iterdir())
        if not dwarf_files:
            raise InventoryError(f"dSYM has no DWARF binary: {candidate.name}")
        for dwarf in dwarf_files:
            regular_file(dwarf, label=f"{candidate.name} DWARF binary")
            if dwarf.name in names:
                raise InventoryError(f"duplicate dSYM DWARF name: {dwarf.name}")
            names.add(dwarf.name)
            records.append(
                {
                    "name": dwarf.name,
                    "dSYM": candidate.relative_to(archive).as_posix(),
                    "DWARF": dwarf.relative_to(archive).as_posix(),
                    "size": dwarf.stat().st_size,
                    "sha256": sha256(dwarf),
                    "uuids": macho_uuids(dwarf, label=f"{dwarf.name} dSYM"),
                }
            )
    if not records:
        raise InventoryError("archive contains no dSYM records")
    return records


def bind_product(
    archive: Path,
    *,
    name: str,
    relative_binary: PurePosixPath,
    records: list[dict[str, Any]],
) -> dict[str, Any]:
    binary = archive / Path(*relative_binary.parts)
    binary_uuids = macho_uuids(binary, label=f"published {name} binary")
    matching_records: set[str] = set()
    for value in binary_uuids:
        matches = [record for record in records if value in record["uuids"]]
        if len(matches) != 1:
            raise InventoryError(
                f"published {name} UUID {value['uuid']} ({value['architecture']}) must have "
                f"exactly one matching dSYM; found {len(matches)}"
            )
        matching_records.add(matches[0]["name"])
    if matching_records != {name}:
        raise InventoryError(f"published {name} UUIDs do not resolve to the {name} dSYM")
    debug = next(record for record in records if record["name"] == name)
    if debug["uuids"] != binary_uuids:
        raise InventoryError(f"published {name} and its dSYM do not contain the exact same UUIDs")
    return {
        "name": name,
        "binary": relative_binary.as_posix(),
        "size": binary.stat().st_size,
        "sha256": sha256(binary),
        "uuids": binary_uuids,
        "debugSymbols": debug,
    }


def build_inventory(
    archive: Path,
    *,
    cli_availability: str,
    contract_record: dict[str, Any],
    required: set[str],
) -> dict[str, Any]:
    if not archive.is_dir() or archive.is_symlink() or archive.name != "Vela.xcarchive":
        raise InventoryError(f"expected a regular Vela.xcarchive directory: {archive}")
    archive = archive.resolve(strict=True)
    records = dSYM_records(archive)
    record_names = {record["name"] for record in records}
    missing = sorted(required - record_names)
    if missing:
        raise InventoryError(f"archive is missing required dSYMs: {missing}")

    products = [
        bind_product(archive, name=name, relative_binary=path, records=records)
        for name, path in PRODUCT_SPECS
    ]
    cli_name, cli_relative = CLI_SPEC
    cli_binary = archive / Path(*cli_relative.parts)
    cli_exists = cli_binary.is_file() and not cli_binary.is_symlink()
    if cli_binary.is_symlink():
        raise InventoryError("published CLI binary may not be a symlink")
    if cli_availability == "absent":
        if cli_exists:
            raise InventoryError(
                "frozen public contract marks production CLI absent but archive contains one"
            )
        if cli_name in record_names:
            raise InventoryError("CLI is frozen absent but archive contains a synthetic CLI dSYM")
        cli = {"contractAvailability": "absent", "artifactPresence": "absent"}
    elif cli_availability == "present":
        if not cli_exists:
            raise InventoryError("public contract requires a production CLI but archive lacks it")
        products.append(
            bind_product(
                archive,
                name=cli_name,
                relative_binary=cli_relative,
                records=records,
            )
        )
        cli = {"contractAvailability": "present", "artifactPresence": "present"}
    else:
        raise InventoryError("unsupported CLI availability")

    product_debug_names = [product["debugSymbols"]["name"] for product in products]
    if len(product_debug_names) != len(set(product_debug_names)):
        raise InventoryError("more than one published binary resolves to the same dSYM")
    return {
        "schemaVersion": 3,
        "archiveName": archive.name,
        "archiveTree": archive_tree_record(archive),
        "publicContract": contract_record,
        "cli": cli,
        "products": products,
        "records": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bind published Vela Mach-O UUIDs to exact dSYMs in an xcarchive"
    )
    parser.add_argument("--archive", required=True)
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--output")
    destination.add_argument("--verify-receipt")
    parser.add_argument("--public-contract")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()

    try:
        archive = Path(args.archive)
        expected: dict[str, Any] | None = None
        if args.verify_receipt:
            expected = load_json(Path(args.verify_receipt), label="dSYM UUID receipt")
            if expected.get("schemaVersion") != 3:
                raise InventoryError("dSYM UUID receipt must use schemaVersion 3")

        if args.public_contract:
            cli_availability, contract_record = public_contract(Path(args.public_contract))
        elif expected is not None:
            cli = expected.get("cli")
            public_record = expected.get("publicContract")
            if not isinstance(cli, dict) or not isinstance(public_record, dict):
                raise InventoryError("dSYM UUID receipt lacks frozen CLI evidence")
            cli_availability = cli.get("contractAvailability")
            if cli_availability not in {"absent", "present"}:
                raise InventoryError("dSYM UUID receipt has invalid CLI availability")
            contract_record = public_record
        else:
            raise InventoryError("receipt generation requires --public-contract")

        inventory = build_inventory(
            archive,
            cli_availability=cli_availability,
            contract_record=contract_record,
            required=set(args.require),
        )
        serialized = json.dumps(inventory, sort_keys=True)
        if "/Users/" in serialized or "PRIVATE KEY" in serialized:
            raise InventoryError("dSYM UUID inventory contains private machine data")

        if expected is not None:
            if inventory != expected:
                raise InventoryError(
                    "published Mach-O or dSYM UUID binding differs from the retained receipt"
                )
            print(
                "dSYM UUID binding verified: "
                f"{len(inventory['products'])} published Mach-O binaries"
            )
        else:
            output = Path(args.output)
            write_immutable(output, inventory)
            print(
                f"dSYM UUID inventory written: {output} "
                f"({len(inventory['products'])} published Mach-O binaries)"
            )
        return 0
    except (OSError, subprocess.SubprocessError, InventoryError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
