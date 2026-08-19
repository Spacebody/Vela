from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ReleaseCandidate.tests.test_candidate_stage_evidence import (
    APP_NOTARY_ID,
    BUILD,
    DMG_NOTARY_ID,
    TAG,
    VERSION,
    CandidateStageFixture,
)


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "ReleaseCandidate/scripts"
CONFIG = ROOT / "ReleaseCandidate/config"
APPROVAL_ROLES = (
    "Release",
    "Security",
    "Reliability",
    "Product",
    "Support",
    "AccessibilityLocalization",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: dict, *, private: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if private:
        path.chmod(0o600)


def record(path: Path) -> dict:
    data = path.read_bytes()
    return {"filename": path.name, "sha256": digest(data), "size": len(data)}


def reference(root: Path, path: Path) -> dict:
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": digest(path.read_bytes()),
    }


def replace_argument(arguments: tuple[str, ...], option: str, value: Path | str) -> tuple[str, ...]:
    updated = list(arguments)
    updated[updated.index(option) + 1] = str(value)
    return tuple(updated)


def run_closure(
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = dict(environment or os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(
        (sys.executable, str(SCRIPTS / "generate_promotion_closure.py"), *arguments),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
    )


class PromotionClosureFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.stage_fixture = CandidateStageFixture(root)
        self.stage_root = self.stage_fixture.evidence
        self.public = root / "public-artifacts"
        self.public.mkdir(mode=0o755)
        self.evidence = root / "promotion-evidence"
        self.evidence.mkdir(mode=0o700)
        self.private = self.evidence / "private"
        self.private.mkdir(mode=0o700)
        generated = self.stage_fixture.generate()
        if generated.returncode != 0:
            raise AssertionError(generated.stderr)
        self.commit = self.stage_fixture.commit

        # The immutable candidate receipt keeps update artifacts under public/updates.
        # The public release bundle exposes the same bytes by their manifest basenames.
        self.dmg = self.public / self.stage_fixture.dmg.name
        self.appcast = self.public / self.stage_fixture.appcast.name
        self.release_manifest = self.public / self.stage_fixture.app_receipt.name
        self.sbom = self.public / self.stage_fixture.sbom.name
        self.architecture = self.public / self.stage_fixture.architecture.name
        shutil.copyfile(self.stage_fixture.dmg, self.dmg)
        shutil.copyfile(self.stage_fixture.appcast, self.appcast)
        shutil.copyfile(self.stage_fixture.app_receipt, self.release_manifest)
        shutil.copyfile(self.stage_fixture.sbom, self.sbom)
        shutil.copyfile(self.stage_fixture.architecture, self.architecture)

        contract = load(ROOT / "Contracts/v1/public-contract-freeze.json")
        implemented = {
            "productionCLI",
            "productionAutomationSocket",
        }
        contract["absentSurfaces"] = [
            surface for surface in contract["absentSurfaces"] if surface not in implemented
        ]
        self.public_contract = self.public / "public-contract-freeze.json"
        write_json(self.public_contract, contract)

        self.documentation = self.public / "documentation-manifest.json"
        self.privacy = self.public / "PrivacyInfo.xcprivacy"
        self.migration = self.public / "migration-guarantee.json"
        self.audit_summary = self.public / "audit-summary.md"
        self.limitations = self.public / "known-limitations.json"
        write_json(self.documentation, {"schemaVersion": 1, "articles": []})
        write_json(self.privacy, {"NSPrivacyTracking": False})
        write_json(self.migration, {"schemaVersion": 1, "decision": "go"})
        self.audit_summary.write_text("# Public audit summary\nAll release findings closed.\n", encoding="utf-8")
        write_json(self.limitations, {"schemaVersion": 1, "version": "1.0.0"})

        self.public_checksums = self.public / f"artifact-checksums-{VERSION}.txt"
        checksummed = (
            self.release_manifest,
            self.dmg,
            self.sbom,
            self.appcast,
        )
        self.public_checksums.write_text(
            "".join(f"{digest(path.read_bytes())}  {path.name}\n" for path in checksummed),
            encoding="utf-8",
        )

        freezes = {
            "publicContract": record(self.public_contract),
            "architecture": record(self.architecture),
            "documentation": record(self.documentation),
            "privacy": record(self.privacy),
        }
        artifacts = {
            "releaseManifest": record(self.release_manifest),
            "dmg": record(self.dmg),
            "sbom": record(self.sbom),
            "appcast": record(self.appcast),
            "checksums": record(self.public_checksums),
            "migrationGuarantee": record(self.migration),
            "auditSummary": record(self.audit_summary),
            "knownLimitations": record(self.limitations),
        }
        self.rc = {
            "schemaVersion": 1,
            "candidate": {
                "version": VERSION,
                "marketingVersion": "1.0.0",
                "build": BUILD,
                "channel": "rc",
                "appUpdateChannel": "beta",
                "prereleaseLabel": "RC 1",
            },
            "source": {"commit": self.commit, "tag": TAG, "dirty": False},
            "freeze": freezes,
            "quality": {
                gate: "pass"
                for gate in (
                    "stopShip",
                    "contracts",
                    "migration",
                    "securityAudit",
                    "soak",
                    "performance",
                    "accessibilityPrivacy",
                    "installation",
                    "artifact",
                    "supportIncident",
                )
            },
            "artifacts": artifacts,
            "signing": {
                "certificateSHA256": self.stage_fixture.certificate_sha256,
                "appNotary": {"submissionID": APP_NOTARY_ID, "status": "Accepted"},
                "dmgNotary": {"submissionID": DMG_NOTARY_ID, "status": "Accepted"},
                "bundleVerificationRequired": True,
            },
            "provenance": {
                "toolchain": {"xcode": "fixture toolchain"},
                "workflow": {
                    "repository": None,
                    "runID": None,
                    "runnerClass": "local/macos/arm64",
                },
                "attestation": {
                    "status": "pendingExternal",
                    "evidence": None,
                    "subjects": [
                        {
                            "filename": artifacts[name]["filename"],
                            "sha256": artifacts[name]["sha256"],
                        }
                        for name in ("dmg", "sbom")
                    ],
                    "policy": {
                        "workflowPath": ".github/workflows/release.yml",
                        "environment": "production",
                        "verificationRepository": "Spacebody/Vela",
                        "requiredPermissions": [
                            "id-token:write",
                            "attestations:write",
                            "artifact-metadata:write",
                        ],
                    },
                },
            },
        }
        self.rc_path = self.public / f"rc-manifest-{VERSION}.json"
        write_json(self.rc_path, self.rc)

        self.install_result = self.private / "installation-results.json"
        write_json(self.install_result, {"candidate": VERSION, "passedCases": 58}, private=True)
        self.matrix = load(CONFIG / "installation-matrix.json")
        self.matrix["candidate"] = {
            "version": VERSION,
            "build": BUILD,
            "commit": self.commit,
            "artifact": {"kind": "dmg", **record(self.dmg)},
        }
        install_reference = reference(self.evidence, self.install_result)
        for case in self.matrix["cases"]:
            case["status"] = "passed"
            case["evidence"] = [copy.deepcopy(install_reference)]
        self.matrix["decision"] = "go"
        self.matrix["blockers"] = []
        self.matrix_path = self.private / "installation-matrix-final.json"
        write_json(self.matrix_path, self.matrix, private=True)

        public_records = list(self.rc["freeze"].values()) + list(self.rc["artifacts"].values())
        attested = [*public_records, record(self.rc_path)]
        by_name = {item["filename"]: item for item in attested}
        if len(by_name) != len(attested):
            raise AssertionError("fixture contains duplicate attestation subjects")
        self.subject_checksums = self.evidence / "final-subject-checksums.txt"
        self.subject_checksums.write_text(
            "".join(
                f"{item['sha256']}  {item['filename']}\n"
                for item in sorted(attested, key=lambda value: value["filename"])
            ),
            encoding="utf-8",
        )
        self.attestation_bundle = self.private / "attestation-bundles.jsonl"
        self.attestation_bundle.write_text(
            '{"fixture":"signed-bundle"}\n',
            encoding="utf-8",
        )
        self.attestation_bundle.chmod(0o600)
        self.attestation_trusted_root = self.private / "trusted-root.jsonl"
        self.attestation_trusted_root.write_text(
            '{"fixture":"trusted-root"}\n',
            encoding="utf-8",
        )
        self.attestation_trusted_root.chmod(0o600)
        self.attestation = {
            "schemaVersion": 1,
            "repository": "Spacebody/Vela",
            "signerWorkflow": "github.com/Spacebody/Vela/.github/workflows/release.yml",
            "source": {"commit": self.commit, "ref": f"refs/tags/{TAG}"},
            "bundle": record(self.attestation_bundle),
            "trustedRoot": record(self.attestation_trusted_root),
            "subjectChecksums": record(self.subject_checksums),
            "subjects": sorted(attested, key=lambda value: value["filename"]),
            "verifiedAt": "2025-01-01T01:02:03Z",
            "result": "verifiedByGitHubCLIWithOfflineBundle",
        }
        self.attestation_path = self.private / "attestation-verification.json"
        write_json(self.attestation_path, self.attestation, private=True)

        self.generic_gate = self.private / "generic-gate-evidence.json"
        write_json(self.generic_gate, {"candidate": VERSION, "result": "pass"}, private=True)
        generic_reference = reference(self.evidence, self.generic_gate)
        self.go = load(CONFIG / "go-no-go.json")
        self.go["candidate"] = {"version": VERSION, "build": BUILD, "commit": self.commit}
        for gate in self.go["gates"]:
            gate["status"] = "pass"
            gate["evidence"] = [copy.deepcopy(generic_reference)]
            if gate["id"] == "installation":
                gate["evidence"] = [reference(self.evidence, self.matrix_path)]
            elif gate["id"] == "artifact":
                gate["evidence"] = [reference(self.evidence, self.attestation_path)]
        self.go["decision"] = "go"
        self.go["decisionReason"] = "All ten gates and accountable approvals passed."
        self.go["approvals"] = [
            {
                "role": role,
                "approver": f"{role} Owner",
                "approvedAt": "2025-01-01T02:00:00Z",
                "candidateVersion": VERSION,
                "candidateBuild": BUILD,
                "candidateCommit": self.commit,
                "artifactSHA256": record(self.dmg)["sha256"],
            }
            for role in APPROVAL_ROLES
        ]
        self.go_path = self.private / "go-no-go-final.json"
        write_json(self.go_path, self.go, private=True)
        self.output = self.private / f"promotion-closure-{VERSION}.json"

        self.mock_bin = root / "mock-bin"
        self.mock_bin.mkdir()
        self.gh_log = root / "gh.log"
        self.gh_fail = self.mock_bin / "fail"
        mock_gh = self.mock_bin / "gh"
        mock_gh.write_text(
            """#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "${1:-}" == "version" ]]; then
  printf '%s\\n' 'gh version 2.95.0 (fixture)'
  exit 0
fi
[[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}${POISON_CONFIG:-}" ]] || exit 45
[[ -n "${HOME:-}" && -n "${GH_CONFIG_DIR:-}" && -n "${XDG_CONFIG_HOME:-}" ]] || exit 46
printf '%s\\n' "$*" >>"${base}/gh.log"
[[ ! -e "$(dirname "$0")/fail" ]] || exit 44
if [[ -f "$(dirname "$0")/mutate-bound-path" && ! -e "$(dirname "$0")/mutated-bound" ]]; then
  : >"$(dirname "$0")/mutated-bound"
  mutate_bound="$(/bin/cat "$(dirname "$0")/mutate-bound-path")"
  printf '%s\\n' '{"attacker":"replacement"}' >>"${mutate_bound}"
fi
bundle=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "--bundle" ]]; then bundle="${argument}"; fi
  previous="${argument}"
done
[[ -n "${bundle}" && -f "${bundle}" ]] || exit 43
printf '%s\\n' '[{"attestation":{"fixture":"signed-bundle"},"verificationResult":{"verified":true}}]'
""",
            encoding="utf-8",
        )
        mock_gh.chmod(0o755)
        self.environment = dict(os.environ)
        self.environment["PATH"] = f"{self.mock_bin}:{self.environment.get('PATH', '')}"
        self.environment["GH_TOKEN"] = "must-not-survive-offline-isolation"
        self.environment["GH_ENTERPRISE_TOKEN"] = "must-not-survive-offline-isolation"
        self.environment["POISON_CONFIG"] = "must-not-survive-offline-isolation"

    def arguments(self, *, output: Path | None = None) -> tuple[str, ...]:
        return (
            "--candidate-version",
            VERSION,
            "--build",
            str(BUILD),
            "--commit",
            self.commit,
            "--go-no-go",
            str(self.go_path),
            "--installation-matrix",
            str(self.matrix_path),
            "--candidate-stage-evidence",
            str(self.stage_fixture.manifest),
            "--candidate-stage-root",
            str(self.stage_root),
            "--rc-manifest",
            str(self.rc_path),
            "--attestation-verification",
            str(self.attestation_path),
            "--attestation-bundle",
            str(self.attestation_bundle),
            "--attestation-trusted-root",
            str(self.attestation_trusted_root),
            "--subject-checksums",
            str(self.subject_checksums),
            "--public-artifacts-dir",
            str(self.public),
            "--evidence-root",
            str(self.evidence),
            "--output",
            str(output or self.output),
        )

    def run(self, *, output: Path | None = None) -> subprocess.CompletedProcess[str]:
        return run_closure(
            *self.arguments(output=output),
            environment=self.environment,
        )

    def rewrite_go(self) -> None:
        write_json(self.go_path, self.go, private=True)

    def rewrite_matrix(self) -> None:
        write_json(self.matrix_path, self.matrix, private=True)

    def rewrite_attestation(self, *, sync_gate: bool = True) -> None:
        write_json(self.attestation_path, self.attestation, private=True)
        if sync_gate:
            gate = next(item for item in self.go["gates"] if item["id"] == "artifact")
            gate["evidence"] = [reference(self.evidence, self.attestation_path)]
            self.rewrite_go()


class PromotionClosureTests(unittest.TestCase):
    def with_fixture(self) -> tuple[tempfile.TemporaryDirectory[str], PromotionClosureFixture]:
        temporary = tempfile.TemporaryDirectory()
        return temporary, PromotionClosureFixture(Path(temporary.name))

    def test_closes_exact_candidate_to_private_immutable_receipt(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            # Legitimate framework/archive links outside selected receipt paths must not
            # be confused with evidence-path symlink attacks.
            framework = fixture.stage_root / "private/archive/Sparkle.framework/Versions"
            (framework / "A").mkdir(parents=True)
            (framework / "Current").symlink_to("A", target_is_directory=True)

            result = fixture.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            value = load(fixture.output)
            self.assertEqual(value["visibility"], "private")
            self.assertEqual(value["stage"], {
                "decision": "go",
                "promotionStatus": "closed",
                "verifyFilesRequired": True,
            })
            self.assertEqual(value["candidate"]["commit"], fixture.commit)
            self.assertEqual(value["artifact"], {"kind": "dmg", **record(fixture.dmg)})
            self.assertEqual(len(value["bindings"]["gateIDs"]), 10)
            self.assertEqual(set(value["bindings"]["approvalRoles"]), set(APPROVAL_ROLES))
            self.assertEqual(
                value["bindings"]["attestation"]["bundle"],
                record(fixture.attestation_bundle),
            )
            self.assertEqual(
                value["bindings"]["attestation"]["trustedRoot"],
                record(fixture.attestation_trusted_root),
            )
            verification_calls = fixture.gh_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                len(verification_calls),
                len(fixture.attestation["subjects"]) + 2,
            )
            self.assertTrue(
                all(
                    "--bundle" in call
                    and "--repo Spacebody/Vela" in call
                    and "--custom-trusted-root" in call
                    for call in verification_calls
                )
            )
            self.assertEqual(
                sum("https://spdx.dev/Document/v2.3" in call for call in verification_calls),
                1,
            )
            self.assertTrue(
                all(f"--source-digest {fixture.commit}" in call for call in verification_calls)
            )
            self.assertEqual(
                stat.S_IMODE(fixture.output.stat().st_mode) & 0o077,
                0,
            )
            repeated = fixture.run()
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("refusing to overwrite", repeated.stderr)

    def test_candidate_stage_uses_its_own_root_and_same_dmg_receipt(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            stage = load(fixture.stage_fixture.manifest)
            stage["artifacts"]["dmg"]["sha256"] = digest(b"different candidate DMG")
            write_json(fixture.stage_fixture.manifest, stage, private=True)
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("candidate-stage receipt DMG differs", result.stderr)

    def test_rejects_identity_drift_across_all_typed_inputs(self) -> None:
        mutations = ("go", "matrix", "stage", "rc", "attestation")
        for kind in mutations:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as raw:
                fixture = PromotionClosureFixture(Path(raw))
                if kind == "go":
                    fixture.go["candidate"]["build"] = BUILD + 1
                    fixture.rewrite_go()
                elif kind == "matrix":
                    fixture.matrix["candidate"]["build"] = BUILD + 1
                    fixture.rewrite_matrix()
                elif kind == "stage":
                    stage = load(fixture.stage_fixture.manifest)
                    stage["candidate"]["build"] = BUILD + 1
                    write_json(fixture.stage_fixture.manifest, stage, private=True)
                elif kind == "rc":
                    fixture.rc["source"]["commit"] = "b" * 40
                    write_json(fixture.rc_path, fixture.rc)
                else:
                    fixture.attestation["source"]["commit"] = "b" * 40
                    fixture.rewrite_attestation(sync_gate=False)
                result = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exact promotion", result.stderr)

    def test_final_matrix_must_be_go_all_passed_and_reopen_real_evidence(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.matrix["cases"][0]["status"] = "pending"
            fixture.matrix["cases"][0]["evidence"] = []
            fixture.matrix["decision"] = "noGo"
            fixture.matrix["blockers"] = ["One case is not complete."]
            fixture.rewrite_matrix()
            installation = next(
                gate for gate in fixture.go["gates"] if gate["id"] == "installation"
            )
            installation["evidence"] = [reference(fixture.evidence, fixture.matrix_path)]
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installation matrix is not closed", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.install_result.write_text("tampered evidence\n", encoding="utf-8")
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("evidence SHA-256 mismatch", result.stderr)

    def test_final_go_requires_ten_passed_gates_and_six_bound_approvals(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.go["gates"][0]["status"] = "pending"
            fixture.go["gates"][0]["evidence"] = []
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("non-pass gates", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.go["approvals"].pop()
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("approval", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.go["approvals"][0]["artifactSHA256"] = digest(b"other DMG")
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact candidate artifact", result.stderr)

    def test_installation_and_artifact_gates_require_exact_typed_references(self) -> None:
        for gate_id in ("installation", "artifact"):
            with self.subTest(gate=gate_id), tempfile.TemporaryDirectory() as raw:
                fixture = PromotionClosureFixture(Path(raw))
                gate = next(item for item in fixture.go["gates"] if item["id"] == gate_id)
                gate["evidence"] = [reference(fixture.evidence, fixture.generic_gate)]
                fixture.rewrite_go()
                result = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{gate_id} gate must reference only", result.stderr)

    def test_attestation_requires_exact_source_manifest_and_public_checksums(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.attestation["subjects"] = [
                item
                for item in fixture.attestation["subjects"]
                if item["filename"] != fixture.rc_path.name
            ]
            checksum_rows = fixture.subject_checksums.read_text(encoding="utf-8").splitlines()
            fixture.subject_checksums.write_text(
                "\n".join(
                    row for row in checksum_rows if not row.endswith(f"  {fixture.rc_path.name}")
                )
                + "\n",
                encoding="utf-8",
            )
            fixture.attestation["subjectChecksums"] = record(fixture.subject_checksums)
            fixture.rewrite_attestation()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact RC manifest", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.subject_checksums.write_text("changed inventory\n", encoding="utf-8")
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("subject-checksum inventory", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            rows = fixture.subject_checksums.read_text(encoding="utf-8").splitlines()
            fixture.subject_checksums.write_text("\n".join(rows[1:]) + "\n", encoding="utf-8")
            fixture.attestation["subjectChecksums"] = record(fixture.subject_checksums)
            fixture.rewrite_attestation()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rows differ from the verified subject set", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.public_checksums.write_text("changed public checksums\n", encoding="utf-8")
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from manifest", result.stderr)

    def test_plain_report_and_bundle_never_replace_offline_github_verification(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.gh_fail.touch()
            result = run_closure(
                *fixture.arguments(),
                environment=fixture.environment,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("offline GitHub attestation bundle verification failed", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            without_gh = dict(fixture.environment)
            without_gh["PATH"] = "/usr/bin:/bin"
            result = run_closure(
                *fixture.arguments(),
                environment=without_gh,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GitHub CLI is required", result.stderr)

    def test_attestation_bundle_bytes_are_exactly_bound(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.attestation_bundle.write_text(
                '{"fixture":"tampered-bundle"}\n',
                encoding="utf-8",
            )
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("report differs from the supplied offline bundle", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            fixture.attestation_trusted_root.write_text(
                '{"fixture":"tampered-trusted-root"}\n',
                encoding="utf-8",
            )
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("report differs from the supplied offline trusted root", result.stderr)

    def test_attestation_bundle_and_trusted_root_are_rechecked_after_snapshot(self) -> None:
        for target_name in ("bundle", "trusted-root"):
            with self.subTest(target=target_name), tempfile.TemporaryDirectory() as raw:
                fixture = PromotionClosureFixture(Path(raw))
                target = (
                    fixture.attestation_bundle
                    if target_name == "bundle"
                    else fixture.attestation_trusted_root
                )
                (fixture.mock_bin / "mutate-bound-path").write_text(
                    str(target),
                    encoding="utf-8",
                )
                result = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("changed after its immutable snapshot", result.stderr)
                self.assertFalse(fixture.output.exists())

    def test_private_evidence_root_requires_release_user_and_mode_0700(self) -> None:
        for target_name in ("root", "private"):
            with self.subTest(target=target_name), tempfile.TemporaryDirectory() as raw:
                fixture = PromotionClosureFixture(Path(raw))
                target = fixture.evidence if target_name == "root" else fixture.private
                target.chmod(0o750)
                result = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("permissions must be 0700", result.stderr)

    def test_candidate_evidence_and_public_roots_must_not_overlap(self) -> None:
        cases = (
            ("--candidate-stage-root", lambda fixture: fixture.evidence),
            ("--public-artifacts-dir", lambda fixture: fixture.private),
            ("--candidate-stage-root", lambda fixture: fixture.public),
        )
        for option, value in cases:
            with self.subTest(option=option), tempfile.TemporaryDirectory() as raw:
                fixture = PromotionClosureFixture(Path(raw))
                arguments = replace_argument(fixture.arguments(), option, value(fixture))
                result = run_closure(*arguments, environment=fixture.environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("non-overlapping roots", result.stderr)

    def test_attestation_approval_and_closure_times_are_monotonic_and_not_future(self) -> None:
        with self.subTest(case="approval-before-verification"), tempfile.TemporaryDirectory() as raw:
            fixture = PromotionClosureFixture(Path(raw))
            fixture.go["approvals"][0]["approvedAt"] = "2024-12-31T23:59:59Z"
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("at or after attestation verifiedAt", result.stderr)

        with self.subTest(case="future-approval"), tempfile.TemporaryDirectory() as raw:
            fixture = PromotionClosureFixture(Path(raw))
            fixture.go["approvals"][0]["approvedAt"] = "2999-01-01T00:00:00Z"
            fixture.rewrite_go()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("approvedAt may not be in the future", result.stderr)

        with self.subTest(case="future-verification"), tempfile.TemporaryDirectory() as raw:
            fixture = PromotionClosureFixture(Path(raw))
            fixture.attestation["verifiedAt"] = "2999-01-01T00:00:00Z"
            fixture.rewrite_attestation()
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("verifiedAt may not be in the future", result.stderr)

    def test_rejects_symlinked_input_and_public_output(self) -> None:
        temporary, fixture = self.with_fixture()
        with temporary:
            target = fixture.private / "go-no-go-target.json"
            fixture.go_path.rename(target)
            fixture.go_path.symlink_to(target)
            result = fixture.run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)

        temporary, fixture = self.with_fixture()
        with temporary:
            result = fixture.run(output=fixture.public / "promotion-closure.json")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("evidence-root/private", result.stderr)


if __name__ == "__main__":
    unittest.main()
