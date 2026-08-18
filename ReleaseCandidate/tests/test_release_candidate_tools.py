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
SCRIPTS = RC / "scripts"
CONFIG = RC / "config"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def run(script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(
        (sys.executable, str(SCRIPTS / script), *arguments),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
    )


def git(repository: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ("git", "-C", str(repository), *arguments),
        text=True,
        stderr=subprocess.STDOUT,
    ).strip()


def initialize_git_repository(repository: Path) -> str:
    git(repository, "init", "-q")
    git(repository, "config", "user.name", "Vela Test")
    git(repository, "config", "user.email", "vela-test@example.invalid")
    (repository / "seed.txt").write_text("seed\n", encoding="utf-8")
    git(repository, "add", "seed.txt")
    git(repository, "commit", "-q", "-m", "seed")
    return git(repository, "rev-parse", "HEAD")


def record(directory: Path, name: str) -> dict:
    path = directory / name
    content = f"real test artifact: {name}\n".encode()
    path.write_bytes(content)
    return {"filename": name, "sha256": digest_bytes(content), "size": len(content)}


def existing_record(path: Path) -> dict:
    content = path.read_bytes()
    return {"filename": path.name, "sha256": digest_bytes(content), "size": len(content)}


def rc_manifest(directory: Path, *, local_ready: bool = False) -> dict:
    commit = subprocess.check_output(("git", "rev-parse", "HEAD"), cwd=ROOT, text=True).strip()
    freezes = {
        "publicContract": record(directory, "public-contract-freeze.json"),
        "architecture": record(directory, "architecture-freeze.json"),
        "documentation": record(directory, "documentation-manifest.json"),
        "privacy": record(directory, "PrivacyInfo.xcprivacy"),
    }
    artifacts = {
        "releaseManifest": record(directory, "release-manifest-1.0.0-rc.1.json"),
        "dmg": record(directory, "Vela-1.0.0-rc.1-arm64.dmg"),
        "sbom": record(directory, "sbom-1.0.0-rc.1.spdx.json"),
        "appcast": record(directory, "appcast.xml"),
        "checksums": record(directory, "artifact-checksums-1.0.0-rc.1.txt"),
        "migrationGuarantee": record(directory, "migration-guarantee.json"),
        "auditSummary": record(directory, "audit-summary.md"),
        "knownLimitations": record(directory, "known-limitations.json"),
    }
    quality = {
        "stopShip": "pending",
        "contracts": "pending",
        "migration": "pending",
        "securityAudit": "pending",
        "soak": "pending",
        "performance": "pending",
        "accessibilityPrivacy": "pending",
        "installation": "pending",
        "artifact": "pending",
        "supportIncident": "pending",
    }
    if local_ready:
        quality = {key: "pass" for key in quality}
        quality["artifact"] = "pending"
    subjects = [
        {"filename": artifacts[name]["filename"], "sha256": artifacts[name]["sha256"]}
        for name in ("dmg", "sbom")
    ]
    return {
        "schemaVersion": 1,
        "candidate": {
            "version": "1.0.0-rc.1",
            "marketingVersion": "1.0.0",
            "build": 2026071501,
            "channel": "rc",
            "appUpdateChannel": "beta",
            "prereleaseLabel": "RC 1",
        },
        "source": {"commit": commit, "tag": "v1.0.0-rc.1", "dirty": False},
        "freeze": freezes,
        "quality": quality,
        "artifacts": artifacts,
        "signing": {
            "certificateSHA256": digest_bytes(b"test certificate bytes"),
            "appNotary": {"submissionID": "test-app-submission", "status": "Accepted"},
            "dmgNotary": {"submissionID": "test-dmg-submission", "status": "Accepted"},
            "bundleVerificationRequired": True,
        },
        "provenance": {
            "toolchain": {"xcode": "test fixture derived at runtime"},
            "workflow": {"repository": None, "runID": None, "runnerClass": "local/macos/arm64"},
            "attestation": {
                "status": "pendingExternal",
                "evidence": None,
                "subjects": subjects,
                "policy": {
                    "workflowPath": ".github/workflows/release.yml",
                    "environment": "production",
                    "verificationRepository": "Spacebody/Vela",
                    "requiredPermissions": ["id-token:write", "attestations:write", "artifact-metadata:write"],
                },
            },
        },
    }


class CheckedInTruthTests(unittest.TestCase):
    def test_pending_migration_is_structurally_valid_but_not_closed(self) -> None:
        structural = run(
            "validate_migration_guarantee.py",
            str(CONFIG / "migration-guarantee.json"),
            "--allow-pending",
        )
        closed = run("validate_migration_guarantee.py", str(CONFIG / "migration-guarantee.json"))
        self.assertEqual(structural.returncode, 0, structural.stderr)
        self.assertNotEqual(closed.returncode, 0)

    def test_checked_in_audit_pending_shape_regression(self) -> None:
        result = run(
            "validate_audit_closure.py",
            str(CONFIG / "audit-closure.json"),
            "--allow-pending",
            "--as-of",
            "2026-07-14",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = load(CONFIG / "audit-closure.json")
        self.assertEqual(set(value["scope"]["deltaReview"]), {"status", "path", "sha256"})

    def test_known_limitations_are_truthful_and_strict(self) -> None:
        result = run(
            "validate_known_limitations.py",
            str(CONFIG / "known-limitations.json"),
            "--version",
            "1.0.0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = load(CONFIG / "known-limitations.json")
        ssid = next(item for item in value["limitations"] if item["id"] == "ssid-location-permission")
        self.assertIn("does not enable production Scenes", ssid["description"])
        self.assertEqual(ssid["impact"], {"security": "none", "data": "none", "network": "none"})

    def test_go_packet_is_explicit_no_go(self) -> None:
        result = run(
            "validate_go_no_go.py",
            str(CONFIG / "go-no-go.json"),
            "--expect",
            "noGo",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_support_matrix_matches_public_contract(self) -> None:
        result = run(
            "validate_support_matrix.py",
            str(CONFIG / "support-matrix.json"),
            "--public-contract",
            str(ROOT / "Contracts/v1/public-contract-freeze.json"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class ValidatorNegativeTests(unittest.TestCase):
    def test_semver_build_and_tag_contract(self) -> None:
        passed = run(
            "validate_semver_build.py",
            "--version",
            "1.0.0-rc.1",
            "--marketing-version",
            "1.0.0",
            "--build",
            "2026071501",
            "--tag",
            "v1.0.0-rc.1",
            "--channel",
            "rc",
            "--published",
            str(CONFIG / "published-builds.json"),
        )
        wrong_tag = run(
            "validate_semver_build.py",
            "--version",
            "1.0.0-rc.1",
            "--build",
            "2026071501",
            "--tag",
            "v1.0.0-rc.2",
            "--channel",
            "rc",
            "--published",
            str(CONFIG / "published-builds.json"),
        )
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertNotEqual(wrong_tag.returncode, 0)

        missing_history = run(
            "validate_semver_build.py",
            "--version",
            "1.0.0-rc.1",
            "--build",
            "2026071501",
            "--channel",
            "rc",
            "--published",
            str(CONFIG / "published-builds.json"),
            "--require-history",
        )
        self.assertNotEqual(missing_history.returncode, 0)
        self.assertIn("build-ledger/high-water", missing_history.stderr)

    def test_historical_rc_versions_require_exact_positive_rc_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            registry = load(CONFIG / "published-builds.json")
            valid = copy.deepcopy(registry)
            valid["builds"] = [{
                "version": "1.0.0-rc.12",
                "build": 2026071401,
                "channel": "rc",
                "status": "published",
                "artifactSHA256": digest_bytes(b"published rc artifact"),
                "recordedAt": "2026-07-14T08:00:00Z",
                "statusUpdatedAt": "2026-07-14T08:00:00Z",
            }]
            valid_path = directory / "valid-history.json"
            write(valid_path, valid)
            accepted = run(
                "validate_semver_build.py",
                "--version", "1.0.0",
                "--build", "2026071501",
                "--channel", "stable",
                "--published", str(valid_path),
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            for index, version in enumerate((
                "1.0.0-rc.0",
                "1.0.0-rc.01",
                "1.0.0-rc.alpha",
                "1.0.0-rc.1.extra",
            )):
                with self.subTest(version=version):
                    invalid = copy.deepcopy(valid)
                    invalid["builds"][0]["version"] = version
                    invalid_path = directory / f"invalid-history-{index}.json"
                    write(invalid_path, invalid)
                    rejected = run(
                        "validate_semver_build.py",
                        "--version", "1.0.0",
                        "--build", "2026071501",
                        "--channel", "stable",
                        "--published", str(invalid_path),
                    )
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertRegex(
                        rejected.stderr,
                        r"(?:build-ledger RC has invalid version|invalid SemVer)",
                    )

    def test_stable_build_must_exceed_every_published_rc(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            published = Path(raw) / "published.json"
            value = load(CONFIG / "published-builds.json")
            value["builds"] = [{
                "version": "1.0.0-rc.1",
                "build": 2026071501,
                "channel": "rc",
                "status": "published",
                "artifactSHA256": digest_bytes(b"published RC"),
                "recordedAt": "2026-07-15T01:00:00Z",
                "statusUpdatedAt": "2026-07-15T01:00:00Z",
            }]
            write(published, value)
            passed = run(
                "validate_semver_build.py",
                "--version", "1.0.0",
                "--marketing-version", "1.0.0",
                "--build", "2026071502",
                "--tag", "v1.0.0",
                "--channel", "stable",
                "--published", str(published),
                "--require-history",
            )
            too_low = run(
                "validate_semver_build.py",
                "--version", "1.0.0",
                "--build", "2026071401",
                "--tag", "v1.0.0",
                "--channel", "stable",
                "--published", str(published),
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertNotEqual(too_low.returncode, 0)
            self.assertIn("build-ledger high-water", too_low.stderr)

    def test_failed_or_withdrawn_builds_advance_the_high_water_and_cannot_be_reused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = Path(raw) / "published-builds.json"
            value = load(CONFIG / "published-builds.json")
            value["builds"] = [
                {
                    "version": "1.0.0-rc.1",
                    "build": 2026071501,
                    "channel": "rc",
                    "status": "failed",
                    "artifactSHA256": None,
                    "recordedAt": "2026-07-15T01:00:00Z",
                    "statusUpdatedAt": "2026-07-15T01:00:00Z",
                },
                {
                    "version": "1.0.0-rc.2",
                    "build": 2026071502,
                    "channel": "rc",
                    "status": "withdrawn",
                    "artifactSHA256": digest_bytes(b"withdrawn candidate"),
                    "recordedAt": "2026-07-15T02:00:00Z",
                    "statusUpdatedAt": "2026-07-15T02:00:00Z",
                },
            ]
            write(ledger, value)
            reused = run(
                "validate_semver_build.py",
                "--version", "1.0.0-rc.3",
                "--build", "2026071502",
                "--channel", "rc",
                "--published", str(ledger),
            )
            older = run(
                "validate_semver_build.py",
                "--version", "1.0.0-rc.3",
                "--build", "2026071409",
                "--channel", "rc",
                "--published", str(ledger),
            )
            self.assertNotEqual(reused.returncode, 0)
            self.assertIn("already allocated, failed, withdrawn, or published", reused.stderr)
            self.assertNotEqual(older.returncode, 0)
            self.assertIn("build-ledger high-water", older.stderr)

    def test_failed_stable_version_can_retry_only_with_a_higher_build(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            ledger = Path(raw) / "published-builds.json"
            value = load(CONFIG / "published-builds.json")
            value["builds"] = [{
                "version": "1.0.0",
                "build": 2026071501,
                "channel": "stable",
                "status": "failed",
                "artifactSHA256": None,
                "recordedAt": "2026-07-15T01:00:00Z",
                "statusUpdatedAt": "2026-07-15T01:00:00Z",
            }]
            write(ledger, value)
            retry = run(
                "validate_semver_build.py",
                "--version", "1.0.0",
                "--build", "2026071502",
                "--channel", "stable",
                "--published", str(ledger),
            )
            reuse = run(
                "validate_semver_build.py",
                "--version", "1.0.0",
                "--build", "2026071501",
                "--channel", "stable",
                "--published", str(ledger),
            )
            self.assertEqual(retry.returncode, 0, retry.stderr)
            self.assertNotEqual(reuse.returncode, 0)
            self.assertIn("already allocated, failed, withdrawn, or published", reuse.stderr)

    def test_published_or_withdrawn_version_cannot_be_reissued(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            for index, status in enumerate(("published", "withdrawn")):
                with self.subTest(status=status):
                    ledger = directory / f"{status}.json"
                    value = load(CONFIG / "published-builds.json")
                    value["builds"] = [{
                        "version": "1.0.0",
                        "build": 2026071501,
                        "channel": "stable",
                        "status": status,
                        "artifactSHA256": digest_bytes(status.encode("utf-8")),
                        "recordedAt": "2026-07-15T01:00:00Z",
                        "statusUpdatedAt": "2026-07-15T01:00:00Z",
                    }]
                    write(ledger, value)
                    retry = run(
                        "validate_semver_build.py",
                        "--version", "1.0.0",
                        "--build", str(2026071502 + index),
                        "--channel", "stable",
                        "--published", str(ledger),
                    )
                    self.assertNotEqual(retry.returncode, 0)
                    self.assertIn("already published or withdrawn", retry.stderr)

    def test_support_matrix_rejects_policy_drift(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            app_path = directory / "bad-app-support.json"
            app_value = load(CONFIG / "support-matrix.json")
            app_value["appVersions"][1]["support"] = "full"
            write(app_path, app_value)
            core_path = directory / "bad-core-support.json"
            core_value = load(CONFIG / "support-matrix.json")
            core_value["cores"]["arbitraryExternal"] = "supported"
            write(core_path, core_value)
            self.assertNotEqual(run("validate_support_matrix.py", str(app_path)).returncode, 0)
            self.assertNotEqual(run("validate_support_matrix.py", str(core_path)).returncode, 0)

    def test_pending_migration_cannot_carry_unverified_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "migration.json"
            value = load(CONFIG / "migration-guarantee.json")
            value["sources"][0]["fixturePath"] = "Fixtures/unreviewed.json"
            value["sources"][0]["fixtureSHA256"] = digest_bytes(b"unreviewed")
            write(path, value)
            result = run("validate_migration_guarantee.py", str(path), "--allow-pending")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unverified fixture provenance", result.stderr)

    def test_migration_store_and_journal_inventory_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            missing = load(CONFIG / "migration-guarantee.json")
            missing["stores"].pop()
            missing_path = directory / "missing-store.json"
            write(missing_path, missing)
            missing_result = run(
                "validate_migration_guarantee.py", str(missing_path), "--allow-pending"
            )
            self.assertNotEqual(missing_result.returncode, 0)

            duplicate = load(CONFIG / "migration-guarantee.json")
            duplicate["stores"][-1] = copy.deepcopy(duplicate["stores"][0])
            duplicate_path = directory / "duplicate-store.json"
            write(duplicate_path, duplicate)
            duplicate_result = run(
                "validate_migration_guarantee.py", str(duplicate_path), "--allow-pending"
            )
            self.assertNotEqual(duplicate_result.returncode, 0)
            self.assertIn("store/journal inventory", duplicate_result.stderr)

    def test_passed_migration_rejects_fake_commit_tag_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            repository = Path(raw)
            head = initialize_git_repository(repository)
            base = load(CONFIG / "migration-guarantee.json")

            def passed_source(metadata: dict, *, commit: str = head, tag: str = "v0.1") -> dict:
                fixture = repository / "fixture.json"
                write(fixture, {"fixtureMetadata": metadata, "payload": {"profile": "historical"}})
                return {
                    "version": "0.1",
                    "status": "passed",
                    "producingTag": tag,
                    "producingCommit": commit,
                    "fixturePath": "fixture.json",
                    "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
                    "generatorVersion": "1.0.0",
                    "fixtureSchemaVersion": 1,
                }

            expected_metadata = {
                "sourceVersion": "0.1",
                "producingTag": "v0.1",
                "producingCommit": head,
                "generatorVersion": "1.0.0",
                "fixtureSchemaVersion": 1,
            }
            cases = []
            wrong_metadata = copy.deepcopy(base)
            wrong_metadata["sources"][0] = passed_source({**expected_metadata, "sourceVersion": "0.8"})
            cases.append((wrong_metadata, "fixture metadata"))

            fake_commit = "a" * 40
            fake_metadata = {**expected_metadata, "producingCommit": fake_commit}
            fake_commit_value = copy.deepcopy(base)
            fake_commit_value["sources"][0] = passed_source(fake_metadata, commit=fake_commit)
            cases.append((fake_commit_value, "git"))

            missing_tag_value = copy.deepcopy(base)
            missing_tag_value["sources"][0] = passed_source(expected_metadata)
            cases.append((missing_tag_value, "tag"))

            for index, (value, _) in enumerate(cases):
                path = repository / f"migration-{index}.json"
                write(path, value)
                result = run(
                    "validate_migration_guarantee.py",
                    str(path),
                    "--allow-pending",
                    "--repository-root", str(repository),
                    "--verify-files",
                )
                self.assertNotEqual(result.returncode, 0, f"case {index} unexpectedly passed")

    def test_audit_requires_baseline_ancestor_of_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            repository = Path(raw)
            common = initialize_git_repository(repository)
            git(repository, "checkout", "-q", "-b", "audit-left")
            (repository / "left.txt").write_text("left\n", encoding="utf-8")
            git(repository, "add", "left.txt")
            git(repository, "commit", "-q", "-m", "left")
            left = git(repository, "rev-parse", "HEAD")
            git(repository, "checkout", "-q", "-b", "audit-right", common)
            (repository / "right.txt").write_text("right\n", encoding="utf-8")
            git(repository, "add", "right.txt")
            git(repository, "commit", "-q", "-m", "right")
            right = git(repository, "rev-parse", "HEAD")
            value = load(CONFIG / "audit-closure.json")
            value["scope"]["baselineCommit"] = left
            value["scope"]["rcCommit"] = right
            path = repository / "audit.json"
            write(path, value)
            result = run(
                "validate_audit_closure.py",
                str(path),
                "--allow-pending",
                "--repository-root", str(repository),
                "--verify-files",
                "--expected-commit", right,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not an ancestor", result.stderr)

    def test_expired_medium_risk_acceptance_is_malformed_even_no_go(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "audit.json"
            value = load(CONFIG / "audit-closure.json")
            value["findings"] = [{
                "id": "VELA-AUDIT-101",
                "severity": "medium",
                "status": "riskAccepted",
                "affectedBuild": None,
                "component": "test boundary",
                "description": "Runtime-generated negative test finding.",
                "proof": [],
                "fixCommit": None,
                "regressionTest": None,
                "retestEvidence": [],
                "owner": "Security",
                "disclosure": "private",
                "riskAcceptance": {
                    "owner": "Security",
                    "reason": "negative test",
                    "exposure": "bounded fixture",
                    "mitigation": "none",
                    "expiresAt": "2026-07-13",
                    "affectedVersion": "1.0.0-rc.1",
                },
            }]
            write(path, value)
            result = run(
                "validate_audit_closure.py",
                str(path),
                "--allow-pending",
                "--as-of",
                "2026-07-14",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("risk acceptance expired", result.stderr)

    def test_known_limitation_cannot_hide_material_impact(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "limitations.json"
            value = load(CONFIG / "known-limitations.json")
            value["limitations"][0]["impact"]["security"] = "material"
            write(path, value)
            result = run("validate_known_limitations.py", str(path))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must remain Stop-Ship", result.stderr)

    def test_known_limitations_cannot_be_empty(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "limitations.json"
            value = load(CONFIG / "known-limitations.json")
            value["limitations"] = []
            write(path, value)
            result = run("validate_known_limitations.py", str(path))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("too few items", result.stderr)

    def test_go_packet_rejects_all_zero_evidence_hash(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "decision.json"
            value = load(CONFIG / "go-no-go.json")
            value["gates"][0]["evidence"] = [{"path": "evidence.json", "sha256": "0" * 64}]
            write(path, value)
            result = run("validate_go_no_go.py", str(path), "--expect", "noGo")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 is invalid", result.stderr)

    def test_pre_artifact_mode_never_accepts_artifact_pass_or_go(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "decision.json"
            value = load(CONFIG / "go-no-go.json")
            commit = subprocess.check_output(("git", "rev-parse", "HEAD"), cwd=ROOT, text=True).strip()
            value["candidate"] = {
                "version": "1.0.0-rc.1",
                "build": 2026071501,
                "commit": commit,
            }
            for gate in value["gates"]:
                gate["status"] = "pass"
                gate["evidence"] = [{"path": "evidence.json", "sha256": digest_bytes(gate["id"].encode())}]
            value["decision"] = "go"
            value["decisionReason"] = "negative test must not pass"
            value["approvals"] = []
            write(path, value)
            artifact_pass = run("validate_go_no_go.py", str(path), "--pre-artifact")
            self.assertNotEqual(artifact_pass.returncode, 0)
            self.assertIn("artifact=pending", artifact_pass.stderr)

            artifact_gate = next(gate for gate in value["gates"] if gate["id"] == "artifact")
            artifact_gate["status"] = "pending"
            artifact_gate["evidence"] = []
            write(path, value)
            go_claim = run("validate_go_no_go.py", str(path), "--pre-artifact")
            self.assertNotEqual(go_claim.returncode, 0)
            self.assertIn("must not claim Go", go_claim.stderr)

    def test_protected_preflight_requires_external_candidate_evidence(self) -> None:
        result = subprocess.run(
            (
                "/bin/bash",
                str(SCRIPTS / "preflight.sh"),
                "--version", "1.0.0",
                "--candidate-version", "1.0.0",
                "--build", "2026071502",
                "--tag", "v1.0.0",
                "--candidate-stage",
            ),
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("external candidate evidence required", result.stderr)

    def test_rc_manifest_enforces_candidate_basename_and_display_label(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = directory / "rc.json"
            value = rc_manifest(directory)
            write(path, value)
            passed = run("validate_release_candidate.py", str(path), "--stage", "structural")
            self.assertEqual(passed.returncode, 0, passed.stderr)

            value["candidate"]["prereleaseLabel"] = "rc.1"
            write(directory / "bad-label.json", value)
            bad_label = run(
                "validate_release_candidate.py",
                str(directory / "bad-label.json"),
                "--stage",
                "structural",
            )
            self.assertNotEqual(bad_label.returncode, 0)

    def test_stable_manifest_uses_stable_channel_and_exact_basename(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value = rc_manifest(directory)
            old_dmg = directory / value["artifacts"]["dmg"]["filename"]
            new_dmg = directory / "Vela-1.0.0-arm64.dmg"
            old_dmg.rename(new_dmg)
            value["artifacts"]["dmg"] = {
                "filename": new_dmg.name,
                "sha256": hashlib.sha256(new_dmg.read_bytes()).hexdigest(),
                "size": new_dmg.stat().st_size,
            }
            value["candidate"].update({
                "version": "1.0.0",
                "channel": "stable",
                "appUpdateChannel": "stable",
                "prereleaseLabel": None,
            })
            value["source"]["tag"] = "v1.0.0"
            value["provenance"]["attestation"]["subjects"] = [
                {
                    "filename": value["artifacts"][name]["filename"],
                    "sha256": value["artifacts"][name]["sha256"],
                }
                for name in ("dmg", "sbom")
            ]
            path = directory / "stable.json"
            write(path, value)
            result = run("validate_release_candidate.py", str(path), "--stage", "structural")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_pending_external_is_only_valid_at_local_stage(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = directory / "rc.json"
            write(path, rc_manifest(directory, local_ready=True))
            local = run("validate_release_candidate.py", str(path), "--stage", "local")
            final = run("validate_release_candidate.py", str(path), "--stage", "final")
            self.assertEqual(local.returncode, 0, local.stderr)
            self.assertNotEqual(final.returncode, 0)
            self.assertIn("attestation", final.stderr)

    def test_embedded_attestation_claims_and_wrong_repository_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            base = rc_manifest(directory, local_ready=True)
            cases = []
            fake_verified = copy.deepcopy(base)
            fake_verified["provenance"]["attestation"]["status"] = "verified"
            cases.append(fake_verified)
            bare_not_applicable = copy.deepcopy(base)
            bare_not_applicable["provenance"]["attestation"]["status"] = "notApplicableDocumented"
            cases.append(bare_not_applicable)
            wrong_repository = copy.deepcopy(base)
            wrong_repository["provenance"]["attestation"]["policy"]["verificationRepository"] = "attacker/fork"
            cases.append(wrong_repository)
            for index, value in enumerate(cases):
                path = directory / f"bad-attestation-{index}.json"
                write(path, value)
                result = run("validate_release_candidate.py", str(path), "--stage", "structural")
                self.assertNotEqual(result.returncode, 0, f"case {index} unexpectedly passed")

    def test_pending_external_subjects_cannot_point_at_unrelated_digest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            value = rc_manifest(directory, local_ready=True)
            value["provenance"]["attestation"]["subjects"][0]["sha256"] = digest_bytes(
                b"unrelated artifact"
            )
            path = directory / "unrelated-subject.json"
            write(path, value)
            result = run("validate_release_candidate.py", str(path), "--stage", "structural")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly match", result.stderr)

    def test_attestation_verifier_rejects_mid_verification_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            evidence = directory / "evidence"
            evidence.mkdir(mode=0o700)
            private = evidence / "private"
            private.mkdir(mode=0o700)
            artifacts = directory / "artifacts"
            artifacts.mkdir()
            value = rc_manifest(artifacts, local_ready=True)
            manifest = artifacts / "rc-manifest-1.0.0-rc.1.json"
            write(manifest, value)

            names = {
                record_value["filename"]
                for group in (value["freeze"], value["artifacts"])
                for record_value in group.values()
            }
            names.add(manifest.name)
            nested = artifacts / "public/release-notes/1.0.0-rc.1.md"
            nested.parent.mkdir(parents=True)
            nested.write_text("release notes\n", encoding="utf-8")
            names.add("public/release-notes/1.0.0-rc.1.md")
            subject_checksums = directory / "final-subject-checksums.txt"
            subject_checksums.write_text(
                "".join(
                    f"{hashlib.sha256((artifacts / name).read_bytes()).hexdigest()}  {name}\n"
                    for name in sorted(names)
                ),
                encoding="utf-8",
            )

            mock_bin = directory / "bin"
            mock_bin.mkdir()
            mock_gh = mock_bin / "gh"
            mock_gh.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "base=\"$(cd \"$(dirname \"$0\")/..\" && pwd -P)\"\n"
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf 'gh version 2.95.0 (fixture)\\n'\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"${1:-} ${2:-}\" == \"attestation trusted-root\" ]]; then\n"
                "  [[ -z \"${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}\" ]] || exit 50\n"
                "  printf '{\"fixture\":\"trusted-root\"}\\n'\n"
                "  exit 0\n"
                "fi\n"
                "printf '%s\\n' \"$*\" >> \"${base}/mock-gh.log\"\n"
                "[[ -z \"${POISON_CONFIG:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}\" ]] || exit 51\n"
                "bundle=\"\"\n"
                "previous=\"\"\n"
                "for argument in \"$@\"; do\n"
                "  if [[ \"${previous}\" == \"--bundle\" ]]; then bundle=\"${argument}\"; fi\n"
                "  previous=\"${argument}\"\n"
                "done\n"
                "if [[ -n \"${bundle}\" ]]; then\n"
                "  [[ -z \"${GH_TOKEN:-}${GITHUB_TOKEN:-}\" ]] || exit 52\n"
                "fi\n"
                "if [[ ! -e \"${base}/mock-called\" ]]; then\n"
                "  : > \"${base}/mock-called\"\n"
                "  mutate_path=\"$(/bin/cat \"${base}/mutate-path\")\"\n"
                "  printf 'attacker replacement\\n' >> \"${mutate_path}\"\n"
                "fi\n"
                "printf '[{\"attestation\":{\"fixture\":\"signed\"},\"verificationResult\":{\"verified\":true}}]\\n'\n",
                encoding="utf-8",
            )
            mock_gh.chmod(0o755)
            output = private / "verification.json"
            environment = dict(os.environ)
            environment["PATH"] = f"{mock_bin}:{environment.get('PATH', '')}"
            environment["GH_TOKEN"] = "fixture-online-token"
            environment["GH_ENTERPRISE_TOKEN"] = "must-not-survive-isolation"
            environment["POISON_CONFIG"] = "must-not-survive-isolation"
            (directory / "mutate-path").write_text(str(nested), encoding="utf-8")
            unsafe_link = artifacts / "unlisted-intermediate-link"
            unsafe_link.symlink_to(nested.parent, target_is_directory=True)
            unsafe_output = private / "unsafe-symlink-verification.json"
            unsafe_bundle = private / "unsafe-symlink-bundle.jsonl"
            unsafe_trusted_root = private / "unsafe-symlink-trusted-root.jsonl"
            unsafe = subprocess.run(
                (
                    "/bin/bash",
                    str(SCRIPTS / "verify_rc_attestations.sh"),
                    "--manifest", str(manifest),
                    "--artifacts-dir", str(artifacts),
                    "--subject-checksums", str(subject_checksums),
                    "--output", str(unsafe_output),
                    "--bundle-output", str(unsafe_bundle),
                    "--trusted-root-output", str(unsafe_trusted_root),
                ),
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertIn("contains a symlink", unsafe.stderr)
            self.assertFalse(unsafe_output.exists())
            self.assertFalse(unsafe_bundle.exists())
            self.assertFalse(unsafe_trusted_root.exists())
            unsafe_link.unlink()

            escaped_output = directory / "escaped-verification.json"
            escaped = subprocess.run(
                (
                    "/bin/bash",
                    str(SCRIPTS / "verify_rc_attestations.sh"),
                    "--manifest", str(manifest),
                    "--artifacts-dir", str(artifacts),
                    "--subject-checksums", str(subject_checksums),
                    "--output", str(escaped_output),
                    "--bundle-output", str(private / "escaped-bundle.jsonl"),
                    "--trusted-root-output", str(private / "escaped-root.jsonl"),
                ),
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(escaped.returncode, 0)
            self.assertIn("must be directly below", escaped.stderr)
            self.assertFalse(escaped_output.exists())

            result = subprocess.run(
                (
                    "/bin/bash",
                    str(SCRIPTS / "verify_rc_attestations.sh"),
                    "--manifest", str(manifest),
                    "--artifacts-dir", str(artifacts),
                    "--subject-checksums", str(subject_checksums),
                    "--output", str(output),
                    "--bundle-output", str(private / "mutation-bundle.jsonl"),
                    "--trusted-root-output", str(private / "mutation-trusted-root.jsonl"),
                ),
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("changed after snapshot", result.stderr)
            self.assertFalse(output.exists())

            subject_checksums.write_text(
                "".join(
                    f"{hashlib.sha256((artifacts / name).read_bytes()).hexdigest()}  {name}\n"
                    for name in sorted(names)
                ),
                encoding="utf-8",
            )
            verified_output = private / "verification-success.json"
            verified_bundle = private / "verification-success-bundle.jsonl"
            verified_trusted_root = private / "verification-success-trusted-root.jsonl"
            verified = subprocess.run(
                (
                    "/bin/bash",
                    str(SCRIPTS / "verify_rc_attestations.sh"),
                    "--manifest", str(manifest),
                    "--artifacts-dir", str(artifacts),
                    "--subject-checksums", str(subject_checksums),
                    "--output", str(verified_output),
                    "--bundle-output", str(verified_bundle),
                    "--trusted-root-output", str(verified_trusted_root),
                ),
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr)
            report = load(verified_output)
            self.assertTrue(verified_bundle.is_file())
            self.assertTrue(verified_trusted_root.is_file())
            self.assertEqual(report["bundle"], existing_record(verified_bundle))
            self.assertEqual(report["trustedRoot"], existing_record(verified_trusted_root))
            self.assertEqual(report["result"], "verifiedByGitHubCLIWithOfflineBundle")
            self.assertIn(
                "public/release-notes/1.0.0-rc.1.md",
                {item["filename"] for item in report["subjects"]},
            )
            gh_log = (directory / "mock-gh.log").read_text(encoding="utf-8")
            self.assertIn(".inventory/final-subject-checksums.txt", gh_log)
            self.assertIn(
                "--predicate-type https://spdx.dev/Document/v2.3",
                gh_log,
            )
            self.assertIn("--custom-trusted-root", gh_log)
            self.assertIn("--bundle ", gh_log)
            self.assertIn("attestation-bundle.snapshot.jsonl", gh_log)
            self.assertNotIn(f"--bundle {verified_bundle}", gh_log)

            unsafe_call = directory / "old-gh-attestation-call"
            mock_gh.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf 'gh version 2.92.0 (unsafe fixture)\\n'\n"
                "  exit 0\n"
                "fi\n"
                f": > {json.dumps(str(unsafe_call))}\n",
                encoding="utf-8",
            )
            mock_gh.chmod(0o755)
            old_version_output = private / "old-version-verification.json"
            old_version_bundle = private / "old-version-bundle.jsonl"
            old_version_root = private / "old-version-trusted-root.jsonl"
            old_version = subprocess.run(
                (
                    "/bin/bash",
                    str(SCRIPTS / "verify_rc_attestations.sh"),
                    "--manifest", str(manifest),
                    "--artifacts-dir", str(artifacts),
                    "--subject-checksums", str(subject_checksums),
                    "--output", str(old_version_output),
                    "--bundle-output", str(old_version_bundle),
                    "--trusted-root-output", str(old_version_root),
                ),
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(old_version.returncode, 0)
            self.assertIn("2.93.0 or newer", old_version.stderr)
            self.assertFalse(unsafe_call.exists())
            self.assertFalse(old_version_output.exists())
            self.assertFalse(old_version_bundle.exists())
            self.assertFalse(old_version_root.exists())

    def test_readiness_report_never_copies_private_evidence_text(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            public = directory / "public"
            evidence = directory / "evidence"
            public.mkdir()
            evidence.mkdir()
            rc = rc_manifest(public)
            commit = rc["source"]["commit"]
            secret = "ULTRA_PRIVATE_AUDIT_MARKER_8472"

            contract_path = public / "public-contract-freeze.json"
            write(contract_path, load(ROOT / "Contracts/v1/public-contract-freeze.json"))
            rc["freeze"]["publicContract"] = existing_record(contract_path)

            migration_path = public / "migration-guarantee.json"
            migration = load(CONFIG / "migration-guarantee.json")
            migration["blockers"] = [secret]
            write(migration_path, migration)
            rc["artifacts"]["migrationGuarantee"] = existing_record(migration_path)

            limitations_path = public / "known-limitations.json"
            write(limitations_path, load(CONFIG / "known-limitations.json"))
            rc["artifacts"]["knownLimitations"] = existing_record(limitations_path)

            summary_path = evidence / "audit-summary.md"
            summary_path.write_text("# Public audit summary\nNo private finding detail.\n", encoding="utf-8")
            rc["artifacts"]["auditSummary"] = existing_record(summary_path)

            audit_path = evidence / "audit-closure.json"
            audit = load(CONFIG / "audit-closure.json")
            audit["scope"]["baselineCommit"] = commit
            audit["scope"]["rcCommit"] = commit
            audit["publicSummary"] = {
                "status": "verified",
                "path": summary_path.name,
                "sha256": digest_bytes(summary_path.read_bytes()),
            }
            audit["findings"] = [{
                "id": "VELA-AUDIT-900",
                "severity": "low",
                "status": "open",
                "affectedBuild": 2026071501,
                "component": "private component",
                "description": secret,
                "proof": [],
                "fixCommit": None,
                "regressionTest": None,
                "retestEvidence": [],
                "owner": "Private Security Owner",
                "disclosure": "private",
                "riskAcceptance": None,
            }]
            audit["blockers"] = [secret]
            write(audit_path, audit)

            decision_path = evidence / "go-no-go.json"
            decision = load(CONFIG / "go-no-go.json")
            decision["candidate"] = {
                "version": rc["candidate"]["version"],
                "build": rc["candidate"]["build"],
                "commit": commit,
            }
            decision["decisionReason"] = secret
            write(decision_path, decision)
            rc_path = public / "rc.json"
            write(rc_path, rc)
            output = directory / "readiness.json"
            result = run(
                "generate_v1_readiness_report.py",
                "--rc", str(rc_path),
                "--go-no-go", str(decision_path),
                "--migration", str(migration_path),
                "--audit", str(audit_path),
                "--audit-summary", str(summary_path),
                "--known-limitations", str(limitations_path),
                "--repository-root", str(ROOT),
                "--evidence-root", str(evidence),
                "--public-contract", str(contract_path),
                "--output", str(output),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            serialized = output.read_text(encoding="utf-8")
            self.assertNotIn(secret, serialized)
            report = load(output)
            self.assertIn("audit decision: noGo", report["blockers"])
            self.assertIn("migration decision: noGo", report["blockers"])
            self.assertEqual(report["audit"]["criticalHighOpenCount"], 0)
            self.assertEqual(report["schemaVersion"], 2)
            self.assertEqual(len(report["migration"]["stores"]), 21)
            self.assertEqual(report["migration"]["stores"]["scenes"], "blockedAbsentSurface")
            self.assertEqual(
                report["migration"]["stores"]["cliInstallMetadata"],
                "blockedAbsentSurface",
            )


if __name__ == "__main__":
    unittest.main()
