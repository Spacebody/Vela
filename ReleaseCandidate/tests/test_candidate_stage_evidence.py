from __future__ import annotations

import base64
import copy
import hashlib
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
SCRIPTS = ROOT / "ReleaseCandidate/scripts"
VERSION = "1.0.0-rc.1"
BUILD = 2026071501
TAG = f"v{VERSION}"
APP_NOTARY_ID = "11111111-2222-3333-8444-555555555555"
DMG_NOTARY_ID = "66666666-7777-4888-9999-aaaaaaaaaaaa"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(
    script: str,
    *arguments: str,
    environment_overrides: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment.update(environment_overrides or {})
    return subprocess.run(
        (sys.executable, str(SCRIPTS / script), *arguments),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
    )


class CandidateStageFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.repository = root / "repository"
        self.evidence = root / "candidate-evidence"
        self.repository.mkdir()
        self.evidence.mkdir()
        (self.evidence / "private/notary").mkdir(parents=True, mode=0o700)
        (self.evidence / "private/tools").mkdir(mode=0o700)
        (self.evidence / "public/updates").mkdir(parents=True)

        subprocess.run(("git", "init", "-q", str(self.repository)), check=True)
        subprocess.run(
            ("git", "-C", str(self.repository), "config", "user.name", "Vela Test"),
            check=True,
        )
        subprocess.run(
            (
                "git",
                "-C",
                str(self.repository),
                "config",
                "user.email",
                "vela-test@example.invalid",
            ),
            check=True,
        )
        (self.repository / "seed.txt").write_text("candidate source\n", encoding="utf-8")
        verifier = self.repository / "Release/scripts/verify_signed_appcast_artifacts.py"
        verifier.parent.mkdir(parents=True)
        verifier.write_bytes(
            (ROOT / "Release/scripts/verify_signed_appcast_artifacts.py").read_bytes()
        )
        inventory_tool = self.repository / "Release/scripts/inventory_dsyms.py"
        inventory_tool.write_bytes((ROOT / "Release/scripts/inventory_dsyms.py").read_bytes())
        archive_verifier = self.repository / "Release/scripts/verify_archive_container.py"
        archive_verifier.write_bytes(
            (ROOT / "Release/scripts/verify_archive_container.py").read_bytes()
        )
        contract = self.repository / "Contracts/v1/public-contract-freeze.json"
        write_json(
            contract,
            {
                "absentSurfaces": ["productionCLI"],
                "cli": {"availability": "absent"},
                "identifiers": {"cli": None},
            },
        )
        subprocess.run(("git", "-C", str(self.repository), "add", "."), check=True)
        subprocess.run(
            ("git", "-C", str(self.repository), "commit", "-q", "-m", "candidate"),
            check=True,
        )
        subprocess.run(
            ("git", "-C", str(self.repository), "tag", "-a", TAG, "-m", "candidate"),
            check=True,
        )
        self.commit = subprocess.check_output(
            ("git", "-C", str(self.repository), "rev-parse", "HEAD"),
            text=True,
        ).strip()

        self.architecture = self.evidence / "public/architecture-freeze.json"
        write_json(
            self.architecture,
            {"schemaVersion": 1, "version": "1.0.0", "status": "frozen"},
        )
        self.dmg = self.evidence / f"public/updates/Vela-{VERSION}-arm64.dmg"
        self.dmg.write_bytes(b"fixture notarized DMG bytes\n")
        self.release_notes = self.evidence / f"public/updates/release-notes-{VERSION}.html"
        self.release_notes.write_text(
            "<html><body><h1>Vela RC 1</h1><p>Signed release notes.</p></body></html>\n",
            encoding="utf-8",
        )
        signature = base64.b64encode(bytes(range(1, 65))).decode("ascii")
        self.appcast = self.evidence / "public/updates/appcast.xml"
        self.appcast.write_text(
            (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
                "  <channel>\n"
                "    <item>\n"
                f"      <sparkle:version>{BUILD}</sparkle:version>\n"
                f'      <sparkle:releaseNotesLink sparkle:edSignature="{signature}" '
                f'sparkle:length="{self.release_notes.stat().st_size}">'
                f"https://updates.example.invalid/{self.release_notes.name}"
                "</sparkle:releaseNotesLink>\n"
                f'      <enclosure url="https://updates.example.invalid/{self.dmg.name}" '
                f'length="{self.dmg.stat().st_size}" sparkle:edSignature="{signature}" />\n'
                "    </item>\n"
                "  </channel>\n"
                "</rss>\n"
            ),
            encoding="utf-8",
        )
        self.sbom = self.evidence / f"public/Vela-{VERSION}.spdx.json"
        write_json(
            self.sbom,
            {
                "spdxVersion": "SPDX-2.3",
                "SPDXID": "SPDXRef-DOCUMENT",
                "name": f"Vela-{VERSION}",
            },
        )
        self.updates_checksums = self.evidence / "public/updates-checksums.txt"
        self.write_updates_checksums()

        self.sign_update = self.evidence / "private/tools/sign_update"
        self.sign_update.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.sign_update.chmod(0o700)
        self.sparkle_key = self.evidence / "private/tools/sparkle-test-key"
        self.sparkle_key.write_bytes(b"test-only Sparkle verification key\n")
        self.app_archive = (
            self.evidence / f"private/Vela-{VERSION}-{BUILD}-app-notary.zip"
        )
        self.app_archive.write_bytes(b"sealed notarization App ZIP bytes\n")
        self.archive_container = (
            self.evidence / f"private/Vela-{VERSION}-{BUILD}.xcarchive.zip"
        )
        self.certificate_sha256 = digest(b"Developer ID Application certificate")

        self.app_notary = self.evidence / "private/notary/notary-app-result.json"
        self.dmg_notary = self.evidence / "private/notary/notary-dmg-result.json"
        write_json(self.app_notary, {"id": APP_NOTARY_ID, "status": "Accepted"})
        write_json(self.dmg_notary, {"id": DMG_NOTARY_ID, "status": "Accepted"})

        self.app_receipt = self.evidence / f"private/release-manifest-{VERSION}.json"
        write_json(
            self.app_receipt,
            {
                "schemaVersion": 1,
                "manifestKind": "external",
                "app": {
                    "name": "Vela",
                    "version": "1.0.0",
                    "build": BUILD,
                    "channel": "beta",
                    "prereleaseLabel": "RC 1",
                    "bundleIdentifier": "dev.yilin.Vela",
                },
                "appBundle": {"name": "Vela.app"},
                "build": {"sourceDirty": False, "buildID": "fixture"},
                "source": {
                    "tag": TAG,
                    "commit": self.commit,
                    "architectureFreezeSHA256": digest(self.architecture.read_bytes()),
                },
                "artifacts": {
                    "appZip": {
                        "filename": self.app_archive.name,
                        "size": self.app_archive.stat().st_size,
                        "sha256": digest(self.app_archive.read_bytes()),
                    },
                    "dmg": {
                        "filename": self.dmg.name,
                        "size": self.dmg.stat().st_size,
                        "sha256": digest(self.dmg.read_bytes()),
                    },
                    "appcast": {
                        "filename": self.appcast.name,
                        "size": self.appcast.stat().st_size,
                        "sha256": digest(self.appcast.read_bytes()),
                    }
                },
                "trust": {"signingCertificateSHA256": self.certificate_sha256},
                "notarization": {
                    "app": {"submissionID": APP_NOTARY_ID, "status": "Accepted"},
                    "dmg": {"submissionID": DMG_NOTARY_ID, "status": "Accepted"},
                },
            },
        )
        self.archive_directory = self.evidence / "build/Vela.xcarchive"
        archive_files = {
            "Products/Applications/Vela.app/Contents/MacOS/Vela": Path("/usr/bin/true"),
            (
                "Products/Applications/Vela.app/Contents/Library/LaunchServices/"
                "VelaHelper"
            ): Path("/bin/ls"),
            "dSYMs/Vela.app.dSYM/Contents/Resources/DWARF/Vela": Path("/usr/bin/true"),
            (
                "dSYMs/VelaHelper.dSYM/Contents/Resources/DWARF/VelaHelper"
            ): Path("/bin/ls"),
        }
        for relative, source in archive_files.items():
            path = self.archive_directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(source.read_bytes())
        self.environment: dict[str, str] = {}
        self.archive_receipt = self.evidence / "private/dsym-inventory.json"
        generated_inventory = subprocess.run(
            (
                sys.executable,
                str(inventory_tool),
                "--archive",
                str(self.archive_directory),
                "--output",
                str(self.archive_receipt),
                "--public-contract",
                str(contract),
            ),
            env={**os.environ, **self.environment},
            text=True,
            capture_output=True,
        )
        if generated_inventory.returncode != 0:
            raise RuntimeError(generated_inventory.stderr)
        self.seal_archive(self.archive_container)
        self.manifest = self.evidence / f"private/candidate-stage-{VERSION}.json"

    def seal_archive(self, destination: Path) -> None:
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(self.archive_directory.rglob("*")):
                archive.write(
                    path,
                    arcname=path.relative_to(self.archive_directory.parent).as_posix(),
                )

    def write_updates_checksums(self) -> None:
        rows = []
        for path in sorted((self.evidence / "public/updates").iterdir()):
            rows.append(f"{digest(path.read_bytes())}  {path.name}\n")
        self.updates_checksums.write_text("".join(rows), encoding="utf-8")

    def generator_arguments(self, *, output: Path | None = None) -> tuple[str, ...]:
        return (
            "--repository-root",
            str(self.repository),
            "--evidence-root",
            str(self.evidence),
            "--candidate-version",
            VERSION,
            "--build",
            str(BUILD),
            "--tag",
            TAG,
            "--commit",
            self.commit,
            "--architecture-freeze",
            str(self.architecture),
            "--dmg",
            str(self.dmg),
            "--app-archive",
            str(self.app_archive),
            "--archive-container",
            str(self.archive_container),
            "--appcast",
            str(self.appcast),
            "--sbom",
            str(self.sbom),
            "--signed-release-notes",
            str(self.release_notes),
            "--updates-root",
            str(self.evidence / "public/updates"),
            "--updates-checksums",
            str(self.updates_checksums),
            "--app-receipt",
            str(self.app_receipt),
            "--archive-receipt",
            str(self.archive_receipt),
            "--archive-directory",
            str(self.archive_directory),
            "--app-notary-receipt",
            str(self.app_notary),
            "--dmg-notary-receipt",
            str(self.dmg_notary),
            "--sparkle-sign-update",
            str(self.sign_update),
            "--sparkle-ed-key-file",
            str(self.sparkle_key),
            "--signing-certificate-sha256",
            self.certificate_sha256,
            "--output",
            str(output or self.manifest),
        )

    def generate(self) -> subprocess.CompletedProcess[str]:
        return run(
            "generate_candidate_stage_evidence.py",
            *self.generator_arguments(),
            environment_overrides=self.environment,
        )

    def verify(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return run(
            "validate_candidate_stage_evidence.py",
            str(self.manifest),
            "--evidence-root",
            str(self.evidence),
            "--verify-files",
            *extra,
            environment_overrides=self.environment,
        )


class CandidateStageEvidenceTests(unittest.TestCase):
    def with_fixture(self) -> tuple[tempfile.TemporaryDirectory[str], CandidateStageFixture]:
        temporary = tempfile.TemporaryDirectory()
        return temporary, CandidateStageFixture(Path(temporary.name))

    def test_generate_and_promotion_verify_bind_exact_private_candidate(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            generated = fixture.generate()
            self.assertEqual(generated.returncode, 0, generated.stderr)
            mode = stat.S_IMODE(fixture.manifest.stat().st_mode)
            self.assertEqual(mode & 0o077, 0)
            value = json.loads(fixture.manifest.read_text(encoding="utf-8"))
            self.assertEqual(value["visibility"], "private")
            self.assertEqual(value["stage"]["decision"], "noGo")
            self.assertEqual(value["stage"]["promotionStatus"], "pending")
            self.assertEqual(value["candidate"]["commit"], fixture.commit)
            self.assertEqual(value["artifacts"]["dmg"]["filename"], fixture.dmg.name)
            self.assertEqual(
                value["artifacts"]["appArchive"]["filename"],
                fixture.app_archive.name,
            )
            self.assertEqual(
                value["artifacts"]["archiveContainer"]["sha256"],
                digest(fixture.archive_container.read_bytes()),
            )
            self.assertEqual(value["artifacts"]["appcast"]["filename"], "appcast.xml")
            self.assertEqual(value["artifacts"]["sbom"]["filename"], fixture.sbom.name)
            self.assertEqual(
                value["artifacts"]["signedReleaseNotes"]["filename"],
                fixture.release_notes.name,
            )
            self.assertEqual(len(value["artifacts"]["updatesSubjects"]), 3)
            self.assertEqual(
                value["signing"]["sparkleVerification"],
                {
                    "status": "verified",
                    "toolVersion": "verify_signed_appcast_artifacts.py/1",
                    "appcastSHA256": digest(fixture.appcast.read_bytes()),
                },
            )
            serialized = fixture.manifest.read_text(encoding="utf-8")
            self.assertNotIn(str(fixture.sparkle_key), serialized)
            self.assertNotIn(fixture.sparkle_key.name, serialized)

            verified = fixture.verify(
                "--candidate-version",
                VERSION,
                "--build",
                str(BUILD),
                "--tag",
                TAG,
                "--commit",
                fixture.commit,
                "--architecture-sha256",
                digest(fixture.architecture.read_bytes()),
            )
            self.assertEqual(verified.returncode, 0, verified.stderr)
            self.assertIn("decision remains No-Go, promotion pending", verified.stdout)

    def test_promotion_rejects_changed_candidate_bytes(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            original = fixture.dmg.read_bytes()
            fixture.dmg.write_bytes(bytes([original[0] ^ 0x01]) + original[1:])
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            fixture.archive_container.write_bytes(b"tampered complete archive\n")
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive container bytes differ", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            fixture.app_archive.write_bytes(b"tampered App archive\n")
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("App archive bytes differ", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            binary = (
                fixture.archive_directory
                / "Products/Applications/Vela.app/Contents/MacOS/Vela"
            )
            binary.write_bytes(Path("/usr/bin/false").read_bytes())
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Mach-O/dSYM UUID binding verification failed", result.stderr)

    def test_archive_container_must_be_a_replayable_exact_xcarchive_zip(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.archive_container.write_bytes(b"not an xcarchive ZIP\n")
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sealed xcarchive replay verification failed", result.stderr)
            self.assertIn("invalid xcarchive ZIP", result.stderr)

    def test_archive_receipt_requires_strict_schema_v3_tree_binding(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            original = json.loads(fixture.archive_receipt.read_text(encoding="utf-8"))
            mutations = {
                "legacy-schema": lambda value: value.__setitem__("schemaVersion", 2),
                "missing-tree": lambda value: value.pop("archiveTree"),
                "boolean-count": lambda value: value["archiveTree"].__setitem__(
                    "fileCount", True
                ),
                "empty-size": lambda value: value["archiveTree"].__setitem__(
                    "totalSize", 0
                ),
                "unknown-field": lambda value: value["archiveTree"].__setitem__(
                    "unexpected", 1
                ),
            }
            for label, mutate in mutations.items():
                with self.subTest(case=label):
                    value = copy.deepcopy(original)
                    mutate(value)
                    write_json(fixture.archive_receipt, value)
                    result = fixture.generate()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("archive receipt", result.stderr)
            self.assertFalse(fixture.manifest.exists())

        temporary, fixture = self.with_fixture()
        with temporary:
            unexpected = fixture.archive_directory / "unexpected-after-receipt.txt"
            unexpected.write_text("not retained by the receipt\n", encoding="utf-8")
            fixture.seal_archive(fixture.archive_container)
            unexpected.unlink()
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sealed xcarchive replay verification failed", result.stderr)
            self.assertIn("differs from the retained receipt", result.stderr)
            self.assertFalse(fixture.manifest.exists())

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            fixture.archive_container.write_bytes(b"corrupt promoted ZIP\n")
            value = json.loads(fixture.manifest.read_text(encoding="utf-8"))
            archive_record = value["artifacts"]["archiveContainer"]
            archive_record["size"] = fixture.archive_container.stat().st_size
            archive_record["sha256"] = digest(fixture.archive_container.read_bytes())
            write_json(fixture.manifest, value)
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sealed xcarchive replay verification failed", result.stderr)
            self.assertIn("invalid xcarchive ZIP", result.stderr)

    def test_generator_and_promotion_reject_symlinks(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            architecture_target = fixture.evidence / "public/architecture-target.json"
            fixture.architecture.rename(architecture_target)
            fixture.architecture.symlink_to(architecture_target)
            generated = fixture.generate()
            self.assertNotEqual(generated.returncode, 0)
            self.assertIn("symlink", generated.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            receipt_target = fixture.evidence / "private/archive-target.json"
            fixture.archive_receipt.rename(receipt_target)
            fixture.archive_receipt.symlink_to(receipt_target)
            verified = fixture.verify()
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("symlink", verified.stderr)

    def test_generator_rejects_public_manifest_output_and_path_escape(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            public_output = fixture.evidence / "public/candidate-stage.json"
            result = run(
                "generate_candidate_stage_evidence.py",
                *fixture.generator_arguments(output=public_output),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("evidence-root/private", result.stderr)

            escaped = fixture.root / "outside.json"
            escaped.write_text("{}\n", encoding="utf-8")
            arguments = list(fixture.generator_arguments())
            index = arguments.index("--archive-receipt") + 1
            arguments[index] = str(escaped)
            result = run("generate_candidate_stage_evidence.py", *arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes the candidate evidence root", result.stderr)

    def test_generator_rejects_placeholder_receipt_and_nonaccepted_notary(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            app = json.loads(fixture.app_receipt.read_text(encoding="utf-8"))
            app["operatorNote"] = "TODO"
            write_json(fixture.app_receipt, app)
            placeholder = fixture.generate()
            self.assertNotEqual(placeholder.returncode, 0)
            self.assertIn("placeholder", placeholder.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            write_json(fixture.dmg_notary, {"id": DMG_NOTARY_ID, "status": "In Progress"})
            not_accepted = fixture.generate()
            self.assertNotEqual(not_accepted.returncode, 0)
            self.assertIn("not Accepted", not_accepted.stderr)

    def test_app_receipt_must_bind_certificate_and_exact_dmg(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            app = json.loads(fixture.app_receipt.read_text(encoding="utf-8"))
            app["trust"]["signingCertificateSHA256"] = digest(b"other certificate")
            write_json(fixture.app_receipt, app)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signing certificate differs", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            app = json.loads(fixture.app_receipt.read_text(encoding="utf-8"))
            app["artifacts"]["dmg"]["sha256"] = digest(b"other DMG")
            write_json(fixture.app_receipt, app)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("DMG bytes differ", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            app = json.loads(fixture.app_receipt.read_text(encoding="utf-8"))
            app["artifacts"]["appcast"]["sha256"] = digest(b"other appcast")
            write_json(fixture.app_receipt, app)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("appcast bytes differ", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            app = json.loads(fixture.app_receipt.read_text(encoding="utf-8"))
            app["artifacts"]["appZip"]["sha256"] = digest(b"other App archive")
            write_json(fixture.app_receipt, app)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("App archive bytes differ", result.stderr)

    def test_generator_invokes_real_sparkle_verifier_and_rejects_failed_signature(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.sign_update.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            fixture.sign_update.chmod(0o700)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signed appcast artifact verification failed", result.stderr)
            self.assertFalse(fixture.manifest.exists())

    def test_candidate_appcast_and_spdx_bind_the_declared_artifacts(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            decoy = fixture.evidence / "public/updates/decoy-notes.html"
            decoy.write_text("<p>Unsigned decoy notes.</p>\n", encoding="utf-8")
            fixture.write_updates_checksums()
            arguments = list(fixture.generator_arguments())
            index = arguments.index("--signed-release-notes") + 1
            arguments[index] = str(decoy)
            result = run("generate_candidate_stage_evidence.py", *arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not reference the exact signed release notes", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            sbom = json.loads(fixture.sbom.read_text(encoding="utf-8"))
            sbom["spdxVersion"] = "SPDX-2.2"
            write_json(fixture.sbom, sbom)
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SPDX-2.3", result.stderr)

    def test_nested_symlink_paths_are_rejected(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            alias = fixture.evidence / "public/updates-alias"
            alias.symlink_to(fixture.evidence / "public/updates", target_is_directory=True)
            arguments = list(fixture.generator_arguments())
            index = arguments.index("--appcast") + 1
            arguments[index] = str(alias / "appcast.xml")
            result = run("generate_candidate_stage_evidence.py", *arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)

    def test_updates_checksum_inventory_is_complete_sorted_and_exact(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            rows = fixture.updates_checksums.read_text(encoding="utf-8").splitlines()
            fixture.updates_checksums.write_text("\n".join(rows[1:]) + "\n", encoding="utf-8")
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("incomplete or stale", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            rows = fixture.updates_checksums.read_text(encoding="utf-8").splitlines()
            fixture.updates_checksums.write_text("\n".join(reversed(rows)) + "\n", encoding="utf-8")
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be sorted", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            rows = fixture.updates_checksums.read_text(encoding="utf-8").splitlines()
            pieces = rows[0].split("  ", 1)
            rows[0] = f"{digest(b'wrong bytes')}  {pieces[1]}"
            fixture.updates_checksums.write_text("\n".join(rows) + "\n", encoding="utf-8")
            result = fixture.generate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from exact artifact bytes", result.stderr)

    def test_promotion_rejects_uninventoried_update_and_forged_sparkle_receipt(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            (fixture.evidence / "public/updates/unlisted.bin").write_bytes(b"new bytes\n")
            result = fixture.verify()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("complete inventory", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            value = json.loads(fixture.manifest.read_text(encoding="utf-8"))
            value["signing"]["sparkleVerification"]["appcastSHA256"] = digest(
                b"different appcast"
            )
            forged = fixture.evidence / "private/forged-sparkle-receipt.json"
            write_json(forged, value)
            forged.chmod(0o600)
            result = run("validate_candidate_stage_evidence.py", str(forged))
            self.assertNotEqual(result.returncode, 0)

    def test_manifest_cannot_claim_go_or_promoted_and_expected_identity_is_strict(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            self.assertEqual(fixture.generate().returncode, 0)
            mismatch = fixture.verify("--build", "2026071502")
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("expected promotion identity", mismatch.stderr)

            value = json.loads(fixture.manifest.read_text(encoding="utf-8"))
            value["stage"]["decision"] = "go"
            value["stage"]["promotionStatus"] = "promoted"
            forged = fixture.evidence / "private/forged-candidate-stage.json"
            write_json(forged, value)
            forged.chmod(0o600)
            result = run("validate_candidate_stage_evidence.py", str(forged))
            self.assertNotEqual(result.returncode, 0)

    def test_release_pipeline_uses_the_complete_two_phase_cli_contract(self) -> None:
        release = (ROOT / "Release/scripts/release.sh").read_text(encoding="utf-8")
        preflight = (ROOT / "ReleaseCandidate/scripts/preflight.sh").read_text(
            encoding="utf-8"
        )
        start = release.index("generate_candidate_stage_evidence.py")
        end = release.index("validate_candidate_stage_evidence.py", start)
        generator = release[start:end]
        required_arguments = {
            "--repository-root",
            "--evidence-root",
            "--candidate-version",
            "--build",
            "--tag",
            "--commit",
            "--architecture-freeze",
            "--dmg",
            "--app-archive",
            "--archive-container",
            "--appcast",
            "--sbom",
            "--signed-release-notes",
            "--updates-root",
            "--updates-checksums",
            "--app-receipt",
            "--archive-receipt",
            "--archive-directory",
            "--app-notary-receipt",
            "--dmg-notary-receipt",
            "--sparkle-sign-update",
            "--sparkle-ed-key-file",
            "--signing-certificate-sha256",
            "--output",
        }
        for argument in required_arguments:
            self.assertIn(argument, generator)
        self.assertIn(
            '--output "${STAGE}/private/candidate-stage-evidence.json"', generator
        )
        self.assertIn('--updates-root "updates"', generator)

        promotion = release[release.index("else\n  /bin/mkdir -p", end) :]
        self.assertNotIn(
            'find -P "${CANDIDATE_STAGE_PATH}" -type l',
            promotion,
        )
        self.assertIn(
            '"${STAGE}/private/candidate-stage-evidence.json"', promotion
        )
        for argument in (
            "--evidence-root",
            "--verify-files",
            "--candidate-version",
            "--build",
            "--tag",
            "--commit",
            "--architecture-sha256",
        ):
            self.assertIn(argument, promotion)

        self.assertIn('if [[ "${PHASE}" == "candidate-stage" ]]', preflight)
        self.assertIn('if [[ "${PHASE}" == "candidate-stage" ]]; then', preflight)
        self.assertIn("--promotion --candidate-stage-path", release)
        self.assertIn(
            '"${CANDIDATE_STAGE_PATH}/private/candidate-stage-evidence.json"',
            preflight,
        )
        self.assertIn("--architecture-sha256", preflight)


if __name__ == "__main__":
    unittest.main()
