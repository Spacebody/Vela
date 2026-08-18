from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


LAB_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB_ROOT))
CORE_ROOT = LAB_ROOT.parent
sys.path.insert(0, str(CORE_ROOT))

from compatibility_lab import (  # noqa: E402
    CompatibilityError,
    API_CONTRACT_PATH,
    CORPUS_PATH,
    SUITE_PATH,
    atomic_write_new,
    canonical_json_bytes,
    load_json,
    load_suite,
    sha256_file,
    sha256_manifest,
    validate_api_contract,
    validate_corpus,
    validate_dedicated_host_evidence,
    validate_performance_review,
    validate_report,
)
from signed_core_identity import (  # noqa: E402
    build_signed_core_identity,
    validate_signed_core_identity,
)
from core_release_lib import CoreReleaseError  # noqa: E402


class CompatibilityLabContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.suite = load_suite()
        self.candidate_sha = hashlib.sha256(b"unsigned-upstream-v1.19.28").hexdigest()
        self.upstream_sha = self.candidate_sha
        self.factory_sha = hashlib.sha256(b"factory-v1.19.28").hexdigest()

    def test_suite_corpus_and_api_contract_are_exact(self) -> None:
        corpus, paths = validate_corpus()
        contract = validate_api_contract(self.suite)
        self.assertEqual(self.suite["transitionCount"], 20)
        self.assertEqual(self.suite["performance"]["syntheticConnections"], 1000)
        self.assertEqual(len(corpus["valid"]), 9)
        self.assertEqual(len(corpus["invalid"]), 2)
        self.assertGreaterEqual(len(paths), 14)
        self.assertEqual(set(contract["rest"]), set(self.suite["requiredRESTEndpoints"]))
        self.assertEqual(set(contract["webSockets"]), set(self.suite["requiredWebSockets"]))

    def test_pack_fixture_is_nonproduction_only(self) -> None:
        fixture = load_json(
            LAB_ROOT.parents[2]
            / "Docs"
            / "V1"
            / "Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack"
            / "fixtures"
            / "compatibility-report-v1.19.28-r1.json"
        )
        validate_report(fixture, expected_core_id="v1.19.28-r1")
        with self.assertRaisesRegex(CompatibilityError, "lacks executable lab evidence"):
            validate_report(fixture, production=True)

    def test_dedicated_host_evidence_requires_full_cleanup_matrix(self) -> None:
        evidence = self.dedicated_evidence()
        validate_dedicated_host_evidence(
            evidence,
            core_id="v1.19.28-r1",
            candidate_sha256=self.candidate_sha,
            factory_sha256=self.factory_sha,
        )
        evidence["tun"]["routesRestored"] = False
        with self.assertRaisesRegex(CompatibilityError, "routesRestored"):
            validate_dedicated_host_evidence(
                evidence,
                core_id="v1.19.28-r1",
                candidate_sha256=self.candidate_sha,
                factory_sha256=self.factory_sha,
            )

    def test_performance_review_binds_both_artifacts(self) -> None:
        review = self.performance_review()
        validate_performance_review(
            review,
            core_id="v1.19.28-r1",
            candidate_sha256=self.candidate_sha,
            factory_sha256=self.factory_sha,
        )
        review["factorySHA256"] = "3" * 64
        with self.assertRaisesRegex(CompatibilityError, "artifact identity"):
            validate_performance_review(
                review,
                core_id="v1.19.28-r1",
                candidate_sha256=self.candidate_sha,
                factory_sha256=self.factory_sha,
            )

    def test_full_report_can_pass_production_only_with_distinct_bound_evidence(self) -> None:
        report = self.full_report()
        with tempfile.TemporaryDirectory() as directory:
            dedicated_path, review_path = self.write_external_evidence(
                Path(directory),
                report,
            )
            validate_report(
                report,
                production=True,
                expected_core_id="v1.19.28-r1",
                dedicated_host_evidence_path=dedicated_path,
                performance_review_path=review_path,
            )
            report["artifacts"]["factoryExecutableSHA256"] = self.candidate_sha
            with self.assertRaisesRegex(CompatibilityError, "distinct"):
                validate_report(
                    report,
                    production=True,
                    dedicated_host_evidence_path=dedicated_path,
                    performance_review_path=review_path,
                )

    def test_forged_or_stale_suite_hash_is_rejected(self) -> None:
        report = self.full_report()
        report["artifacts"]["suiteSHA256"] = "f" * 64
        with self.assertRaisesRegex(CompatibilityError, "current checked-in suite"):
            validate_report(report)

    def test_production_candidate_must_equal_unsigned_upstream_payload(self) -> None:
        report = self.full_report()
        report["artifacts"]["candidateExecutableSHA256"] = "f" * 64
        with tempfile.TemporaryDirectory() as directory:
            dedicated_path, review_path = self.write_external_evidence(
                Path(directory), report
            )
            with self.assertRaisesRegex(CompatibilityError, "unsigned upstream"):
                validate_report(
                    report,
                    production=True,
                    dedicated_host_evidence_path=dedicated_path,
                    performance_review_path=review_path,
                )

    def test_empty_passed_evidence_and_metrics_are_rejected(self) -> None:
        report = self.full_report()
        report["evidence"]["controllerAPI"] = {}
        with self.assertRaisesRegex(CompatibilityError, "exactly cover"):
            validate_report(report)
        report = self.full_report()
        report["metrics"]["candidate"] = {}
        with self.assertRaisesRegex(CompatibilityError, "metrics fields"):
            validate_report(report)

    def test_production_revalidates_external_bytes_and_rejects_stale_evidence(self) -> None:
        report = self.full_report()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dedicated_path, review_path = self.write_external_evidence(root, report)
            dedicated_path.write_bytes(dedicated_path.read_bytes() + b" ")
            with self.assertRaisesRegex(CompatibilityError, "bytes differ"):
                validate_report(
                    report,
                    production=True,
                    dedicated_host_evidence_path=dedicated_path,
                    performance_review_path=review_path,
                )

            report = self.full_report(dedicated_generated_at="2026-05-01T00:00:00Z")
            dedicated_path, review_path = self.write_external_evidence(
                root / "stale",
                report,
            )
            with self.assertRaisesRegex(CompatibilityError, "stale"):
                validate_report(
                    report,
                    production=True,
                    dedicated_host_evidence_path=dedicated_path,
                    performance_review_path=review_path,
                )

    def test_aggregate_result_must_match_every_test(self) -> None:
        report = self.full_report()
        report["tests"][2]["result"] = "failed"
        with self.assertRaisesRegex(CompatibilityError, "aggregate"):
            validate_report(report)

    def test_atomic_output_never_overwrites(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            atomic_write_new(path, b"{}\n")
            self.assertEqual(path.read_bytes(), b"{}\n")
            with self.assertRaisesRegex(CompatibilityError, "overwrite"):
                atomic_write_new(path, b"changed\n")

    def test_final_signed_identity_is_separate_from_unsigned_upstream(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = root / "unsigned-mihomo"
            upstream.write_bytes(b"unsigned-upstream-v1.19.28")
            report_path = root / "compatibility.json"
            report_path.write_bytes(canonical_json_bytes(self.full_report()))
            bundle = root / "VelaMihomoCore.bundle"
            fixed_files = {
                "Contents/Info.plist": b"plist",
                "Contents/MacOS/mihomo": b"final-signed-executable",
                "Contents/_CodeSignature/CodeResources": b"code-resources",
                "Contents/Resources/LICENSE": b"license",
                "Contents/Resources/NOTICE.md": b"notice",
                "Contents/Resources/source.json": b"{}\n",
                "Contents/Resources/compatibility.json": report_path.read_bytes(),
            }
            for relative, raw in fixed_files.items():
                path = bundle / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)
                path.chmod(0o755 if relative == "Contents/MacOS/mihomo" else 0o644)
            identity = build_signed_core_identity(bundle, report_path, upstream)
            self.assertEqual(identity["upstreamPayloadSHA256"], self.upstream_sha)
            self.assertNotEqual(
                identity["signedExecutableSHA256"],
                identity["upstreamPayloadSHA256"],
            )
            identity_raw = canonical_json_bytes(identity)
            validate_signed_core_identity(identity_raw, bundle, report_path, upstream)
            (bundle / "Contents/_CodeSignature/CodeResources").write_bytes(b"timestamp drift")
            with self.assertRaisesRegex(CoreReleaseError, "final post-notarization"):
                validate_signed_core_identity(identity_raw, bundle, report_path, upstream)

    def dedicated_evidence(
        self,
        generated_at: str = "2026-07-13T00:00:00Z",
    ) -> dict:
        return {
            "schemaVersion": 1,
            "suiteVersion": 1,
            "coreID": "v1.19.28-r1",
            "generatedAt": generated_at,
            "host": {"architecture": "arm64", "macOS": "26.5", "machineIDHash": "a" * 64},
            "candidateSHA256": self.candidate_sha,
            "factorySHA256": self.factory_sha,
            "systemProxy": {"result": "passed", "transitions": 20, "restored": True},
            "tun": {
                "result": "passed",
                "modes": ["mixed", "system", "gvisor"],
                "transitions": 20,
                "dnsPassed": True,
                "localNetworkPassed": True,
                "noOrphanInterfaces": True,
                "noOrphanProcesses": True,
                "routesRestored": True,
            },
            "sleepNetwork": {"result": "passed", "sleepWake": True, "networkSwitch": True},
            "rollback": {"result": "passed", "tunRollback": True, "factoryFallback": True},
        }

    def performance_review(self) -> dict:
        return {
            "schemaVersion": 1,
            "suiteVersion": 1,
            "coreID": "v1.19.28-r1",
            "candidateSHA256": self.candidate_sha,
            "factorySHA256": self.factory_sha,
            "decision": "accepted",
            "reviewedAt": "2026-07-13T00:00:00Z",
            "reviewer": "release-reviewer",
            "notes": "Relative metrics reviewed against the exact Factory baseline.",
        }

    def full_report(
        self,
        *,
        dedicated_generated_at: str = "2026-07-13T00:00:00Z",
    ) -> dict:
        tests = [{"id": item, "result": "passed"} for item in self.suite["requiredTests"]]
        dedicated = self.dedicated_evidence(dedicated_generated_at)
        review = self.performance_review()
        _, corpus_paths = validate_corpus()
        api_contract = validate_api_contract(self.suite)
        candidate_metrics = {
            "configParseMeanSeconds": 0.020,
            "idleCPUPercent": 0.1,
            "idleRSSKiB": 50_000.0,
            "loadedCPUPercent": 5.0,
            "loadedRSSKiB": 80_000.0,
            "startupMeanSeconds": 0.20,
            "syntheticConnections": 1_000,
        }
        factory_metrics = {
            "configParseMeanSeconds": 0.018,
            "idleCPUPercent": 0.1,
            "idleRSSKiB": 48_000.0,
            "loadedCPUPercent": 4.5,
            "loadedRSSKiB": 75_000.0,
            "startupMeanSeconds": 0.19,
            "syntheticConnections": 1_000,
        }
        return {
            "schemaVersion": 1,
            "suiteVersion": 1,
            "coreID": "v1.19.28-r1",
            "result": "passed",
            "generatedAt": "2026-07-13T00:00:00Z",
            "environment": {
                "architecture": "arm64",
                "macOS": "26.5",
                "vela": "0.6.0",
                "hostClass": "dedicated-release-lab",
                "userDataAccessed": False,
            },
            "tests": tests,
            "knownDeviations": [],
            "evidenceVersion": 1,
            "artifacts": {
                "upstreamPayloadSHA256": self.upstream_sha,
                "candidateExecutableSHA256": self.candidate_sha,
                "factoryExecutableSHA256": self.factory_sha,
                "suiteSHA256": sha256_file(SUITE_PATH),
                "corpusSHA256": sha256_manifest(corpus_paths, CORPUS_PATH.parent),
                "apiContractSHA256": sha256_file(API_CONTRACT_PATH),
                "dedicatedHostEvidenceSHA256": hashlib.sha256(
                    canonical_json_bytes(dedicated)
                ).hexdigest(),
                "performanceReviewSHA256": hashlib.sha256(
                    canonical_json_bytes(review)
                ).hexdigest(),
            },
            "evidence": {
                "candidateVersion": {
                    "output": "Mihomo Meta v1.19.28 darwin arm64",
                    "version": "1.19.28",
                    "platform": "darwin",
                    "architecture": "arm64",
                },
                "factoryVersion": {
                    "output": "Mihomo Meta v1.19.27 darwin arm64",
                    "version": "1.19.27",
                    "platform": "darwin",
                    "architecture": "arm64",
                },
                "configCorpus": {
                    "validCount": 10,
                    "invalidCount": 2,
                    "largeRuleCount": 10_000,
                    "maximumParseSeconds": 0.05,
                },
                "controllerAPI": {
                    path: sorted(value["requiredKeys"])
                    for path, value in api_contract["rest"].items()
                },
                "webSockets": {
                    path: ["fixture"] for path in api_contract["webSockets"]
                },
                "userBackend": {
                    "transitions": 20,
                    "portCollisionRejected": True,
                    "minimumStartupSeconds": 0.1,
                    "maximumStartupSeconds": 0.3,
                    "meanStartupSeconds": 0.2,
                    "noOrphanProcesses": True,
                    "portsReleased": True,
                },
                "dedicatedHost": {
                    key: dedicated[key]
                    for key in (
                        "generatedAt", "host", "systemProxy", "tun",
                        "sleepNetwork", "rollback",
                    )
                },
                "rollback": {
                    "user": {
                        "sequence": ["factory-before", "candidate", "factory-after"],
                        "userRollback": True,
                        "factoryRecovered": True,
                    },
                    "privileged": dedicated["rollback"],
                },
                "performance": {
                    "relativeThresholds": self.suite["performance"]["thresholds"],
                    "thresholdsPassed": True,
                    "manualReview": {
                        key: review[key]
                        for key in ("decision", "reviewedAt", "reviewer")
                    },
                },
            },
            "metrics": {
                "candidate": candidate_metrics,
                "factory": factory_metrics,
                "ratios": {
                    "configParse": candidate_metrics["configParseMeanSeconds"] / factory_metrics["configParseMeanSeconds"],
                    "idleRSS": candidate_metrics["idleRSSKiB"] / factory_metrics["idleRSSKiB"],
                    "startup": candidate_metrics["startupMeanSeconds"] / factory_metrics["startupMeanSeconds"],
                },
            },
        }

    def write_external_evidence(
        self,
        directory: Path,
        report: dict,
    ) -> tuple[Path, Path]:
        directory.mkdir(parents=True, exist_ok=True)
        dedicated = self.dedicated_evidence(
            report["evidence"]["dedicatedHost"]["generatedAt"]
        )
        review = self.performance_review()
        dedicated_path = directory / "dedicated-host.json"
        review_path = directory / "performance-review.json"
        dedicated_path.write_bytes(canonical_json_bytes(dedicated))
        review_path.write_bytes(canonical_json_bytes(review))
        return dedicated_path, review_path


if __name__ == "__main__":
    unittest.main()
