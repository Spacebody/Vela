from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Release/scripts/inventory_dsyms.py"
CONTAINER_SCRIPT = ROOT / "Release/scripts/verify_archive_container.py"


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


class UUIDInventoryFixture:
    def __init__(self, root: Path, *, cli: bool = False) -> None:
        self.root = root
        self.archive = root / "Vela.xcarchive"
        self.contract = root / "public-contract-freeze.json"
        self.receipt = root / "dsym-inventory.json"
        self.install("Products/Applications/Vela.app/Contents/MacOS/Vela", "/usr/bin/true")
        self.install(
            "Products/Applications/Vela.app/Contents/Library/LaunchServices/VelaHelper",
            "/bin/ls",
        )
        self.install(
            "dSYMs/Vela.app.dSYM/Contents/Resources/DWARF/Vela",
            "/usr/bin/true",
        )
        self.install(
            "dSYMs/VelaHelper.dSYM/Contents/Resources/DWARF/VelaHelper",
            "/bin/ls",
        )
        if cli:
            self.install(
                "Products/Applications/Vela.app/Contents/Helpers/vela",
                "/usr/bin/false",
            )
            self.install(
                "dSYMs/vela.dSYM/Contents/Resources/DWARF/vela",
                "/usr/bin/false",
            )
        self.write_contract(present=cli)

    def install(self, relative: str, source: str) -> Path:
        destination = self.archive / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(Path(source).read_bytes())
        return destination

    def write_contract(self, *, present: bool) -> None:
        write_json(
            self.contract,
            {
                "absentSurfaces": [] if present else ["productionCLI"],
                "cli": {"availability": "present" if present else "absent"},
                "identifiers": {"cli": "dev.yilin.Vela.CLI" if present else None},
            },
        )

    def run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        poison = self.root / "poison-path"
        poison.mkdir(exist_ok=True)
        fake = poison / "dwarfdump"
        fake.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
        fake.chmod(0o700)
        environment = {**os.environ, "PATH": f"{poison}:{os.environ['PATH']}"}
        return subprocess.run(
            (sys.executable, str(SCRIPT), "--archive", str(self.archive), *arguments),
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )

    def generate(self) -> subprocess.CompletedProcess[str]:
        return self.run(
            "--output",
            str(self.receipt),
            "--public-contract",
            str(self.contract),
        )

    def verify(self) -> subprocess.CompletedProcess[str]:
        return self.run(
            "--verify-receipt",
            str(self.receipt),
            "--public-contract",
            str(self.contract),
        )

    def seal(self, destination: Path) -> None:
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(self.archive.rglob("*")):
                archive.write(path, arcname=path.relative_to(self.archive.parent).as_posix())

    def verify_container(self, container: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            (
                sys.executable,
                str(CONTAINER_SCRIPT),
                "--archive-zip",
                str(container),
                "--live-archive",
                str(self.archive),
                "--receipt",
                str(self.receipt),
                "--public-contract",
                str(self.contract),
                "--require",
                "Vela",
                "--require",
                "VelaHelper",
            ),
            cwd=ROOT,
            text=True,
            capture_output=True,
        )


class InventoryDSYMTests(unittest.TestCase):
    def test_absent_cli_is_frozen_fact_and_receipt_revalidates(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            generated = fixture.generate()
            self.assertEqual(generated.returncode, 0, generated.stderr)
            value = json.loads(fixture.receipt.read_text(encoding="utf-8"))
            self.assertEqual(value["schemaVersion"], 3)
            self.assertGreater(value["archiveTree"]["fileCount"], 0)
            self.assertGreater(value["archiveTree"]["directoryCount"], 0)
            self.assertRegex(value["archiveTree"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(value["cli"], {
                "contractAvailability": "absent",
                "artifactPresence": "absent",
            })
            self.assertEqual([item["name"] for item in value["products"]], ["Vela", "VelaHelper"])
            verified = fixture.verify()
            self.assertEqual(verified.returncode, 0, verified.stderr)
            self.assertIn("2 published Mach-O binaries", verified.stdout)

    def test_present_cli_is_bound_only_when_contract_and_artifact_exist(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw), cli=True)
            generated = fixture.generate()
            self.assertEqual(generated.returncode, 0, generated.stderr)
            value = json.loads(fixture.receipt.read_text(encoding="utf-8"))
            self.assertEqual([item["name"] for item in value["products"]], [
                "Vela", "VelaHelper", "vela"
            ])
            self.assertEqual(value["cli"]["artifactPresence"], "present")

    def test_binary_uuid_mismatch_and_duplicate_dsym_owner_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            fixture.install(
                "dSYMs/VelaHelper.dSYM/Contents/Resources/DWARF/VelaHelper",
                "/usr/bin/false",
            )
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one matching dSYM", result.stderr)

        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            fixture.install(
                "dSYMs/Copy.dSYM/Contents/Resources/DWARF/Copy",
                "/usr/bin/true",
            )
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one matching dSYM", result.stderr)

    def test_absent_cli_rejects_binary_or_synthetic_dsym(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            fixture.install(
                "Products/Applications/Vela.app/Contents/Helpers/vela",
                "/usr/bin/false",
            )
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contract marks production CLI absent", result.stderr)

        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            fixture.install(
                "dSYMs/vela.dSYM/Contents/Resources/DWARF/vela",
                "/usr/bin/false",
            )
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("synthetic CLI dSYM", result.stderr)

    def test_receipt_revalidation_rejects_published_binary_tamper(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            self.assertEqual(fixture.generate().returncode, 0)
            fixture.install(
                "Products/Applications/Vela.app/Contents/MacOS/Vela",
                "/usr/bin/false",
            )
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one matching dSYM", result.stderr)

    def test_full_archive_tree_tamper_is_bound_even_outside_published_binaries(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = UUIDInventoryFixture(Path(raw))
            self.assertEqual(fixture.generate().returncode, 0)
            metadata = fixture.archive / "Info.plist"
            metadata.write_bytes(b"changed after receipt\n")
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from the retained receipt", result.stderr)

    def test_sealed_zip_replays_exact_tree_and_rejects_changed_or_unsafe_members(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            fixture = UUIDInventoryFixture(root)
            self.assertEqual(fixture.generate().returncode, 0)
            container = root / "Vela.xcarchive.zip"
            fixture.seal(container)
            verified = fixture.verify_container(container)
            self.assertEqual(verified.returncode, 0, verified.stderr)

            container.unlink()
            (fixture.archive / "unexpected.txt").write_text("not in receipt\n", encoding="utf-8")
            fixture.seal(container)
            changed = fixture.verify_container(container)
            self.assertNotEqual(changed.returncode, 0)
            self.assertIn("differs from the retained receipt", changed.stderr)

            (fixture.archive / "unexpected.txt").unlink()
            unsafe = root / "unsafe.xcarchive.zip"
            link = zipfile.ZipInfo("Vela.xcarchive/escape")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(unsafe, "w") as archive:
                archive.writestr(link, "../../outside")
            rejected = fixture.verify_container(unsafe)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("symbolic link", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
