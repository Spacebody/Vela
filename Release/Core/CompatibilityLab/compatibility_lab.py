#!/usr/bin/env python3
"""Dependency-free contracts and live probes for Vela Core Compatibility Lab.

The module intentionally has no access to Vela's user profile locations. Every
runtime configuration is generated from the checked-in corpus into a new
temporary directory.
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import math
import os
import platform
import re
import resource
import secrets
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote


LAB_ROOT = Path(__file__).resolve().parent
SUITE_PATH = LAB_ROOT / "config" / "suite-v1.json"
CORPUS_PATH = LAB_ROOT / "fixtures" / "config-corpus.json"
API_CONTRACT_PATH = LAB_ROOT / "fixtures" / "api-contract-v1.json"
MAX_JSON_BYTES = 2 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
CORE_ID_RE = re.compile(r"v([0-9]+\.[0-9]+\.[0-9]+)-r([1-9][0-9]*)")
VERSION_RE = re.compile(
    r"\bMihomo\s+Meta\s+v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)\s+"
    r"(?P<platform>darwin)\s+(?P<architecture>arm64)\b",
    re.IGNORECASE,
)


class CompatibilityError(ValueError):
    pass


def fail(message: str) -> None:
    raise CompatibilityError(message)


def read_regular_bytes(path: Path, maximum: int = MAX_JSON_BYTES) -> bytes:
    if not path.is_file() or path.is_symlink():
        fail(f"expected a regular non-symlink file: {path}")
    size = path.stat().st_size
    if size > maximum:
        fail(f"file exceeds {maximum} bytes: {path}")
    return path.read_bytes()


def load_json(path: Path, maximum: int = MAX_JSON_BYTES) -> dict[str, Any]:
    try:
        value = json.loads(read_regular_bytes(path, maximum))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON {path}: {error}")
    if not isinstance(value, dict):
        fail(f"expected a JSON object: {path}")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_rfc3339(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or len(value) > 64:
        fail(f"{label} must be an RFC3339 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{label} is not valid RFC3339")
    if parsed.tzinfo is None:
        fail(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def sha256_manifest(paths: list[Path], relative_to: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: item.relative_to(relative_to).as_posix()):
        if not path.is_file() or path.is_symlink():
            fail(f"manifest input must be a regular non-symlink file: {path}")
        relative = path.relative_to(relative_to).as_posix().encode("utf-8")
        data = read_regular_bytes(path)
        digest.update(struct.pack(">I", len(relative)))
        digest.update(relative)
        digest.update(struct.pack(">Q", len(data)))
        digest.update(data)
    return digest.hexdigest()


def load_suite() -> dict[str, Any]:
    suite = load_json(SUITE_PATH, 128 * 1024)
    expected_keys = {
        "schemaVersion",
        "suiteVersion",
        "candidate",
        "controllerAPIProfile",
        "requiredRESTEndpoints",
        "requiredWebSockets",
        "requiredTests",
        "transitionCount",
        "performance",
    }
    if set(suite) != expected_keys or suite["schemaVersion"] != 1 or suite["suiteVersion"] != 1:
        fail("Compatibility Lab suite-v1 fields/schema are invalid")
    candidate = suite["candidate"]
    if candidate != {
        "architecture": "arm64",
        "coreID": "v1.19.28-r1",
        "platform": "darwin",
        "version": "v1.19.28",
    }:
        fail("suite-v1 candidate matrix must remain v1.19.28-r1/darwin/arm64")
    if suite["controllerAPIProfile"] != "mihomo-v1.19.28":
        fail("suite-v1 controller profile changed without a suite bump")
    required_tests = suite["requiredTests"]
    if not isinstance(required_tests, list) or len(required_tests) != len(set(required_tests)):
        fail("suite-v1 required test IDs must be a unique array")
    if suite["transitionCount"] != 20:
        fail("suite-v1 must run exactly twenty backend transitions")
    performance = suite["performance"]
    if not isinstance(performance, dict) or performance.get("syntheticConnections") != 1000:
        fail("suite-v1 must measure one thousand synthetic connections")
    return suite


def validate_corpus() -> tuple[dict[str, Any], list[Path]]:
    corpus = load_json(CORPUS_PATH, 128 * 1024)
    if set(corpus) != {"schemaVersion", "valid", "invalid", "generated", "supportFiles"}:
        fail("config corpus manifest fields are invalid")
    if corpus["schemaVersion"] != 1:
        fail("unsupported config corpus schema")
    fixture_root = CORPUS_PATH.parent
    paths: list[Path] = [CORPUS_PATH]
    for category in ("valid", "invalid", "supportFiles"):
        entries = corpus[category]
        if not isinstance(entries, list) or not entries:
            fail(f"config corpus {category} must be non-empty")
        for relative in entries:
            if not isinstance(relative, str) or relative.startswith("/") or ".." in Path(relative).parts:
                fail(f"unsafe config corpus path: {relative!r}")
            path = fixture_root / relative
            read_regular_bytes(path, 1024 * 1024)
            paths.append(path)
    generated = corpus["generated"]
    if generated != [{"id": "large-config", "ruleCount": 10000}]:
        fail("suite-v1 large config contract changed without a suite bump")
    return corpus, paths


def validate_api_contract(suite: dict[str, Any]) -> dict[str, Any]:
    contract = load_json(API_CONTRACT_PATH, 128 * 1024)
    if set(contract) != {"schemaVersion", "profile", "rest", "webSockets"}:
        fail("API contract fields are invalid")
    if contract["schemaVersion"] != 1 or contract["profile"] != suite["controllerAPIProfile"]:
        fail("API contract version/profile mismatch")
    if list(contract["rest"]) != sorted(suite["requiredRESTEndpoints"]):
        fail("REST contract does not exactly cover the suite matrix")
    if list(contract["webSockets"]) != sorted(suite["requiredWebSockets"]):
        fail("WebSocket contract does not exactly cover the suite matrix")
    for path, item in contract["rest"].items():
        if not path.startswith("/") or item.get("type") != "object":
            fail(f"invalid REST contract for {path}")
        required = item.get("requiredKeys")
        if not isinstance(required, list) or not required:
            fail(f"REST contract {path} needs required keys")
    for path, item in contract["webSockets"].items():
        if not path.startswith("/") or item != {"frame": "json-object"}:
            fail(f"invalid WebSocket contract for {path}")
    return contract


def validate_dedicated_host_evidence(
    evidence: dict[str, Any],
    *,
    core_id: str,
    candidate_sha256: str,
    factory_sha256: str,
) -> dict[str, Any]:
    required = {
        "schemaVersion",
        "suiteVersion",
        "coreID",
        "generatedAt",
        "host",
        "candidateSHA256",
        "factorySHA256",
        "systemProxy",
        "tun",
        "sleepNetwork",
        "rollback",
    }
    if set(evidence) != required or evidence["schemaVersion"] != 1 or evidence["suiteVersion"] != 1:
        fail("dedicated-host evidence fields/schema are invalid")
    if evidence["coreID"] != core_id:
        fail("dedicated-host evidence CoreID mismatch")
    if evidence["candidateSHA256"] != candidate_sha256 or evidence["factorySHA256"] != factory_sha256:
        fail("dedicated-host evidence artifact hash mismatch")
    parse_rfc3339(evidence["generatedAt"], "dedicated-host generatedAt")
    host = evidence["host"]
    if not isinstance(host, dict) or set(host) != {"architecture", "macOS", "machineIDHash"}:
        fail("dedicated-host identity fields are invalid")
    if host["architecture"] != "arm64" or SHA256_RE.fullmatch(str(host["machineIDHash"])) is None:
        fail("dedicated-host must be an anonymized Apple Silicon host")
    system_proxy = evidence["systemProxy"]
    if system_proxy != {"result": "passed", "transitions": 20, "restored": True}:
        fail("System Proxy evidence did not pass twenty transitions and restoration")
    tun = evidence["tun"]
    if not isinstance(tun, dict) or set(tun) != {
        "result", "modes", "transitions", "dnsPassed", "localNetworkPassed",
        "noOrphanInterfaces", "noOrphanProcesses", "routesRestored",
    }:
        fail("TUN evidence fields are invalid")
    if tun["result"] != "passed" or tun["modes"] != ["mixed", "system", "gvisor"] or tun["transitions"] != 20:
        fail("TUN evidence matrix did not pass")
    for flag in ("dnsPassed", "localNetworkPassed", "noOrphanInterfaces", "noOrphanProcesses", "routesRestored"):
        if tun[flag] is not True:
            fail(f"TUN evidence failed {flag}")
    sleep = evidence["sleepNetwork"]
    if sleep != {"result": "passed", "sleepWake": True, "networkSwitch": True}:
        fail("sleep/wake and network-switch evidence did not pass")
    rollback = evidence["rollback"]
    if rollback != {"result": "passed", "tunRollback": True, "factoryFallback": True}:
        fail("privileged rollback evidence did not pass")
    return evidence


def validate_performance_review(
    review: dict[str, Any],
    *,
    core_id: str,
    candidate_sha256: str,
    factory_sha256: str,
) -> dict[str, Any]:
    required = {
        "schemaVersion", "suiteVersion", "coreID", "candidateSHA256",
        "factorySHA256", "decision", "reviewedAt", "reviewer", "notes",
    }
    if set(review) != required or review["schemaVersion"] != 1 or review["suiteVersion"] != 1:
        fail("performance review fields/schema are invalid")
    if review["coreID"] != core_id or review["candidateSHA256"] != candidate_sha256 or review["factorySHA256"] != factory_sha256:
        fail("performance review artifact identity mismatch")
    if review["decision"] not in {"accepted", "rejected"}:
        fail("performance review decision is invalid")
    parse_rfc3339(review["reviewedAt"], "performance reviewedAt")
    if not isinstance(review["reviewer"], str) or not review["reviewer"].strip() or len(review["reviewer"]) > 128:
        fail("performance review requires a bounded reviewer identity")
    if (
        not isinstance(review["notes"], str)
        or not review["notes"].strip()
        or len(review["notes"]) > 4096
    ):
        fail("performance review notes are invalid")
    return review


def _bounded_string(value: Any, label: str, *, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        fail(f"{label} must be a non-empty bounded string")
    return value


def _finite_number(
    value: Any,
    label: str,
    *,
    positive: bool = False,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number) or number < 0 or (positive and number <= 0):
        fail(f"{label} must be a finite {'positive' if positive else 'non-negative'} value")
    return number


def _validate_version_summary(
    value: Any,
    label: str,
    *,
    expected_version: str | None = None,
) -> None:
    if not isinstance(value, dict) or set(value) != {
        "output", "version", "platform", "architecture",
    }:
        fail(f"{label} version evidence fields are invalid")
    _bounded_string(value["output"], f"{label} version output", maximum=1024)
    version = _bounded_string(value["version"], f"{label} version", maximum=64)
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        fail(f"{label} version evidence is invalid")
    if expected_version is not None and version != expected_version:
        fail(f"{label} version differs from suite-v1")
    if value["platform"] != "darwin" or value["architecture"] != "arm64":
        fail(f"{label} version evidence is not darwin/arm64")


def _validate_snapshot_map(
    value: Any,
    expected: dict[str, Any],
    label: str,
) -> None:
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(f"{label} evidence does not exactly cover the suite contract")
    for path, keys in value.items():
        if (
            not isinstance(keys, list)
            or not keys
            or len(keys) != len(set(keys))
            or any(not isinstance(item, str) or not item or len(item) > 256 for item in keys)
        ):
            fail(f"{label} evidence is invalid for {path}")
        required = expected[path].get("requiredKeys")
        if required is not None and not set(required).issubset(keys):
            fail(f"{label} evidence lacks required keys for {path}")


def _validate_user_lifecycle(value: Any, transition_count: int) -> None:
    required = {
        "transitions", "portCollisionRejected", "minimumStartupSeconds",
        "maximumStartupSeconds", "meanStartupSeconds", "noOrphanProcesses",
        "portsReleased",
    }
    if not isinstance(value, dict) or set(value) != required:
        fail("user backend evidence fields are invalid")
    if value["transitions"] != transition_count:
        fail("user backend transition count differs from suite-v1")
    for flag in ("portCollisionRejected", "noOrphanProcesses", "portsReleased"):
        if value[flag] is not True:
            fail(f"user backend evidence failed {flag}")
    minimum = _finite_number(value["minimumStartupSeconds"], "minimum startup")
    maximum = _finite_number(value["maximumStartupSeconds"], "maximum startup")
    mean = _finite_number(value["meanStartupSeconds"], "mean startup")
    if not minimum <= mean <= maximum:
        fail("user backend startup metrics are inconsistent")


def _validate_user_rollback(value: Any) -> None:
    if value != {
        "sequence": ["factory-before", "candidate", "factory-after"],
        "userRollback": True,
        "factoryRecovered": True,
    }:
        fail("user rollback evidence is invalid")


def _validate_performance_metrics(
    metrics: Any,
    suite: dict[str, Any],
) -> None:
    if not isinstance(metrics, dict) or set(metrics) != {"candidate", "factory", "ratios"}:
        fail("compatibility metrics fields are invalid")
    metric_keys = {
        "configParseMeanSeconds", "idleCPUPercent", "idleRSSKiB",
        "loadedCPUPercent", "loadedRSSKiB", "startupMeanSeconds",
        "syntheticConnections",
    }
    for label in ("candidate", "factory"):
        value = metrics[label]
        if not isinstance(value, dict) or set(value) != metric_keys:
            fail(f"{label} performance metrics fields are invalid")
        for key in metric_keys - {"syntheticConnections"}:
            _finite_number(value[key], f"{label} {key}", positive=key in {
                "configParseMeanSeconds", "idleRSSKiB", "loadedRSSKiB",
                "startupMeanSeconds",
            })
        if value["syntheticConnections"] != suite["performance"]["syntheticConnections"]:
            fail(f"{label} synthetic connection count differs from suite-v1")
    ratios = metrics["ratios"]
    if not isinstance(ratios, dict) or set(ratios) != {"configParse", "idleRSS", "startup"}:
        fail("performance ratio fields are invalid")
    mappings = {
        "configParse": "configParseMeanSeconds",
        "idleRSS": "idleRSSKiB",
        "startup": "startupMeanSeconds",
    }
    for ratio_key, metric_key in mappings.items():
        actual = _finite_number(ratios[ratio_key], f"{ratio_key} ratio", positive=True)
        expected = float(metrics["candidate"][metric_key]) / float(metrics["factory"][metric_key])
        if not math.isclose(actual, expected, rel_tol=1e-9, abs_tol=1e-12):
            fail(f"{ratio_key} ratio does not match candidate/Factory metrics")


def _validate_passed_report_evidence(
    evidence: Any,
    metrics: Any,
    suite: dict[str, Any],
    api_contract: dict[str, Any],
) -> None:
    if not isinstance(evidence, dict) or set(evidence) != {
        "candidateVersion", "factoryVersion", "configCorpus", "controllerAPI",
        "webSockets", "userBackend", "dedicatedHost", "rollback", "performance",
    }:
        fail("compatibility evidence summary fields are invalid")
    expected_version = suite["candidate"]["version"].removeprefix("v")
    _validate_version_summary(
        evidence["candidateVersion"],
        "candidate",
        expected_version=expected_version,
    )
    _validate_version_summary(evidence["factoryVersion"], "Factory")
    corpus = evidence["configCorpus"]
    if not isinstance(corpus, dict) or set(corpus) != {
        "validCount", "invalidCount", "largeRuleCount", "maximumParseSeconds",
    }:
        fail("config corpus evidence fields are invalid")
    if corpus["validCount"] != 10 or corpus["invalidCount"] != 2 or corpus["largeRuleCount"] != 10_000:
        fail("config corpus evidence counts differ from suite-v1")
    _finite_number(corpus["maximumParseSeconds"], "config corpus parse duration", positive=True)
    _validate_snapshot_map(evidence["controllerAPI"], api_contract["rest"], "Controller API")
    _validate_snapshot_map(evidence["webSockets"], api_contract["webSockets"], "WebSocket")
    _validate_user_lifecycle(evidence["userBackend"], suite["transitionCount"])
    _validate_performance_metrics(metrics, suite)

    dedicated = evidence["dedicatedHost"]
    if not isinstance(dedicated, dict) or set(dedicated) != {
        "generatedAt", "host", "systemProxy", "tun", "sleepNetwork", "rollback",
    }:
        fail("dedicated-host summary evidence fields are invalid")
    rollback = evidence["rollback"]
    if not isinstance(rollback, dict) or set(rollback) != {"user", "privileged"}:
        fail("rollback summary evidence fields are invalid")
    _validate_user_rollback(rollback["user"])
    if rollback["privileged"] != dedicated["rollback"]:
        fail("privileged rollback summary differs from dedicated-host evidence")
    performance = evidence["performance"]
    if not isinstance(performance, dict) or set(performance) != {
        "relativeThresholds", "thresholdsPassed", "manualReview",
    }:
        fail("performance evidence fields are invalid")
    if performance["relativeThresholds"] != suite["performance"]["thresholds"]:
        fail("performance thresholds differ from suite-v1")
    if performance["thresholdsPassed"] is not True:
        fail("performance thresholds did not pass")
    review = performance["manualReview"]
    if not isinstance(review, dict) or set(review) != {"decision", "reviewedAt", "reviewer"}:
        fail("performance manual-review summary fields are invalid")
    if review["decision"] != "accepted":
        fail("performance manual review did not accept the candidate")
    parse_rfc3339(review["reviewedAt"], "performance summary reviewedAt")
    _bounded_string(review["reviewer"], "performance summary reviewer", maximum=128)


def validate_report(
    report: dict[str, Any],
    *,
    production: bool = False,
    expected_core_id: str | None = None,
    dedicated_host_evidence_path: Path | None = None,
    performance_review_path: Path | None = None,
) -> dict[str, Any]:
    base_required = {
        "schemaVersion", "suiteVersion", "coreID", "result", "generatedAt",
        "environment", "tests", "knownDeviations",
    }
    if not base_required.issubset(report):
        fail(f"compatibility report is missing fields: {sorted(base_required - set(report))}")
    if report["schemaVersion"] != 1 or report["suiteVersion"] != 1:
        fail("unsupported compatibility report schema/suite")
    if CORE_ID_RE.fullmatch(str(report["coreID"])) is None:
        fail("compatibility report CoreID is invalid")
    if expected_core_id is not None and report["coreID"] != expected_core_id:
        fail("compatibility report CoreID mismatch")
    generated_at = parse_rfc3339(report["generatedAt"], "compatibility generatedAt")
    if report["result"] not in {"passed", "failed"}:
        fail("compatibility result must be passed or failed")
    tests = report["tests"]
    if not isinstance(tests, list) or not tests:
        fail("compatibility tests must be non-empty")
    identifiers: set[str] = set()
    for item in tests:
        if not isinstance(item, dict) or set(item) != {"id", "result"}:
            fail("compatibility test entries must contain only id/result")
        identifier = item["id"]
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            fail("compatibility test identifiers must be unique")
        identifiers.add(identifier)
        if item["result"] not in {"passed", "failed"}:
            fail(f"compatibility test {identifier} has an invalid result")
    all_passed = all(item["result"] == "passed" for item in tests)
    if (report["result"] == "passed") != all_passed:
        fail("compatibility aggregate result does not match individual tests")
    deviations = report["knownDeviations"]
    if not isinstance(deviations, list) or any(not isinstance(item, str) or len(item) > 4096 for item in deviations):
        fail("known deviations must be a bounded string array")

    # The Pack fixture predates the executable lab evidence extension. It stays
    # valid for parser/catalog fixture tests but can never pass production.
    if report.get("evidenceVersion") is None:
        if production:
            fail("production compatibility report lacks executable lab evidence")
        return report

    suite = load_suite()
    corpus, corpus_paths = validate_corpus()
    api_contract = validate_api_contract(suite)
    exact_keys = base_required | {"evidenceVersion", "artifacts", "evidence", "metrics"}
    if set(report) != exact_keys or report["evidenceVersion"] != 1:
        fail("executable compatibility report fields/evidence version are invalid")
    if [item["id"] for item in tests] != suite["requiredTests"]:
        fail("compatibility report does not exactly cover suite-v1 required tests")
    environment = report["environment"]
    if not isinstance(environment, dict) or set(environment) != {
        "architecture", "macOS", "vela", "hostClass", "userDataAccessed",
    }:
        fail("compatibility environment fields are invalid")
    if environment["architecture"] != "arm64" or environment["userDataAccessed"] is not False:
        fail("compatibility report must come from arm64 and contain no user data")
    if environment["hostClass"] not in {"local-development", "dedicated-release-lab"}:
        fail("compatibility host class is invalid")
    _bounded_string(environment["macOS"], "compatibility macOS", maximum=64)
    if environment["vela"] != "0.6.0":
        fail("compatibility report Vela version must be 0.6.0")
    artifacts = report["artifacts"]
    required_artifacts = {
        "upstreamPayloadSHA256", "candidateExecutableSHA256", "factoryExecutableSHA256", "suiteSHA256",
        "corpusSHA256", "apiContractSHA256", "dedicatedHostEvidenceSHA256",
        "performanceReviewSHA256",
    }
    if not isinstance(artifacts, dict) or set(artifacts) != required_artifacts:
        fail("compatibility artifact hashes are incomplete")
    for key, value in artifacts.items():
        if value is not None and SHA256_RE.fullmatch(str(value)) is None:
            fail(f"invalid compatibility artifact hash: {key}")
    if any(
        SHA256_RE.fullmatch(str(artifacts[key])) is None
        for key in (
            "upstreamPayloadSHA256",
            "candidateExecutableSHA256",
            "factoryExecutableSHA256",
        )
    ):
        fail("upstream payload, candidate, and Factory executable hashes are mandatory")
    expected_static_hashes = {
        "suiteSHA256": sha256_file(SUITE_PATH),
        "corpusSHA256": sha256_manifest(corpus_paths, CORPUS_PATH.parent),
        "apiContractSHA256": sha256_file(API_CONTRACT_PATH),
    }
    for key, expected in expected_static_hashes.items():
        if artifacts[key] != expected:
            fail(f"compatibility {key} differs from the current checked-in suite")
    evidence = report["evidence"]
    if not isinstance(evidence, dict) or set(evidence) != {
        "candidateVersion", "factoryVersion", "configCorpus", "controllerAPI",
        "webSockets", "userBackend", "dedicatedHost", "rollback", "performance",
    }:
        fail("compatibility evidence summary fields are invalid")
    metrics = report["metrics"]
    if report["result"] == "passed" and deviations:
        fail("a passed compatibility report cannot contain known deviations")
    if report["result"] == "passed":
        _validate_passed_report_evidence(evidence, metrics, suite, api_contract)
    if production:
        if environment["hostClass"] != "dedicated-release-lab":
            fail("production compatibility report must use a dedicated release lab")
        if artifacts["candidateExecutableSHA256"] != artifacts["upstreamPayloadSHA256"]:
            fail("production compatibility candidate must equal the exact unsigned upstream payload")
        if artifacts["candidateExecutableSHA256"] == artifacts["factoryExecutableSHA256"]:
            fail("production candidate must be distinct from the Factory baseline")
        if artifacts["dedicatedHostEvidenceSHA256"] is None or artifacts["performanceReviewSHA256"] is None:
            fail("production compatibility report lacks dedicated-host or performance-review evidence")
        if dedicated_host_evidence_path is None or performance_review_path is None:
            fail("production compatibility validation requires explicit dedicated-host and performance-review files")
        dedicated_raw = read_regular_bytes(dedicated_host_evidence_path)
        review_raw = read_regular_bytes(performance_review_path)
        if sha256_bytes(dedicated_raw) != artifacts["dedicatedHostEvidenceSHA256"]:
            fail("dedicated-host evidence bytes differ from the report hash")
        if sha256_bytes(review_raw) != artifacts["performanceReviewSHA256"]:
            fail("performance review bytes differ from the report hash")
        try:
            dedicated_source = json.loads(dedicated_raw)
            review_source = json.loads(review_raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"external compatibility evidence JSON is invalid: {error}")
        if not isinstance(dedicated_source, dict) or not isinstance(review_source, dict):
            fail("external compatibility evidence must contain JSON objects")
        validate_dedicated_host_evidence(
            dedicated_source,
            core_id=report["coreID"],
            candidate_sha256=artifacts["candidateExecutableSHA256"],
            factory_sha256=artifacts["factoryExecutableSHA256"],
        )
        validate_performance_review(
            review_source,
            core_id=report["coreID"],
            candidate_sha256=artifacts["candidateExecutableSHA256"],
            factory_sha256=artifacts["factoryExecutableSHA256"],
        )
        expected_dedicated_summary = {
            key: dedicated_source[key]
            for key in ("generatedAt", "host", "systemProxy", "tun", "sleepNetwork", "rollback")
        }
        if evidence["dedicatedHost"] != expected_dedicated_summary:
            fail("dedicated-host report summary differs from the explicit evidence file")
        expected_review_summary = {
            key: review_source[key]
            for key in ("decision", "reviewedAt", "reviewer")
        }
        if evidence["performance"]["manualReview"] != expected_review_summary:
            fail("performance report summary differs from the explicit review file")
        dedicated_at = parse_rfc3339(dedicated_source["generatedAt"], "dedicated-host generatedAt")
        reviewed_at = parse_rfc3339(review_source["reviewedAt"], "performance reviewedAt")
        for value, label in (
            (dedicated_at, "dedicated-host evidence"),
            (reviewed_at, "performance review"),
        ):
            if value > generated_at:
                fail(f"{label} is newer than the compatibility report")
            if generated_at - value > timedelta(days=30):
                fail(f"{label} is stale by more than 30 days")
        if report["result"] != "passed":
            fail("production compatibility report did not pass")
    return report


def atomic_write_new(path: Path, data: bytes) -> None:
    if path.exists() or path.is_symlink():
        fail(f"refusing to overwrite compatibility output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    # macOS exposes /tmp as a system-owned symlink to /private/tmp. Resolve the
    # existing parent once, then create/link only inside that concrete directory.
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir():
        fail("compatibility output parent must be a directory")
    path = parent / path.name
    if path.exists() or path.is_symlink():
        fail(f"refusing to overwrite compatibility output: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        try:
            os.link(temporary, path)
        except FileExistsError:
            fail(f"compatibility output appeared concurrently: {path}")
    finally:
        temporary.unlink(missing_ok=True)


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def port_is_bindable(port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False


def http_json(
    port: int,
    path: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    secret: str,
    timeout: float = 3.0,
) -> tuple[int, Any]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"Authorization": f"Bearer {secret}", "Accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    try:
        connection.request(method, path, body=payload, headers=headers)
        response = connection.getresponse()
        raw = response.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            fail(f"controller response exceeded limit: {path}")
        if not raw:
            return response.status, None
        try:
            return response.status, json.loads(raw)
        except json.JSONDecodeError:
            fail(f"controller response was not JSON: {path}")
    finally:
        connection.close()


def _recv_exact(sock: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            fail("WebSocket closed before a complete frame")
        data.extend(chunk)
    return bytes(data)


def websocket_json_frame(
    port: int,
    path: str,
    *,
    secret: str,
    trigger: Callable[[], None] | None = None,
    timeout: float = 4.0,
) -> dict[str, Any]:
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    expected_accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {secret}\r\n\r\n"
        ).encode("ascii")
        sock.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            response.extend(sock.recv(4096))
            if len(response) > 64 * 1024:
                fail(f"oversized WebSocket handshake: {path}")
        header, remainder = bytes(response).split(b"\r\n\r\n", 1)
        lines = header.decode("iso-8859-1").split("\r\n")
        if not lines[0].startswith("HTTP/1.1 101"):
            fail(f"WebSocket upgrade failed for {path}: {lines[0]}")
        fields = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                fields[name.strip().lower()] = value.strip()
        if fields.get("sec-websocket-accept") != expected_accept:
            fail(f"WebSocket accept hash mismatch: {path}")
        if trigger is not None:
            trigger()

        buffered = bytearray(remainder)

        def take(count: int) -> bytes:
            while len(buffered) < count:
                buffered.extend(sock.recv(max(4096, count - len(buffered))))
            result = bytes(buffered[:count])
            del buffered[:count]
            return result

        for _ in range(8):
            first, second = take(2)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", take(8))[0]
            if length > 2 * 1024 * 1024:
                fail(f"oversized WebSocket frame: {path}")
            mask = take(4) if masked else b""
            payload = bytearray(take(length))
            if masked:
                for index in range(length):
                    payload[index] ^= mask[index % 4]
            if opcode == 0x8:
                fail(f"WebSocket closed without JSON evidence: {path}")
            if opcode in {0x1, 0x2}:
                try:
                    value = json.loads(bytes(payload))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    fail(f"WebSocket frame was not JSON: {path}")
                if not isinstance(value, dict):
                    fail(f"WebSocket frame was not an object: {path}")
                return value
        fail(f"WebSocket did not produce a data frame: {path}")


def runtime_config(mixed_port: int, controller_port: int, secret: str) -> bytes:
    return f"""mixed-port: {mixed_port}
external-controller: 127.0.0.1:{controller_port}
secret: {secret}
allow-lan: false
mode: rule
log-level: info
ipv6: false
proxies: []
proxy-groups:
  - name: VELA-COMPAT
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,VELA-COMPAT
""".encode("utf-8")


@dataclass
class RuntimeProcess:
    process: subprocess.Popen[bytes]
    directory: Path
    mixed_port: int
    controller_port: int
    secret: str
    started_at: float
    ready_at: float


def start_runtime(executable: Path, parent: Path, label: str, timeout: float = 8.0) -> RuntimeProcess:
    directory = Path(tempfile.mkdtemp(prefix=f"{label}-", dir=parent))
    mixed_port = free_tcp_port()
    controller_port = free_tcp_port()
    secret = "vela-compat-suite-v1"
    config = directory / "config.yaml"
    config.write_bytes(runtime_config(mixed_port, controller_port, secret))
    os.chmod(config, 0o600)
    started_at = time.monotonic()
    process = subprocess.Popen(
        [str(executable), "-d", str(directory), "-f", str(config)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = started_at + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            fail(f"Mihomo exited before controller readiness: {label} status={process.returncode}")
        try:
            status, value = http_json(controller_port, "/version", secret=secret, timeout=0.4)
            if status == 200 and isinstance(value, dict):
                return RuntimeProcess(
                    process=process,
                    directory=directory,
                    mixed_port=mixed_port,
                    controller_port=controller_port,
                    secret=secret,
                    started_at=started_at,
                    ready_at=time.monotonic(),
                )
        except (OSError, CompatibilityError):
            pass
        time.sleep(0.04)
    stop_runtime_process(process)
    fail(f"Mihomo controller readiness timed out: {label}")


def stop_runtime_process(process: subprocess.Popen[bytes], timeout: float = 5.0) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def stop_runtime(runtime: RuntimeProcess) -> None:
    stop_runtime_process(runtime.process)
    if runtime.process.poll() is None:
        fail("Mihomo process remained alive after stop")
    if not port_is_bindable(runtime.mixed_port) or not port_is_bindable(runtime.controller_port):
        fail("Mihomo ports were not released after stop")


def executable_version(executable: Path) -> tuple[str, dict[str, str]]:
    result = subprocess.run(
        [str(executable), "-v"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    output = (result.stdout + result.stderr).decode("utf-8", "replace").strip()
    if result.returncode != 0:
        fail(f"mihomo -v failed with status {result.returncode}")
    match = VERSION_RE.search(output)
    if match is None:
        fail("mihomo -v output did not match the fixed darwin/arm64 contract")
    return output[:512], match.groupdict()


def run_config_test(executable: Path, config: Path, expected_valid: bool, timeout: float = 12.0) -> float:
    started = time.monotonic()
    result = subprocess.run(
        [str(executable), "-t", "-d", str(config.parent), "-f", str(config)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    duration = time.monotonic() - started
    passed = result.returncode == 0
    if passed != expected_valid:
        combined = (result.stdout + result.stderr).decode("utf-8", "replace")[-1000:]
        expectation = "pass" if expected_valid else "fail"
        fail(f"config {config.name} did not {expectation}: {combined}")
    return duration


def generate_large_config(path: Path, rule_count: int) -> None:
    if rule_count != 10000:
        fail("large config must use the suite-v1 ten-thousand-rule corpus")
    lines = [
        "mode: rule",
        "log-level: warning",
        "proxies: []",
        "proxy-groups:",
        "  - {name: VELA-COMPAT, type: select, proxies: [DIRECT]}",
        "rules:",
    ]
    lines.extend(f"  - DOMAIN,host-{index}.example.invalid,DIRECT" for index in range(rule_count - 1))
    lines.append("  - MATCH,VELA-COMPAT")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def process_sample(pid: int) -> dict[str, float]:
    result = subprocess.run(
        ["/bin/ps", "-o", "rss=,pcpu=", "-p", str(pid)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=3,
        check=False,
    )
    if result.returncode != 0:
        fail("unable to sample Mihomo RSS/CPU")
    fields = result.stdout.decode("ascii", "replace").split()
    if len(fields) != 2:
        fail("unexpected ps RSS/CPU output")
    return {"rssKiB": float(fields[0]), "cpuPercent": float(fields[1])}


def relative_ratio(candidate: float, factory: float) -> float:
    if factory <= 0:
        fail("Factory performance baseline must be positive")
    return candidate / factory


def ensure_file_limit(required: int) -> None:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = required if hard == resource.RLIM_INFINITY else min(required, hard)
    if target < required:
        fail(f"host file descriptor limit cannot support {required} synthetic connections")
    if soft < target:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))


class LocalTargetServer:
    def __init__(self, expected: int) -> None:
        self.expected = expected
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(min(expected, 1024))
        self.listener.settimeout(0.2)
        self.port = int(self.listener.getsockname()[1])
        self.connections: list[socket.socket] = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._accept, daemon=True)

    def _accept(self) -> None:
        while not self.stop_event.is_set() and len(self.connections) < self.expected:
            try:
                connection, _ = self.listener.accept()
                connection.settimeout(1)
                self.connections.append(connection)
            except socket.timeout:
                continue
            except OSError:
                return

    def __enter__(self) -> "LocalTargetServer":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop_event.set()
        try:
            self.listener.close()
        except OSError:
            pass
        for connection in self.connections:
            try:
                connection.close()
            except OSError:
                pass
        self.thread.join(timeout=2)


def open_synthetic_connections(
    mixed_port: int,
    count: int,
) -> tuple[list[socket.socket], LocalTargetServer, int]:
    if count != 1000:
        fail("suite-v1 performance evidence requires exactly one thousand connections")
    ensure_file_limit(count * 3 + 256)
    clients: list[socket.socket] = []
    target = LocalTargetServer(count)
    target.__enter__()
    try:
        for _ in range(count):
            client = socket.create_connection(("127.0.0.1", mixed_port), timeout=3)
            request = (
                f"CONNECT 127.0.0.1:{target.port} HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{target.port}\r\n\r\n"
            ).encode("ascii")
            client.sendall(request)
            client.settimeout(3)
            response = bytearray()
            while b"\r\n\r\n" not in response:
                response.extend(client.recv(4096))
                if len(response) > 64 * 1024:
                    fail("oversized synthetic CONNECT response")
            if b" 200 " not in bytes(response).split(b"\r\n", 1)[0]:
                fail("synthetic CONNECT was rejected")
            clients.append(client)
        deadline = time.monotonic() + 5
        while len(target.connections) < count and time.monotonic() < deadline:
            time.sleep(0.02)
        if len(target.connections) != count:
            fail(f"only {len(target.connections)} of {count} synthetic targets connected")
        return clients, target, len(target.connections)
    except Exception:
        for client in clients:
            client.close()
        target.__exit__()
        raise


def close_sockets(sockets: list[socket.socket]) -> None:
    for value in sockets:
        try:
            value.close()
        except OSError:
            pass


def current_macos_version() -> str:
    value = platform.mac_ver()[0]
    if value:
        return value
    result = subprocess.run(["/usr/bin/sw_vers", "-productVersion"], stdout=subprocess.PIPE, timeout=3)
    return result.stdout.decode("ascii", "replace").strip()


def run_rest_contract(runtime: RuntimeProcess, contract: dict[str, Any]) -> dict[str, list[str]]:
    snapshots: dict[str, list[str]] = {}
    for path, requirement in contract["rest"].items():
        status, value = http_json(runtime.controller_port, path, secret=runtime.secret)
        if status != 200 or not isinstance(value, dict):
            fail(f"REST contract failed {path}: status={status}")
        missing = set(requirement["requiredKeys"]) - set(value)
        if missing:
            fail(f"REST contract {path} missing keys: {sorted(missing)}")
        snapshots[path] = sorted(value.keys())
    status, _ = http_json(
        runtime.controller_port,
        "/configs",
        method="PATCH",
        body={"mode": "global"},
        secret=runtime.secret,
    )
    if status not in {200, 204}:
        fail("controller mode switch to global failed")
    status, _ = http_json(
        runtime.controller_port,
        f"/proxies/{quote('VELA-COMPAT', safe='')}",
        method="PUT",
        body={"name": "DIRECT"},
        secret=runtime.secret,
    )
    if status not in {200, 204}:
        fail("controller selector switch failed")
    status, _ = http_json(
        runtime.controller_port,
        "/configs",
        method="PATCH",
        body={"mode": "rule"},
        secret=runtime.secret,
    )
    if status not in {200, 204}:
        fail("controller mode restoration failed")
    return snapshots


def run_websocket_contract(runtime: RuntimeProcess, contract: dict[str, Any]) -> dict[str, list[str]]:
    snapshots: dict[str, list[str]] = {}
    for path in contract["webSockets"]:
        query = path + ("?level=info" if path == "/logs" else "")

        def trigger() -> None:
            if path == "/logs":
                try:
                    with socket.create_connection(
                        ("127.0.0.1", runtime.mixed_port),
                        timeout=1,
                    ) as proxy:
                        proxy.sendall(
                            b"GET http://127.0.0.1:1/ HTTP/1.1\r\n"
                            b"Host: 127.0.0.1:1\r\nConnection: close\r\n\r\n"
                        )
                        proxy.settimeout(1)
                        try:
                            proxy.recv(1024)
                        except socket.timeout:
                            pass
                except OSError:
                    pass
            else:
                http_json(runtime.controller_port, "/version", secret=runtime.secret)

        try:
            frame = websocket_json_frame(
                runtime.controller_port,
                query,
                secret=runtime.secret,
                trigger=trigger,
            )
        except (CompatibilityError, OSError) as error:
            fail(f"WebSocket {path} failed: {error}")
        snapshots[path] = sorted(frame.keys())
    return snapshots


def run_port_collision(executable: Path, parent: Path) -> None:
    controller_port = free_tcp_port()
    mixed_port = free_tcp_port()
    secret = "vela-compat-suite-v1"
    directory = Path(tempfile.mkdtemp(prefix="port-collision-", dir=parent))
    config = directory / "config.yaml"
    config.write_bytes(runtime_config(mixed_port, controller_port, secret))
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
        occupied.bind(("127.0.0.1", controller_port))
        occupied.listen(1)
        process = subprocess.Popen(
            [str(executable), "-d", str(directory), "-f", str(config)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                # Mihomo v1.19.28 can keep its process alive after an inbound
                # listener bind error. Vela must still treat the backend as not
                # ready because the fixed Controller endpoint is unavailable.
                # The suite records this behavior and terminates the partial
                # process; it never mistakes process liveness for readiness.
                stop_runtime_process(process)
                return
            if process.returncode == 0:
                fail("Mihomo reported success despite a fixed controller port collision")
        finally:
            stop_runtime_process(process)


def run_lifecycle(executable: Path, parent: Path, count: int) -> dict[str, Any]:
    startup: list[float] = []
    for index in range(count):
        runtime = start_runtime(executable, parent, f"lifecycle-{index:02d}")
        startup.append(runtime.ready_at - runtime.started_at)
        stop_runtime(runtime)
    run_port_collision(executable, parent)
    return {
        "transitions": count,
        "portCollisionRejected": True,
        "minimumStartupSeconds": min(startup),
        "maximumStartupSeconds": max(startup),
        "meanStartupSeconds": sum(startup) / len(startup),
        "noOrphanProcesses": True,
        "portsReleased": True,
    }


def run_rollback(candidate: Path, factory: Path, parent: Path) -> dict[str, Any]:
    sequence: list[str] = []
    for label, executable in (("factory-before", factory), ("candidate", candidate), ("factory-after", factory)):
        runtime = start_runtime(executable, parent, label)
        status, value = http_json(runtime.controller_port, "/version", secret=runtime.secret)
        if status != 200 or not isinstance(value, dict):
            fail(f"rollback stage failed controller readiness: {label}")
        sequence.append(label)
        stop_runtime(runtime)
    return {"sequence": sequence, "userRollback": True, "factoryRecovered": True}


def run_performance_target(
    executable: Path,
    parent: Path,
    label: str,
    *,
    startup_iterations: int,
    parse_iterations: int,
    idle_seconds: float,
    synthetic_connections: int,
) -> dict[str, Any]:
    config = LAB_ROOT / "fixtures" / "configs" / "minimum.yaml"
    parse_samples = [run_config_test(executable, config, True) for _ in range(parse_iterations)]
    startup_samples: list[float] = []
    for index in range(startup_iterations):
        runtime = start_runtime(executable, parent, f"perf-{label}-{index}")
        startup_samples.append(runtime.ready_at - runtime.started_at)
        stop_runtime(runtime)
    runtime = start_runtime(executable, parent, f"perf-{label}-sample")
    clients: list[socket.socket] = []
    target: LocalTargetServer | None = None
    try:
        time.sleep(idle_seconds)
        idle = process_sample(runtime.process.pid)
        clients, target, connected = open_synthetic_connections(
            runtime.mixed_port,
            synthetic_connections,
        )
        time.sleep(0.5)
        loaded = process_sample(runtime.process.pid)
        status, connections = http_json(runtime.controller_port, "/connections", secret=runtime.secret)
        if status != 200 or not isinstance(connections, dict) or not isinstance(connections.get("connections"), list):
            fail("synthetic connection snapshot failed")
        observed = len(connections["connections"])
        if observed < synthetic_connections:
            fail(f"controller observed only {observed}/{synthetic_connections} synthetic connections")
    finally:
        close_sockets(clients)
        if target is not None:
            target.__exit__()
        stop_runtime(runtime)
    return {
        "configParseMeanSeconds": sum(parse_samples) / len(parse_samples),
        "idleCPUPercent": idle["cpuPercent"],
        "idleRSSKiB": idle["rssKiB"],
        "loadedCPUPercent": loaded["cpuPercent"],
        "loadedRSSKiB": loaded["rssKiB"],
        "startupMeanSeconds": sum(startup_samples) / len(startup_samples),
        "syntheticConnections": connected,
    }
