#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Hardening/scripts"))
from json_schema import SchemaError, validate  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "ReleaseCandidate/scripts"
FIXTURES = ROOT / "ReleaseCandidate/tests/fixtures"
FEATURE_FREEZE = ROOT / "ReleaseCandidate/config/feature-freeze.json"


def run_script(
    name: str,
    *arguments: str | Path,
    expect_success: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / name), *map(str, arguments)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if expect_success and result.returncode != 0:
        raise AssertionError(
            f"{name} unexpectedly failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    if not expect_success and result.returncode == 0:
        raise AssertionError(f"{name} unexpectedly passed\nstdout:\n{result.stdout}")
    return result


def load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class ContractToolingTests(unittest.TestCase):
    def generate(self, directory: Path) -> None:
        run_script(
            "generate_project_contracts.py",
            "--repository-root",
            ROOT,
            "--output-dir",
            directory,
        )

    def test_generation_is_deterministic_and_uses_real_absent_surfaces(self) -> None:
        with tempfile.TemporaryDirectory() as first_raw, tempfile.TemporaryDirectory() as second_raw:
            first = Path(first_raw)
            second = Path(second_raw)
            self.generate(first)
            self.generate(second)
            for name in (
                "public-contract-freeze.json",
                "app-intent-registry.json",
                "hashes.json",
            ):
                self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())

            contract = load(first / "public-contract-freeze.json")
            self.assertEqual(contract["protocols"]["helper"]["methodCount"], 19)
            self.assertIn(
                "refreshCoreCatalog",
                contract["protocols"]["helper"]["methods"],
            )
            self.assertIsNone(contract["protocols"]["automation"])
            self.assertEqual(contract["cli"]["availability"], "absent")
            self.assertEqual(contract["cli"]["commands"], [])
            self.assertEqual(contract["appIntents"]["intentTypeNames"], [])
            self.assertEqual(contract["schemas"]["rootData"], 3)
            self.assertEqual(contract["schemas"]["scene"], 1)
            self.assertNotIn("productionSceneStore", contract["absentSurfaces"])
            self.assertEqual(
                contract["configuration"]["operationKinds"],
                [
                    "set",
                    "remove",
                    "deepMerge",
                    "prependUnique",
                    "appendUnique",
                    "upsertNamed",
                    "removeNamed",
                ],
            )
            self.assertEqual(
                contract["keychain"][0]["service"],
                "dev.yilin.Vela.subscription",
            )

    def test_generated_contracts_pass_all_validators_and_hash_verification(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            public = output / "public-contract-freeze.json"
            intents = output / "app-intent-registry.json"
            hashes = output / "hashes.json"
            run_script(
                "validate_contract_freeze.py",
                public,
                "--app-intent-registry",
                intents,
            )
            run_script("validate_app_intent_registry.py", intents)
            run_script(
                "generate_contract_hashes.py",
                "--contracts-dir",
                output,
                "--output",
                hashes,
                "--verify",
            )
            run_script("compare_contract_freeze.py", public, public)

    def test_checked_in_feature_freeze_is_strict_and_complete(self) -> None:
        run_script("validate_feature_freeze.py", FEATURE_FREEZE)
        with tempfile.TemporaryDirectory() as raw:
            broken = copy.deepcopy(load(FEATURE_FREEZE))
            broken["forbiddenAdditions"].remove("helperRPC")
            path = Path(raw) / "feature-freeze.json"
            write(path, broken)
            result = run_script(
                "validate_feature_freeze.py",
                path,
                expect_success=False,
            )
            self.assertIn("helperRPC", result.stderr)

    def test_unapproved_contract_drift_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            current_value = copy.deepcopy(load(golden))
            current_value["trustRoots"][1]["identifier"] = "production-app-update-key-v1"
            current_value["trustRoots"][1]["status"] = "configured"
            current = output / "current.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                expect_success=False,
            )
            self.assertIn("/trustRoots", result.stderr)

    def test_exact_accepted_adr_can_approve_nonexpanding_trust_provisioning(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            current_value = copy.deepcopy(load(golden))
            current_value["trustRoots"][1]["identifier"] = "production-app-update-key-v1"
            current_value["trustRoots"][1]["status"] = "configured"
            current = output / "current.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                FIXTURES / "accepted-trust-provisioning-adr.json",
            )
            self.assertIn("validated ADR approval", result.stdout)

    def test_published_contract_change_schema_matches_v2_adr_contract(self) -> None:
        schema = load(ROOT / "Contracts/v1/schemas/contract-change-adr.schema.json")
        accepted = load(FIXTURES / "accepted-trust-provisioning-adr.json")
        validate(accepted, schema)

        legacy = copy.deepcopy(accepted)
        legacy["schemaVersion"] = 1
        legacy.pop("contractBinding")
        with self.assertRaises(SchemaError):
            validate(legacy, schema)

    def test_core_same_kind_key_addition_is_forbidden_even_with_an_adr(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden_value = load(output / "public-contract-freeze.json")
            core = next(
                item
                for item in golden_value["trustRoots"]
                if item["kind"] == "coreCatalogEd25519"
            )
            core["identifier"] = ["production-core-key-v1"]
            core["status"] = "configured"
            golden = output / "configured-core.json"
            write(golden, golden_value)

            current_value = copy.deepcopy(golden_value)
            current_core = next(
                item
                for item in current_value["trustRoots"]
                if item["kind"] == "coreCatalogEd25519"
            )
            current_core["identifier"].append("production-core-key-v2")
            current = output / "expanded-core.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                FIXTURES / "accepted-trust-provisioning-adr.json",
                expect_success=False,
            )
            self.assertIn(
                "new or changed trust-root identifier/key ID outside exact provisioning: "
                "coreCatalogEd25519",
                result.stderr,
            )

    def test_replayed_trust_provisioning_adr_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            current_value = copy.deepcopy(load(golden))
            current_value["trustRoots"][1]["identifier"] = "different-production-key"
            current_value["trustRoots"][1]["status"] = "configured"
            current = output / "different-current.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                FIXTURES / "accepted-trust-provisioning-adr.json",
                expect_success=False,
            )
            self.assertIn(
                "current canonical SHA-256 does not bind this contract",
                result.stderr,
            )

    def test_wide_trust_root_adr_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            golden_value = load(golden)
            current_value = copy.deepcopy(golden_value)
            current_value["trustRoots"][1]["identifier"] = "production-app-update-key-v1"
            current_value["trustRoots"][1]["status"] = "configured"
            current = output / "current.json"
            write(current, current_value)

            adr = load(FIXTURES / "accepted-trust-provisioning-adr.json")
            adr["changes"][0]["path"] = "/trustRoots"
            adr["changes"][0]["before"] = golden_value["trustRoots"]
            adr["changes"][0]["after"] = current_value["trustRoots"]
            adr_path = output / "wide-adr.json"
            write(adr_path, adr)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                adr_path,
                expect_success=False,
            )
            self.assertIn(
                "does not bind an actual contract change",
                result.stderr,
            )

    def test_incomplete_adr_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            current_value = copy.deepcopy(load(golden))
            current_value["trustRoots"][1]["identifier"] = "production-app-update-key-v1"
            current_value["trustRoots"][1]["status"] = "configured"
            current = output / "current.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                FIXTURES / "rejected-incomplete-adr.json",
                expect_success=False,
            )
            self.assertIn("required approval roles", result.stderr)

    def test_feature_freeze_forbids_new_helper_rpc_even_with_adr(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            golden = output / "public-contract-freeze.json"
            current_value = copy.deepcopy(load(golden))
            current_value["protocols"]["helper"]["methods"].append(
                "arbitraryCommand"
            )
            current_value["protocols"]["helper"]["methodCount"] += 1
            current = output / "current.json"
            write(current, current_value)
            result = run_script(
                "compare_contract_freeze.py",
                golden,
                current,
                "--adr",
                FIXTURES / "accepted-trust-provisioning-adr.json",
                expect_success=False,
            )
            self.assertIn("new Helper RPC", result.stderr)

    def test_absent_app_intent_registry_cannot_hide_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            registry = load(output / "app-intent-registry.json")
            registry["intents"] = [
                {"type": "ExperimentalVelaIntent", "parameters": []}
            ]
            path = output / "invalid-intents.json"
            write(path, registry)
            result = run_script(
                "validate_app_intent_registry.py",
                path,
                expect_success=False,
            )
            self.assertIn("must have empty collections", result.stderr)

    def test_contract_validator_rejects_placeholder_or_pack_fiction(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            self.generate(output)
            value = load(output / "public-contract-freeze.json")
            value["identifiers"]["cli"] = "dev.yilin.Vela.CLI"
            value["cli"]["bundleIdentifier"] = "dev.yilin.Vela.CLI"
            value["cli"]["availability"] = "available"
            value["cli"]["commands"] = ["status"]
            path = output / "fictional-cli.json"
            write(path, value)
            result = run_script(
                "validate_contract_freeze.py",
                path,
                expect_success=False,
            )
            self.assertIn("identifiers changed", result.stderr)


if __name__ == "__main__":
    unittest.main()
