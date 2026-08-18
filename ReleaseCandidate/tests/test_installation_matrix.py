from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RC = ROOT / "ReleaseCandidate"
SCRIPT = RC / "scripts/validate_installation_matrix.py"
BASE_PATH = RC / "config/installation-matrix.json"
CONTRACT_PATH = ROOT / "Contracts/v1/public-contract-freeze.json"

VERSION = "1.0.0-rc.1"
BUILD = 2026071501
COMMIT = "a" * 40
ARTIFACT_NAME = f"Vela-{VERSION}-arm64.dmg"

EXPECTED_CASES = (
    "clean.standard.no-old-data",
    "clean.admin.no-old-data",
    "clean.old-data-only",
    "clean.helper-absent",
    "clean.helper-registered",
    "clean.cli-absent",
    "clean.cli-broken",
    "clean.factory-core",
    "clean.no-configuration",
    "clean.local-configuration",
    "clean.remote-configuration",
    "clean.applications-location",
    "clean.downloads-translocated",
    "clean.read-only-dmg",
    "upgrade.fixture-v0.1",
    "upgrade.fixture-v0.2",
    "upgrade.fixture-v0.3",
    "upgrade.fixture-v0.4",
    "upgrade.fixture-v0.5",
    "upgrade.fixture-v0.6",
    "upgrade.fixture-v0.7",
    "upgrade.fixture-v0.8",
    "upgrade.stable-to-rc",
    "upgrade.beta-to-rc",
    "upgrade.rc1-to-rc2",
    "upgrade.rc-to-1.0",
    "upgrade.tun-off",
    "upgrade.tun-on",
    "upgrade.system-proxy-on",
    "upgrade.helper-old",
    "upgrade.helper-current",
    "upgrade.cli-old",
    "upgrade.cli-current",
    "upgrade.external-core-active",
    "upgrade.blocked-core",
    "upgrade.automatic-scenes",
    "upgrade.incomplete-journals",
    "upgrade.low-disk",
    "upgrade.sparkle-offline",
    "repair.helper-reinstall",
    "repair.cli",
    "repair.support-bundle",
    "repair.safe-mode",
    "repair.profile-restore",
    "repair.update-journal",
    "repair.factory-core-fallback",
    "repair.data-export",
    "uninstall.tun-stop-cleanup",
    "uninstall.helper-unregister",
    "uninstall.cli-symlink-removal",
    "uninstall.optional-user-data-removal",
    "uninstall.no-unknown-process-network-deletion",
    "uninstall.retained-data-policy",
    "downgrade.no-silent-downgrade",
    "downgrade.manual-previous-stable-schema-guard",
    "downgrade.backup-export-instructions",
    "downgrade.helper-core-compatibility-warning",
    "downgrade.no-write-compatibility-promise",
)

EXPECTED_BLOCKED = {
    "clean.cli-absent",
    "clean.cli-broken",
    "upgrade.cli-old",
    "upgrade.cli-current",
    "upgrade.automatic-scenes",
    "repair.cli",
    "uninstall.cli-symlink-removal",
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_matrix(path: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(
        (sys.executable, str(SCRIPT), str(path), *arguments),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
    )


def bind_candidate(value: dict) -> None:
    value["candidate"] = {
        "version": VERSION,
        "build": BUILD,
        "commit": COMMIT,
        "artifact": None,
    }


def expected_identity_arguments() -> tuple[str, ...]:
    return (
        "--candidate-version",
        VERSION,
        "--build",
        str(BUILD),
        "--commit",
        COMMIT,
    )


def make_present_contract(directory: Path) -> Path:
    contract = load(CONTRACT_PATH)
    implemented = {
        "productionCLI",
        "productionSceneStore",
        "productionAutomationSocket",
    }
    contract["absentSurfaces"] = [
        surface for surface in contract["absentSurfaces"] if surface not in implemented
    ]
    path = directory / "public-contract-present.json"
    write(path, contract)
    return path


def make_final_packet(directory: Path) -> dict[str, Path | dict]:
    evidence_root = directory / "evidence"
    artifacts_dir = directory / "artifacts"
    evidence_file = evidence_root / "lab/install-matrix-result.json"
    artifact_file = artifacts_dir / ARTIFACT_NAME
    evidence_file.parent.mkdir(parents=True)
    artifacts_dir.mkdir()

    evidence_bytes = b"candidate-bound installation matrix evidence\n"
    artifact_bytes = b"signed and notarized DMG fixture bytes\n"
    evidence_file.write_bytes(evidence_bytes)
    artifact_file.write_bytes(artifact_bytes)

    value = load(BASE_PATH)
    bind_candidate(value)
    value["candidate"]["artifact"] = {
        "kind": "dmg",
        "filename": ARTIFACT_NAME,
        "sha256": digest(artifact_bytes),
        "size": len(artifact_bytes),
    }
    reference = {
        "path": "lab/install-matrix-result.json",
        "sha256": digest(evidence_bytes),
    }
    for case in value["cases"]:
        case["status"] = "passed"
        case["evidence"] = [copy.deepcopy(reference)]
    value["decision"] = "go"
    value["blockers"] = []

    matrix_path = directory / "installation-matrix-final.json"
    write(matrix_path, value)
    contract_path = make_present_contract(directory)
    return {
        "value": value,
        "matrix": matrix_path,
        "evidence": evidence_root,
        "artifacts": artifacts_dir,
        "artifact": artifact_file,
        "contract": contract_path,
    }


def final_arguments(packet: dict[str, Path | dict]) -> tuple[str, ...]:
    return (
        *expected_identity_arguments(),
        "--evidence-root",
        str(packet["evidence"]),
        "--artifacts-dir",
        str(packet["artifacts"]),
        "--public-contract",
        str(packet["contract"]),
        "--verify-files",
    )


class InstallationMatrixTests(unittest.TestCase):
    def test_checked_in_inventory_and_truthful_no_go(self) -> None:
        value = load(BASE_PATH)
        self.assertEqual(tuple(case["id"] for case in value["cases"]), EXPECTED_CASES)
        self.assertEqual(
            {case["id"] for case in value["cases"] if case["status"] == "blockedAbsentSurface"},
            EXPECTED_BLOCKED,
        )
        self.assertEqual(value["candidate"], {
            "version": None,
            "build": None,
            "commit": None,
            "artifact": None,
        })
        self.assertEqual(value["decision"], "noGo")
        self.assertTrue(value["blockers"])

        structural = run_matrix(
            BASE_PATH,
            "--allow-pending",
            "--public-contract",
            str(CONTRACT_PATH),
        )
        closed = run_matrix(BASE_PATH, "--public-contract", str(CONTRACT_PATH))
        self.assertEqual(structural.returncode, 0, structural.stderr)
        self.assertNotEqual(closed.returncode, 0)

    def test_candidate_stage_binds_identity_but_not_unbuilt_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value = load(BASE_PATH)
            bind_candidate(value)
            path = directory / "installation-matrix-candidate.json"
            write(path, value)
            result = run_matrix(
                path,
                "--candidate-stage",
                *expected_identity_arguments(),
                "--evidence-root",
                str(directory),
                "--public-contract",
                str(CONTRACT_PATH),
                "--verify-files",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("final signed DMG execution remains required", result.stdout)

    def test_candidate_stage_rejects_passed_go_or_artifact_claims(self) -> None:
        mutations = {}
        passed = load(BASE_PATH)
        bind_candidate(passed)
        passed["cases"][0]["status"] = "passed"
        passed["cases"][0]["evidence"] = [{"path": "result.json", "sha256": "1" * 64}]
        mutations["passed case"] = passed

        go = load(BASE_PATH)
        bind_candidate(go)
        go["decision"] = "go"
        go["blockers"] = []
        mutations["Go decision"] = go

        artifact = load(BASE_PATH)
        bind_candidate(artifact)
        artifact["candidate"]["artifact"] = {
            "kind": "dmg",
            "filename": ARTIFACT_NAME,
            "sha256": "1" * 64,
            "size": 1,
        }
        mutations["artifact"] = artifact

        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            for index, (label, value) in enumerate(mutations.items()):
                with self.subTest(label=label):
                    path = directory / f"stage-{index}.json"
                    write(path, value)
                    result = run_matrix(
                        path,
                        "--candidate-stage",
                        *expected_identity_arguments(),
                        "--public-contract",
                        str(CONTRACT_PATH),
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_candidate_stage_rejects_identity_mismatch_and_incomplete_mode_mixing(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "stage.json"
            value = load(BASE_PATH)
            bind_candidate(value)
            write(path, value)
            mismatch = run_matrix(
                path,
                "--candidate-stage",
                "--candidate-version",
                VERSION,
                "--build",
                str(BUILD),
                "--commit",
                "b" * 40,
                "--public-contract",
                str(CONTRACT_PATH),
            )
            mixed = run_matrix(
                path,
                "--candidate-stage",
                "--allow-pending",
                "--public-contract",
                str(CONTRACT_PATH),
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertNotEqual(mixed.returncode, 0)

    def test_candidate_identity_rejects_other_lines_and_build_metadata(self) -> None:
        versions = ("1.1.0-rc.1", "1.0.0-rc.0", "1.0.0+local", "1.0.0-rc.1+local")
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            for index, version in enumerate(versions):
                with self.subTest(version=version):
                    value = load(BASE_PATH)
                    bind_candidate(value)
                    value["candidate"]["version"] = version
                    path = directory / f"identity-{index}.json"
                    write(path, value)
                    result = run_matrix(
                        path,
                        "--candidate-stage",
                        "--public-contract",
                        str(CONTRACT_PATH),
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_inventory_rejects_missing_duplicate_unknown_and_wrong_phase(self) -> None:
        mutations = {}
        missing = load(BASE_PATH)
        missing["cases"].pop()
        mutations["missing"] = missing

        duplicate = load(BASE_PATH)
        duplicate["cases"][-1]["id"] = duplicate["cases"][0]["id"]
        duplicate["cases"][-1]["phase"] = duplicate["cases"][0]["phase"]
        mutations["duplicate"] = duplicate

        unknown = load(BASE_PATH)
        unknown["cases"][-1]["id"] = "downgrade.unknown"
        mutations["unknown"] = unknown

        wrong_phase = load(BASE_PATH)
        wrong_phase["cases"][0]["phase"] = "upgrade"
        mutations["wrong phase"] = wrong_phase

        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            for index, (label, value) in enumerate(mutations.items()):
                with self.subTest(label=label):
                    path = directory / f"inventory-{index}.json"
                    write(path, value)
                    result = run_matrix(
                        path,
                        "--allow-pending",
                        "--public-contract",
                        str(CONTRACT_PATH),
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_evidence_status_path_and_digest_are_fail_closed(self) -> None:
        mutations = {}
        passed_without_evidence = load(BASE_PATH)
        bind_candidate(passed_without_evidence)
        passed_without_evidence["cases"][0]["status"] = "passed"
        mutations["passed without evidence"] = passed_without_evidence

        pending_with_evidence = load(BASE_PATH)
        pending_with_evidence["cases"][0]["evidence"] = [
            {"path": "result.json", "sha256": "1" * 64}
        ]
        mutations["pending with evidence"] = pending_with_evidence

        unsafe_path = load(BASE_PATH)
        bind_candidate(unsafe_path)
        unsafe_path["cases"][0]["status"] = "passed"
        unsafe_path["cases"][0]["evidence"] = [
            {"path": "../result.json", "sha256": "1" * 64}
        ]
        mutations["unsafe path"] = unsafe_path

        zero_digest = load(BASE_PATH)
        bind_candidate(zero_digest)
        zero_digest["cases"][0]["status"] = "passed"
        zero_digest["cases"][0]["evidence"] = [
            {"path": "result.json", "sha256": "0" * 64}
        ]
        mutations["zero digest"] = zero_digest

        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            for index, (label, value) in enumerate(mutations.items()):
                with self.subTest(label=label):
                    path = directory / f"evidence-{index}.json"
                    write(path, value)
                    result = run_matrix(
                        path,
                        "--allow-pending",
                        "--public-contract",
                        str(CONTRACT_PATH),
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_verified_partial_evidence_can_only_remain_no_go(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            evidence = directory / "lab/clean-install.json"
            evidence.parent.mkdir()
            evidence_bytes = b"verified clean installation evidence\n"
            evidence.write_bytes(evidence_bytes)

            value = load(BASE_PATH)
            bind_candidate(value)
            value["cases"][0]["status"] = "passed"
            value["cases"][0]["evidence"] = [
                {"path": "lab/clean-install.json", "sha256": digest(evidence_bytes)}
            ]
            path = directory / "partial.json"
            write(path, value)

            valid = run_matrix(
                path,
                "--allow-pending",
                "--evidence-root",
                str(directory),
                "--public-contract",
                str(CONTRACT_PATH),
                "--verify-files",
            )
            value["decision"] = "go"
            value["blockers"] = []
            write(path, value)
            false_go = run_matrix(
                path,
                "--allow-pending",
                "--evidence-root",
                str(directory),
                "--public-contract",
                str(CONTRACT_PATH),
                "--verify-files",
            )
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertNotEqual(false_go.returncode, 0)

    def test_absent_surface_status_tracks_public_contract(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            missing_surface = load(BASE_PATH)
            next(
                case for case in missing_surface["cases"] if case["id"] == "repair.cli"
            )["status"] = "pending"
            missing_path = directory / "missing-surface.json"
            write(missing_path, missing_surface)

            stale_block = load(BASE_PATH)
            stale_path = directory / "stale-block.json"
            write(stale_path, stale_block)
            present_contract = make_present_contract(directory)

            unapproved = load(BASE_PATH)
            unapproved["cases"][0]["status"] = "blockedAbsentSurface"
            unapproved_path = directory / "unapproved-block.json"
            write(unapproved_path, unapproved)

            self.assertNotEqual(
                run_matrix(
                    missing_path,
                    "--allow-pending",
                    "--public-contract",
                    str(CONTRACT_PATH),
                ).returncode,
                0,
            )
            self.assertNotEqual(
                run_matrix(
                    stale_path,
                    "--allow-pending",
                    "--public-contract",
                    str(present_contract),
                ).returncode,
                0,
            )
            self.assertNotEqual(
                run_matrix(
                    unapproved_path,
                    "--allow-pending",
                    "--public-contract",
                    str(CONTRACT_PATH),
                ).returncode,
                0,
            )

    def test_final_go_verifies_every_case_and_exact_dmg_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            packet = make_final_packet(Path(raw))
            result = run_matrix(packet["matrix"], *final_arguments(packet))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Installation matrix passed for {VERSION} ({BUILD})", result.stdout)

    def test_final_go_cannot_skip_file_verification(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            packet = make_final_packet(Path(raw))
            result = run_matrix(
                packet["matrix"],
                *expected_identity_arguments(),
                "--public-contract",
                str(packet["contract"]),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires --verify-files", result.stderr)

    def test_final_go_rejects_artifact_tamper_missing_binding_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)

            tampered = make_final_packet(directory / "tampered")
            tampered["artifact"].write_bytes(b"tampered DMG bytes\n")
            self.assertNotEqual(
                run_matrix(tampered["matrix"], *final_arguments(tampered)).returncode,
                0,
            )

            missing = make_final_packet(directory / "missing")
            missing_value = missing["value"]
            missing_value["candidate"]["artifact"] = None
            write(missing["matrix"], missing_value)
            self.assertNotEqual(
                run_matrix(missing["matrix"], *final_arguments(missing)).returncode,
                0,
            )

            linked = make_final_packet(directory / "linked")
            artifact = linked["artifact"]
            target = directory / "outside-artifact.dmg"
            target.write_bytes(artifact.read_bytes())
            artifact.unlink()
            artifact.symlink_to(target)
            self.assertNotEqual(
                run_matrix(linked["matrix"], *final_arguments(linked)).returncode,
                0,
            )

    def test_final_go_rejects_evidence_tamper_and_candidate_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            tampered = make_final_packet(directory / "tampered")
            evidence = tampered["evidence"] / "lab/install-matrix-result.json"
            evidence.write_bytes(b"tampered matrix evidence\n")
            self.assertNotEqual(
                run_matrix(tampered["matrix"], *final_arguments(tampered)).returncode,
                0,
            )

            mismatch = make_final_packet(directory / "mismatch")
            arguments = list(final_arguments(mismatch))
            commit_index = arguments.index("--commit") + 1
            arguments[commit_index] = "b" * 40
            self.assertNotEqual(
                run_matrix(mismatch["matrix"], *arguments).returncode,
                0,
            )

    def test_protected_preflight_separates_candidate_and_promotion_modes(self) -> None:
        source = (RC / "scripts/preflight.sh").read_text(encoding="utf-8")
        start = source.index("INSTALL_ARGS=(")
        end = source.index(
            '"${PYTHON}" "${SCRIPT_DIR}/validate_installation_matrix.py" "${INSTALL_ARGS[@]}"',
            start,
        )
        protected_invocation = source[start:end]
        self.assertIn("--candidate-stage", protected_invocation)
        self.assertNotIn("--allow-pending", protected_invocation)
        self.assertIn("--verify-files", protected_invocation)
        self.assertIn('--artifacts-dir "${CANDIDATE_STAGE_PATH}/public"', protected_invocation)


if __name__ == "__main__":
    unittest.main()
