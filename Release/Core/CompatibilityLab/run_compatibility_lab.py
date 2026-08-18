#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from compatibility_lab import (
    API_CONTRACT_PATH,
    CORPUS_PATH,
    LAB_ROOT,
    SUITE_PATH,
    CompatibilityError,
    atomic_write_new,
    canonical_json_bytes,
    current_macos_version,
    executable_version,
    generate_large_config,
    load_json,
    load_suite,
    read_regular_bytes,
    relative_ratio,
    run_config_test,
    run_lifecycle,
    run_performance_target,
    run_rest_contract,
    run_rollback,
    run_websocket_contract,
    sha256_file,
    sha256_manifest,
    start_runtime,
    stop_runtime,
    validate_api_contract,
    validate_corpus,
    validate_dedicated_host_evidence,
    validate_performance_review,
    validate_report,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Vela Core Compatibility Lab suite v1")
    candidate_group = parser.add_mutually_exclusive_group(required=True)
    candidate_group.add_argument("--candidate-executable")
    candidate_group.add_argument("--candidate-bundle")
    factory_group = parser.add_mutually_exclusive_group(required=True)
    factory_group.add_argument("--factory-executable")
    factory_group.add_argument("--factory-bundle")
    parser.add_argument(
        "--upstream-payload",
        required=True,
        help="Exact unsigned upstream executable bytes that the release build will sign",
    )
    parser.add_argument("--core-id", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dedicated-host-evidence")
    parser.add_argument("--performance-review")
    parser.add_argument(
        "--host-class",
        choices=("local-development", "dedicated-release-lab"),
        default="local-development",
    )
    parser.add_argument("--vela-version", default="0.6.0")
    parser.add_argument("--generated-at")
    parser.add_argument(
        "--skip-performance",
        action="store_true",
        help="Development-only: records performance as failed; never creates passing evidence.",
    )
    args = parser.parse_args()

    try:
        candidate = resolve_executable(
            executable=args.candidate_executable,
            bundle=args.candidate_bundle,
            label="candidate",
            require_core_metadata=True,
        )
        factory = resolve_executable(
            executable=args.factory_executable,
            bundle=args.factory_bundle,
            label="Factory",
            require_core_metadata=False,
        )
        for label, executable in (("candidate", candidate), ("Factory", factory)):
            read_regular_bytes(executable, 128 * 1024 * 1024)
            if not os.access(executable, os.X_OK):
                raise CompatibilityError(f"{label} executable is not executable")
        upstream_payload = Path(args.upstream_payload)
        read_regular_bytes(upstream_payload, 128 * 1024 * 1024)
        output = Path(args.output)
        if output.exists() or output.is_symlink():
            raise CompatibilityError("compatibility output must be a new path")

        suite = load_suite()
        if args.core_id != suite["candidate"]["coreID"]:
            raise CompatibilityError("CoreID does not match suite-v1 candidate matrix")
        corpus, corpus_files = validate_corpus()
        api_contract = validate_api_contract(suite)
        candidate_sha = sha256_file(candidate)
        factory_sha = sha256_file(factory)
        upstream_payload_sha = sha256_file(upstream_payload)
        if candidate_sha != upstream_payload_sha:
            raise CompatibilityError(
                "candidate executable must be the exact unsigned upstream payload"
            )
        dedicated_path = Path(args.dedicated_host_evidence) if args.dedicated_host_evidence else None
        review_path = Path(args.performance_review) if args.performance_review else None

        results: dict[str, str] = {identifier: "failed" for identifier in suite["requiredTests"]}
        deviations: list[str] = []
        evidence: dict[str, Any] = {
            "candidateVersion": None,
            "factoryVersion": None,
            "configCorpus": None,
            "controllerAPI": None,
            "webSockets": None,
            "userBackend": None,
            "dedicatedHost": None,
            "rollback": None,
            "performance": None,
        }
        metrics: dict[str, Any] = {"candidate": None, "factory": None, "ratios": None}

        def attempt(identifier: str, action: Callable[[], Any]) -> Any | None:
            try:
                value = action()
                results[identifier] = "passed"
                return value
            except (CompatibilityError, OSError, TimeoutError, subprocess.SubprocessError) as error:
                results[identifier] = "failed"
                deviations.append(f"{identifier}: {bounded_error(error)}")
                return None

        def version_action() -> dict[str, Any]:
            candidate_output, candidate_parsed = executable_version(candidate)
            factory_output, factory_parsed = executable_version(factory)
            expected = suite["candidate"]
            expected_version = expected["version"].removeprefix("v")
            if candidate_parsed != {
                "version": expected_version,
                "platform": expected["platform"],
                "architecture": expected["architecture"],
            }:
                raise CompatibilityError("candidate -v differs from suite-v1 version/platform/architecture")
            if factory_parsed["platform"] != "darwin" or factory_parsed["architecture"] != "arm64":
                raise CompatibilityError("Factory baseline is not darwin/arm64")
            evidence["candidateVersion"] = {"output": candidate_output, **candidate_parsed}
            evidence["factoryVersion"] = {"output": factory_output, **factory_parsed}
            return evidence["candidateVersion"]

        attempt("version", version_action)

        with tempfile.TemporaryDirectory(prefix="vela-core-compat-") as temporary_name:
            temporary = Path(temporary_name)

            def corpus_action() -> dict[str, Any]:
                fixture_root = CORPUS_PATH.parent
                valid_durations: list[float] = []
                invalid_count = 0
                for relative in corpus["valid"]:
                    valid_durations.append(run_config_test(candidate, fixture_root / relative, True))
                for relative in corpus["invalid"]:
                    run_config_test(candidate, fixture_root / relative, False)
                    invalid_count += 1
                large = temporary / "large-config.yaml"
                generate_large_config(large, corpus["generated"][0]["ruleCount"])
                large_duration = run_config_test(candidate, large, True, timeout=30)
                value = {
                    "validCount": len(valid_durations) + 1,
                    "invalidCount": invalid_count,
                    "largeRuleCount": corpus["generated"][0]["ruleCount"],
                    "maximumParseSeconds": max(valid_durations + [large_duration]),
                }
                evidence["configCorpus"] = value
                return value

            attempt("config-corpus", corpus_action)

            runtime_holder: dict[str, Any] = {}
            try:
                runtime_holder["runtime"] = start_runtime(candidate, temporary, "controller-contract")
            except (CompatibilityError, OSError) as error:
                deviations.append(f"controller-api: {bounded_error(error)}")
                deviations.append("websockets: controller runtime was unavailable")
            runtime = runtime_holder.get("runtime")
            if runtime is not None:
                try:
                    value = attempt("controller-api", lambda: run_rest_contract(runtime, api_contract))
                    if value is not None:
                        evidence["controllerAPI"] = value
                    value = attempt("websockets", lambda: run_websocket_contract(runtime, api_contract))
                    if value is not None:
                        evidence["webSockets"] = value
                finally:
                    stop_runtime(runtime)

            value = attempt(
                "user-backend",
                lambda: run_lifecycle(candidate, temporary, suite["transitionCount"]),
            )
            if value is not None:
                evidence["userBackend"] = value

            local_rollback: dict[str, Any] | None = None
            try:
                local_rollback = run_rollback(candidate, factory, temporary)
            except (CompatibilityError, OSError) as error:
                deviations.append(f"rollback: {bounded_error(error)}")

            dedicated: dict[str, Any] | None = None
            if dedicated_path is None:
                deviations.extend([
                    "system-proxy: dedicated-host evidence was not provided",
                    "tun-backend: dedicated-host evidence was not provided",
                    "sleep-network: dedicated-host evidence was not provided",
                ])
            else:
                try:
                    dedicated = validate_dedicated_host_evidence(
                        load_json(dedicated_path),
                        core_id=args.core_id,
                        candidate_sha256=candidate_sha,
                        factory_sha256=factory_sha,
                    )
                    evidence["dedicatedHost"] = {
                        "generatedAt": dedicated["generatedAt"],
                        "host": dedicated["host"],
                        "systemProxy": dedicated["systemProxy"],
                        "tun": dedicated["tun"],
                        "sleepNetwork": dedicated["sleepNetwork"],
                        "rollback": dedicated["rollback"],
                    }
                    results["system-proxy"] = "passed"
                    results["tun-backend"] = "passed"
                    results["sleep-network"] = "passed"
                except (CompatibilityError, OSError) as error:
                    deviations.append(f"dedicated-host: {bounded_error(error)}")

            if local_rollback is not None and dedicated is not None:
                results["rollback"] = "passed"
                evidence["rollback"] = {
                    "user": local_rollback,
                    "privileged": dedicated["rollback"],
                }
            elif local_rollback is not None:
                evidence["rollback"] = {"user": local_rollback, "privileged": None}
                deviations.append("rollback: privileged TUN rollback evidence was not provided")

            performance_review: dict[str, Any] | None = None
            if review_path is not None:
                try:
                    performance_review = validate_performance_review(
                        load_json(review_path),
                        core_id=args.core_id,
                        candidate_sha256=candidate_sha,
                        factory_sha256=factory_sha,
                    )
                except (CompatibilityError, OSError) as error:
                    deviations.append(f"performance: {bounded_error(error)}")

            if args.skip_performance:
                deviations.append("performance: development run explicitly skipped live measurements")
            else:
                try:
                    performance = suite["performance"]
                    candidate_metrics = run_performance_target(
                        candidate,
                        temporary,
                        "candidate",
                        startup_iterations=performance["startupIterations"],
                        parse_iterations=performance["configParseIterations"],
                        idle_seconds=float(performance["idleSampleSeconds"]),
                        synthetic_connections=performance["syntheticConnections"],
                    )
                    factory_metrics = run_performance_target(
                        factory,
                        temporary,
                        "factory",
                        startup_iterations=performance["startupIterations"],
                        parse_iterations=performance["configParseIterations"],
                        idle_seconds=float(performance["idleSampleSeconds"]),
                        synthetic_connections=performance["syntheticConnections"],
                    )
                    ratios = {
                        "configParse": relative_ratio(
                            candidate_metrics["configParseMeanSeconds"],
                            factory_metrics["configParseMeanSeconds"],
                        ),
                        "idleRSS": relative_ratio(
                            candidate_metrics["idleRSSKiB"],
                            factory_metrics["idleRSSKiB"],
                        ),
                        "startup": relative_ratio(
                            candidate_metrics["startupMeanSeconds"],
                            factory_metrics["startupMeanSeconds"],
                        ),
                    }
                    metrics = {
                        "candidate": candidate_metrics,
                        "factory": factory_metrics,
                        "ratios": ratios,
                    }
                    thresholds = performance["thresholds"]
                    threshold_passed = (
                        ratios["configParse"] <= thresholds["configParseRatio"]
                        and ratios["idleRSS"] <= thresholds["idleRSSRatio"]
                        and ratios["startup"] <= thresholds["startupRatio"]
                    )
                    evidence["performance"] = {
                        "relativeThresholds": thresholds,
                        "thresholdsPassed": threshold_passed,
                        "manualReview": None if performance_review is None else {
                            "decision": performance_review["decision"],
                            "reviewedAt": performance_review["reviewedAt"],
                            "reviewer": performance_review["reviewer"],
                        },
                    }
                    if not threshold_passed:
                        deviations.append("performance: relative regression threshold exceeded; manual review cannot override a failed gate")
                    elif performance_review is None:
                        deviations.append("performance: required manual review evidence was not provided")
                    elif performance_review["decision"] != "accepted":
                        deviations.append("performance: manual review rejected the candidate")
                    else:
                        results["performance"] = "passed"
                except (CompatibilityError, OSError, TimeoutError) as error:
                    deviations.append(f"performance: {bounded_error(error)}")

        artifact_ok = candidate_sha != factory_sha
        if not artifact_ok:
            deviations.append("artifact-integrity: candidate and Factory executable SHA-256 are identical")
        elif dedicated_path is not None and dedicated is None:
            deviations.append("artifact-integrity: dedicated-host evidence was present but invalid")
        elif review_path is not None and performance_review is None:
            deviations.append("artifact-integrity: performance review was present but invalid")
        else:
            results["artifact-integrity"] = "passed"

        generated_at = args.generated_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        report = {
            "schemaVersion": 1,
            "suiteVersion": suite["suiteVersion"],
            "coreID": args.core_id,
            "result": "passed" if all(value == "passed" for value in results.values()) else "failed",
            "generatedAt": generated_at,
            "environment": {
                "architecture": platform.machine(),
                "macOS": current_macos_version(),
                "vela": args.vela_version,
                "hostClass": args.host_class,
                "userDataAccessed": False,
            },
            "tests": [{"id": identifier, "result": results[identifier]} for identifier in suite["requiredTests"]],
            "knownDeviations": sorted(set(deviations)),
            "evidenceVersion": 1,
            "artifacts": {
                "upstreamPayloadSHA256": upstream_payload_sha,
                "candidateExecutableSHA256": candidate_sha,
                "factoryExecutableSHA256": factory_sha,
                "suiteSHA256": sha256_file(SUITE_PATH),
                "corpusSHA256": sha256_manifest(corpus_files, CORPUS_PATH.parent),
                "apiContractSHA256": sha256_file(API_CONTRACT_PATH),
                "dedicatedHostEvidenceSHA256": None if dedicated_path is None else sha256_file(dedicated_path),
                "performanceReviewSHA256": None if review_path is None else sha256_file(review_path),
            },
            "evidence": evidence,
            "metrics": metrics,
        }
        validate_report(report, expected_core_id=args.core_id)
        atomic_write_new(output, canonical_json_bytes(report))
        print(f"Compatibility report: {output}")
        print(f"result={report['result']} passed={sum(value == 'passed' for value in results.values())}/{len(results)}")
        if report["result"] != "passed":
            print("The report is intentionally non-publishable until every required gate passes.")
        return 0
    except (CompatibilityError, OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def bounded_error(error: BaseException) -> str:
    value = " ".join(str(error).split())
    return value[:1000] or error.__class__.__name__


def resolve_executable(
    *,
    executable: str | None,
    bundle: str | None,
    label: str,
    require_core_metadata: bool,
) -> Path:
    if executable is not None:
        executable_path = Path(executable)
        if executable_path.is_symlink():
            raise CompatibilityError(f"{label} executable must not be a symlink")
        return executable_path.resolve(strict=True)
    if bundle is None:
        raise CompatibilityError(f"{label} artifact is missing")
    bundle_input = Path(bundle)
    if bundle_input.is_symlink():
        raise CompatibilityError(f"{label} bundle must be a regular non-symlink directory")
    bundle_path = bundle_input.resolve(strict=True)
    if not bundle_path.is_dir():
        raise CompatibilityError(f"{label} bundle must be a regular non-symlink directory")
    candidate = bundle_path / "Contents" / "MacOS" / "mihomo"
    if require_core_metadata:
        info_path = bundle_path / "Contents" / "Info.plist"
        if not info_path.is_file() or info_path.is_symlink():
            raise CompatibilityError("candidate Core bundle Info.plist is missing or unsafe")
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        if info.get("CFBundlePackageType") != "BNDL":
            raise CompatibilityError("candidate Core bundle must use CFBundlePackageType BNDL")
        if not str(info.get("CFBundleIdentifier", "")).endswith(".MihomoCore"):
            raise CompatibilityError("candidate Core bundle identifier is invalid")
        if info.get("VelaCoreVersion") != "v1.19.28" or info.get("VelaCorePackageRevision") != 1:
            raise CompatibilityError("candidate Core bundle version/revision is not v1.19.28-r1")
    return candidate.resolve(strict=True)


if __name__ == "__main__":
    raise SystemExit(main())
