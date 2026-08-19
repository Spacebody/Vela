from __future__ import annotations

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Hardening/scripts"
FIXTURES = ROOT / "Hardening/tests/fixtures"
sys.path.insert(0, str(SCRIPTS))

from json_schema import SchemaError, validate  # noqa: E402
from validate_hardening_config import (  # noqa: E402
    missing_release_required_surfaces,
    release_blockers,
)


def run(*arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True)
    if result.returncode != expected:
        raise AssertionError(
            f"expected {expected}, got {result.returncode}: {' '.join(arguments)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class ArchitectureTests(unittest.TestCase):
    def test_generator_is_deterministic_and_matches_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            architecture = Path(directory) / "architecture.json"
            attack = Path(directory) / "attack.json"
            command = (
                sys.executable,
                str(SCRIPTS / "generate_architecture_manifest.py"),
                "--repository-root", str(ROOT),
                "--architecture-output", str(architecture),
                "--attack-surface-output", str(attack),
            )
            run(*command)
            self.assertEqual(
                architecture.read_bytes(),
                (ROOT / "Hardening/config/architecture-freeze.json").read_bytes(),
            )
            self.assertEqual(
                attack.read_bytes(),
                (ROOT / "Hardening/config/attack-surface.json").read_bytes(),
            )

    def test_live_freeze_validation(self) -> None:
        run(sys.executable, str(SCRIPTS / "validate_architecture_freeze.py"))


class ConfigurationTests(unittest.TestCase):
    def test_release_surface_detection_reports_partial_absence(self) -> None:
        release = {
            "releaseRequirements": {
                "requireCLI": True,
                "requireAppIntents": True,
                "requireAutomationProtocol": True,
                "requireSceneSchema": True,
            }
        }
        compatibility = {
            "components": {"cli": None},
            "cliProtocol": None,
            "automationProtocol": None,
            "schemas": {"scene": 1},
        }
        architecture = {
            "identifiers": {"appIntentIdentifiers": []},
            "absentSurfaces": [
                "productionCLI",
                "productionAutomationSocket",
                "productionAppIntents",
            ],
        }
        self.assertEqual(
            missing_release_required_surfaces(release, compatibility, architecture),
            {"CLI", "AppIntents", "Automation"},
        )

    def test_release_surface_detection_does_not_hide_one_missing_surface(self) -> None:
        release = {
            "releaseRequirements": {
                "requireCLI": False,
                "requireAppIntents": True,
                "requireAutomationProtocol": False,
                "requireSceneSchema": False,
            }
        }
        compatibility = {
            "components": {"cli": "vela"},
            "cliProtocol": 1,
            "automationProtocol": 1,
            "schemas": {"scene": 1},
        }
        architecture = {
            "identifiers": {"appIntentIdentifiers": []},
            "absentSurfaces": ["productionAppIntents"],
        }
        self.assertEqual(
            missing_release_required_surfaces(release, compatibility, architecture),
            {"AppIntents"},
        )

    def test_candidate_stage_defers_only_artifact_bound_stop_ship_conditions(self) -> None:
        policy = {
            "rules": [
                {"condition": "externalAuditIncomplete", "blocks": ["stable"]},
                {"condition": "soak72hIncomplete", "blocks": ["stable"]},
                {"condition": "signedNotarizedBetaArtifactMissing", "blocks": ["stable"]},
            ]
        }
        readiness = {
            "issues": [],
            "conditions": [
                {"id": "externalAuditIncomplete", "active": True},
                {"id": "soak72hIncomplete", "active": True},
                {"id": "signedNotarizedBetaArtifactMissing", "active": True},
            ],
        }
        self.assertEqual(
            release_blockers(policy, readiness, "stable", "candidate-stage"),
            ["externalAuditIncomplete"],
        )
        self.assertEqual(
            release_blockers(policy, readiness, "stable", "promotion"),
            [
                "externalAuditIncomplete",
                "signedNotarizedBetaArtifactMissing",
                "soak72hIncomplete",
            ],
        )

    def test_all_config_is_structurally_and_semantically_valid(self) -> None:
        run(sys.executable, str(SCRIPTS / "validate_hardening_config.py"))

    def test_real_release_gates_remain_blocked(self) -> None:
        result = run(
            sys.executable,
            str(SCRIPTS / "validate_stop_ship.py"),
            "--channel", "publicBeta",
            expected=1,
        )
        self.assertIn("Stop-Ship active", result.stderr)

    def test_schema_rejects_unknown_properties(self) -> None:
        schema = json.loads((ROOT / "Hardening/schemas/evidence-policy.schema.json").read_text())
        value = json.loads((ROOT / "Hardening/config/evidence-policy.json").read_text())
        value["remoteDeviceID"] = True
        with self.assertRaises(SchemaError):
            validate(value, schema)

    def test_schema_rejects_non_finite_numbers_and_noncanonical_formats(self) -> None:
        with self.assertRaises(SchemaError):
            validate(float("nan"), {"type": "number", "minimum": 0, "maximum": 1})
        with self.assertRaises(SchemaError):
            validate("59c5c38bea9a4c11b731e7550c0e8dfb", {"type": "string", "format": "uuid"})
        with self.assertRaises(SchemaError):
            validate("2026-07-14T00:00:00", {"type": "string", "format": "date-time"})

    def test_required_real_migration_evidence_fails(self) -> None:
        result = run(
            sys.executable,
            str(SCRIPTS / "validate_hardening_config.py"),
            "--require-migration-evidence",
            expected=1,
        )
        self.assertIn("migration evidence is incomplete", result.stderr)

    def test_required_performance_calibration_fails(self) -> None:
        result = run(
            sys.executable,
            str(SCRIPTS / "validate_hardening_config.py"),
            "--require-calibrated-performance",
            expected=1,
        )
        self.assertIn("not been calibrated", result.stderr)


class EvidenceTests(unittest.TestCase):
    def test_test_run_manifest_rejects_a_build_outside_the_freeze(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = run(
                sys.executable,
                str(SCRIPTS / "create_test_run_manifest.py"),
                "--build", "1",
                "--core-version", "factory-v1.19.28",
                "--channel", "development",
                "--macos-build", "test-build",
                "--memory-gb", "16",
                "--user-type", "standard",
                "--output", str(Path(directory) / "manifest.json"),
                expected=1,
            )
            self.assertIn("does not match architecture freeze", result.stderr)

    def test_valid_bounded_evidence_passes(self) -> None:
        run(
            sys.executable,
            str(SCRIPTS / "validate_test_evidence.py"),
            str(FIXTURES / "evidence-valid/manifest.json"),
            "--evidence-root", str(FIXTURES / "evidence-valid"),
        )

    def test_sensitive_evidence_fails(self) -> None:
        result = run(
            sys.executable,
            str(SCRIPTS / "scan_beta_evidence.py"),
            str(FIXTURES / "evidence-sensitive.json"),
            expected=1,
        )
        self.assertIn("forbidden-field", result.stderr)

    def test_escaped_and_fake_synthetic_urls_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            escaped = Path(directory) / "escaped.json"
            escaped.write_text('{"message":"https:\\/\\/private.example\\/path"}\n', encoding="utf-8")
            result = run(
                sys.executable,
                str(SCRIPTS / "scan_beta_evidence.py"),
                str(escaped),
                expected=1,
            )
            self.assertIn("raw-url", result.stderr)
            fake = Path(directory) / "fake.json"
            fake.write_text('{"message":"https://example.invalid.evil.com/path"}\n', encoding="utf-8")
            result = run(
                sys.executable,
                str(SCRIPTS / "scan_beta_evidence.py"),
                str(fake),
                "--allow-synthetic-urls",
                expected=1,
            )
            self.assertIn("raw-url", result.stderr)

    def test_aggregate_rejects_not_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            shutil.copytree(FIXTURES / "evidence-valid", directory, dirs_exist_ok=True)
            source = Path(directory) / "manifest.json"
            manifest = json.loads(source.read_text())
            manifest["tests"][0]["status"] = "notRun"
            output = Path(directory) / "summary.json"
            write(source, manifest)
            run(
                sys.executable,
                str(SCRIPTS / "aggregate_soak_results.py"),
                str(source), "--output", str(output),
                expected=1,
            )
            self.assertFalse(json.loads(output.read_text())["passed"])

    def test_aggregate_accepts_passing_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "summary.json"
            run(
                sys.executable,
                str(SCRIPTS / "aggregate_soak_results.py"),
                str(FIXTURES / "evidence-valid/manifest.json"),
                "--output", str(output),
            )
            self.assertTrue(json.loads(output.read_text())["passed"])


class FaultAndSoakTests(unittest.TestCase):
    def test_fault_matrix_is_deterministic_and_not_executed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            for output in (first, second):
                run(
                    sys.executable,
                    str(SCRIPTS / "generate_fault_matrix.py"),
                    str(ROOT / "Hardening/config/fault-plan.json"),
                    str(output),
                )
            self.assertEqual(first.read_bytes(), second.read_bytes())
            matrix = json.loads(first.read_text())
            self.assertTrue(matrix["cases"])
            self.assertEqual({item["status"] for item in matrix["cases"]}, {"notRun"})
            self.assertEqual({item["cleanupStatus"] for item in matrix["cases"]}, {"notRun"})

    def test_soak_is_dry_run_by_default(self) -> None:
        result = run(
            sys.executable,
            str(SCRIPTS / "run_soak_matrix.py"),
            str(ROOT / "Hardening/config/soak-matrix.json"),
            "--only", "help-search-100",
        )
        self.assertIn("no scenario or cleanup command was executed", result.stdout)

    def test_non_destructive_soak_executes_bounded_argv_and_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mapping = {
                "schemaVersion": 1,
                "commands": {
                    "help.searchFixture": {"argv": ["/usr/bin/true"]},
                    "help.closeWindow": {"argv": ["/usr/bin/true"]},
                },
            }
            map_path = Path(directory) / "commands.json"
            output = Path(directory) / "result.json"
            write(map_path, mapping)
            run(
                sys.executable,
                str(SCRIPTS / "run_soak_matrix.py"),
                str(ROOT / "Hardening/config/soak-matrix.json"),
                "--only", "help-search-100",
                "--command-map", str(map_path),
                "--execute", "--output", str(output),
            )
            result = json.loads(output.read_text())
            self.assertTrue(result["passed"])
            self.assertEqual(result["results"][0]["iterations"], 100)
            self.assertEqual(result["results"][0]["cleanup"], "passed")

    def test_destructive_soak_refuses_without_all_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mapping = {
                "schemaVersion": 1,
                "commands": {
                    "network.backendTransition": {"argv": ["/usr/bin/true"]},
                    "network.restoreInitialState": {"argv": ["/usr/bin/true"]},
                },
            }
            map_path = Path(directory) / "commands.json"
            output = Path(directory) / "result.json"
            write(map_path, mapping)
            result = run(
                sys.executable,
                str(SCRIPTS / "run_soak_matrix.py"),
                str(ROOT / "Hardening/config/soak-matrix.json"),
                "--only", "backend-transition-100",
                "--command-map", str(map_path),
                "--execute", "--output", str(output),
                expected=2,
            )
            self.assertIn("VELA_RUN_DESTRUCTIVE_BETA_TESTS", result.stderr)


class PerformanceTests(unittest.TestCase):
    def fixture(self, approved: bool = True) -> tuple[dict, dict, dict]:
        budgets = {
            "schemaVersion": 1,
            "calibration": {
                "status": "approved" if approved else "pending",
                "referenceEnvironmentID": "test-env" if approved else None,
                "approvedBy": "Performance Owner" if approved else None,
                "approvedAt": "2026-07-14T00:00:00+00:00" if approved else None,
                "evidencePath": "private/baseline.json" if approved else None,
            },
            "relativeRegression": {"medianPercent": 15, "p95Percent": 20, "memoryHighWaterPercent": 15},
            "budgets": [
                {
                    "id": "help.search",
                    "unit": "milliseconds",
                    "measurement": "synthetic fixture",
                    "minimumSamples": 10,
                    "durationSeconds": None,
                    "approvedAbsoluteCeiling": 150 if approved else None,
                }
            ],
        }
        baseline = {
            "schemaVersion": 1,
            "status": "approvedBaseline" if approved else "measured",
            "environmentID": "test-env",
            "build": 2026071401,
            "metrics": {"help.search": {"samples": 10, "median": 100, "p95": 110, "unit": "milliseconds", "evidencePath": "private/before.json"}},
        }
        current = {
            "schemaVersion": 1,
            "status": "measured",
            "environmentID": "test-env",
            "build": 2026071402,
            "metrics": {"help.search": {"samples": 10, "median": 105, "p95": 115, "unit": "milliseconds", "evidencePath": "private/current.json"}},
        }
        return budgets, baseline, current

    def compare(self, budgets: dict, baseline: dict, current: dict, *extra: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("budgets.json", "baseline.json", "current.json")]
            for path, value in zip(paths, (budgets, baseline, current), strict=True):
                write(path, value)
            return run(
                sys.executable,
                str(SCRIPTS / "compare_performance_baseline.py"),
                *(str(path) for path in paths),
                *extra,
                expected=expected,
            )

    def test_approved_comparable_performance_passes(self) -> None:
        self.compare(*self.fixture())

    def test_pending_calibration_never_declares_gate(self) -> None:
        budgets, baseline, current = self.fixture(approved=False)
        result = self.compare(budgets, baseline, current, expected=1)
        self.assertIn("refusing to declare a passing gate", result.stderr)
        exploratory = self.compare(budgets, baseline, current, "--exploratory")
        self.assertIn("not an approved Release gate", exploratory.stdout)

    def test_regression_fails(self) -> None:
        budgets, baseline, current = self.fixture()
        current["metrics"]["help.search"]["median"] = 140
        current["metrics"]["help.search"]["p95"] = 160
        result = self.compare(budgets, baseline, current, expected=1)
        self.assertIn("median regression", result.stderr)


class SupplyChainAndCrashTests(unittest.TestCase):
    def test_audit_generator_never_deletes_a_preexisting_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing-packet"
            output.mkdir()
            sentinel = output / "keep.txt"
            sentinel.write_text("do not delete\n", encoding="utf-8")
            run(
                sys.executable,
                str(SCRIPTS / "generate_audit_packet.py"),
                "--version", "0.8.0",
                "--build", "2026071402",
                "--tag", "v0.8.0",
                "--artifact", str(sentinel),
                "--release-manifest", str(sentinel),
                "--sbom", str(sentinel),
                "--output", str(output),
                expected=1,
            )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "do not delete\n")

    def test_all_repository_workflows_are_pinned(self) -> None:
        run(
            sys.executable,
            str(SCRIPTS / "validate_github_workflows.py"),
            str(ROOT / ".github/workflows"),
        )

    def test_workflow_validator_rejects_tag_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workflow = Path(directory) / "bad.yml"
            workflow.write_text(
                "name: bad\non: push\npermissions:\n  contents: read\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n",
                encoding="utf-8",
            )
            result = run(
                sys.executable,
                str(SCRIPTS / "validate_github_workflows.py"),
                str(workflow),
                expected=1,
            )
            self.assertIn("not pinned to a full SHA", result.stderr)

    def test_workflow_validator_distinguishes_top_level_and_job_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workflow = Path(directory) / "job-permissions.yml"
            workflow.write_text(
                "name: bad permissions\non: push\npermissions:\n  contents: read\n"
                "jobs:\n  x:\n    permissions:\n      contents: write\n"
                "    runs-on: ubuntu-latest\n    steps:\n      - run: /usr/bin/true\n",
                encoding="utf-8",
            )
            result = run(
                sys.executable,
                str(SCRIPTS / "validate_github_workflows.py"),
                str(workflow),
                expected=1,
            )
            self.assertIn("absent from the reviewed registry policy", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow = root / ".github/workflows/release.yml"
            registry = root / "Hardening/config/github-actions.json"
            workflow.parent.mkdir(parents=True)
            registry.parent.mkdir(parents=True)
            permission_policy = {
                "workflow": ".github/workflows/release.yml",
                "topLevelPermissions": {"contents": "read"},
                "jobOverrides": {
                    "attest": {
                        "contents": "read",
                        "id-token": "write",
                        "attestations": "write",
                        "artifact-metadata": "write",
                    }
                },
            }
            write(
                registry,
                {
                    "schemaVersion": 2,
                    "verifiedAt": "2026-07-14",
                    "actions": [],
                    "workflowPermissionPolicies": [permission_policy],
                    "notes": [],
                },
            )
            valid = (
                "name: reviewed permissions\non: workflow_dispatch\n"
                "permissions:\n  contents: read\n"
                "jobs:\n  attest:\n    permissions:\n"
                "      contents: read\n      id-token: write\n"
                "      attestations: write\n      artifact-metadata: write\n"
                "    runs-on: macos-latest\n    steps:\n      - run: /usr/bin/true\n"
            )
            workflow.write_text(valid, encoding="utf-8")
            run(
                sys.executable,
                str(SCRIPTS / "validate_github_workflows.py"),
                "--registry", str(registry),
                str(workflow),
            )

            drifted_workflows = {
                "added permission": valid.replace(
                    "      artifact-metadata: write\n",
                    "      artifact-metadata: write\n      issues: write\n",
                ),
                "weakened required permission": valid.replace(
                    "      artifact-metadata: write\n",
                    "      artifact-metadata: read\n",
                ),
                "renamed privileged job": valid.replace("  attest:\n", "  provenance:\n"),
                "quoted permission key": valid.replace(
                    "    permissions:\n",
                    "    \"permissions\":\n",
                ),
            }
            for name, drifted in drifted_workflows.items():
                with self.subTest(name=name):
                    workflow.write_text(drifted, encoding="utf-8")
                    result = run(
                        sys.executable,
                        str(SCRIPTS / "validate_github_workflows.py"),
                        "--registry", str(registry),
                        str(workflow),
                        expected=1,
                    )
                    self.assertIn(
                        "job-level permissions differ from the reviewed registry policy",
                        result.stderr,
                    )

            write(
                registry,
                {
                    "schemaVersion": 2,
                    "verifiedAt": "2026-07-14",
                    "actions": [],
                    "workflowPermissionPolicies": [
                        permission_policy,
                        {
                            "workflow": ".github/workflows/extra.yml",
                            "topLevelPermissions": {"contents": "read"},
                            "jobOverrides": {"publish": {"contents": "write"}},
                        },
                    ],
                    "notes": [],
                },
            )
            workflow.write_text(valid, encoding="utf-8")
            result = run(
                sys.executable,
                str(SCRIPTS / "validate_github_workflows.py"),
                "--registry", str(registry),
                str(workflow),
                expected=2,
            )
            self.assertIn("only the exact reviewed V0.9", result.stderr)

    def test_crash_signature_accepts_symbols_and_rejects_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "signature.json"
            run(
                sys.executable,
                str(SCRIPTS / "create_crash_signature.py"),
                "--component", "Vela",
                "--build", "2026071402",
                "--exception", "EXC_BAD_ACCESS",
                "--category", "ui",
                "--frame", "Vela.OnboardingFlowView.body",
                "--output", str(output),
            )
            value = json.loads(output.read_text())
            self.assertFalse(value["containsUserData"])
            self.assertEqual(len(value["signatureSHA256"]), 64)
            result = run(
                sys.executable,
                str(SCRIPTS / "create_crash_signature.py"),
                "--component", "Vela",
                "--build", "2026071402",
                "--exception", "EXC_BAD_ACCESS",
                "--category", "ui",
                "--frame", "/Users/private/File.swift:42",
                "--output", str(Path(directory) / "bad.json"),
                expected=1,
            )
            self.assertIn("sanitized application symbols", result.stderr)

    def test_shell_tools_parse(self) -> None:
        for name in (
            "snapshot_process_resources.sh", "capture_cleanup_evidence.sh",
            "capture_xctrace.sh", "scan_release_fault_controls.sh",
            "verify_release_attestation.sh", "verify_dsym_uuid.sh", "symbolicate_address.sh",
        ):
            run("/bin/bash", "-n", str(SCRIPTS / name))


if __name__ == "__main__":
    unittest.main()
