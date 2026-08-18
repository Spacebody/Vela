#!/usr/bin/env python3
"""Static security gate for GitHub workflow Action pins and permissions."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable


USES = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", re.M)
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW_PATH = re.compile(r"^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$")
YAML_KEY = re.compile(r"^[A-Za-z0-9_-]+$")
PERMISSION_VALUE = {"none", "read", "write"}
REVIEWED_PERMISSION_POLICIES = {
    ".github/workflows/release.yml": (
        {"contents": "read"},
        {
            "attest": {
                "contents": "read",
                "id-token": "write",
                "attestations": "write",
                "artifact-metadata": "write",
            }
        },
    )
}
DANGEROUS_RUN = {
    "curl-pipe-shell": re.compile(r"\bcurl\b[^\n|]*\|\s*(?:ba|z|k)?sh\b", re.I),
    "wget-pipe-shell": re.compile(r"\bwget\b[^\n|]*\|\s*(?:ba|z|k)?sh\b", re.I),
    "write-all": re.compile(r"^\s*permissions:\s*write-all\s*$", re.M),
    "untrusted-pr-title-in-run": re.compile(r"\$\{\{\s*github\.event\.pull_request\.(?:title|body|head\.label)\s*\}\}"),
}


def workflow_paths(values: list[str]) -> Iterable[Path]:
    for raw in values:
        path = Path(raw)
        if path.is_dir():
            yield from sorted([*path.glob("*.yml"), *path.glob("*.yaml")])
        else:
            yield path


def repository(action: str) -> str:
    parts = action.split("/")
    if len(parts) < 2:
        return action
    return "/".join(parts[:2])


def structural_lines(text: str) -> list[tuple[int, int, str]]:
    """Return YAML structure lines while omitting comments and block scalars.

    This is intentionally a small fail-closed reader, not a general YAML parser. The
    workflows use block mappings for permissions; aliases, flow mappings, tabs, and
    scalar permission shorthands are rejected by ``permission_blocks``.
    """

    result: list[tuple[int, int, str]] = []
    scalar_indent: int | None = None
    for line_number, raw in enumerate(text.splitlines(), start=1):
        if "\t" in raw[: len(raw) - len(raw.lstrip(" \t"))]:
            raise ValueError(f"line {line_number}: tabs are forbidden in YAML indentation")
        stripped = raw.strip()
        indent = len(raw) - len(raw.lstrip(" "))
        if scalar_indent is not None:
            if not stripped or indent > scalar_indent:
                continue
            scalar_indent = None
        if not stripped or stripped.startswith("#"):
            continue
        result.append((line_number, indent, stripped))
        if re.search(r":\s*[|>][+-]?\s*(?:#.*)?$", stripped):
            scalar_indent = indent
    return result


def permission_blocks(text: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Read top-level and job-level permission mappings from a workflow."""

    lines = structural_lines(text)
    top_level: dict[str, str] | None = None
    jobs: dict[str, dict[str, str]] = {}
    in_jobs = False
    current_job: str | None = None

    for index, (line_number, indent, content) in enumerate(lines):
        if indent == 0:
            in_jobs = content == "jobs:"
            current_job = None
        elif in_jobs and indent == 2:
            match = re.fullmatch(r"([A-Za-z0-9_-]+):", content)
            if match is None:
                raise ValueError(f"line {line_number}: unsupported job mapping syntax")
            current_job = match.group(1)

        permission_key = re.match(
            r"(?:-\s*)?(?:permissions|['\"]permissions['\"])\s*:",
            content,
        )
        if permission_key is None:
            continue
        if content != "permissions:":
            raise ValueError(
                f"line {line_number}: permissions must use an explicit block mapping"
            )
        if indent == 0:
            scope = "top-level"
            if top_level is not None:
                raise ValueError(f"line {line_number}: duplicate top-level permissions")
        elif in_jobs and current_job is not None and indent == 4:
            scope = f"job {current_job}"
            if current_job in jobs:
                raise ValueError(f"line {line_number}: duplicate permissions for job {current_job}")
        else:
            raise ValueError(
                f"line {line_number}: permissions are allowed only at workflow or job level"
            )

        values: dict[str, str] = {}
        for child_number, child_indent, child_content in lines[index + 1 :]:
            if child_indent <= indent:
                break
            if child_indent != indent + 2:
                raise ValueError(
                    f"line {child_number}: nested or malformed entry in {scope} permissions"
                )
            match = re.fullmatch(r"([A-Za-z0-9_-]+):\s*(none|read|write)", child_content)
            if match is None:
                raise ValueError(
                    f"line {child_number}: invalid entry in {scope} permissions"
                )
            key, value = match.groups()
            if key in values:
                raise ValueError(f"line {child_number}: duplicate permission {key} in {scope}")
            values[key] = value
        if not values:
            raise ValueError(f"line {line_number}: {scope} permissions must not be empty")
        if scope == "top-level":
            top_level = values
        else:
            assert current_job is not None
            jobs[current_job] = values

    if top_level is None:
        raise ValueError("missing explicit top-level permissions")
    return top_level, jobs


def load_permission_policies(
    registry: dict[str, object],
) -> dict[str, tuple[dict[str, str], dict[str, dict[str, str]]]]:
    policies: dict[str, tuple[dict[str, str], dict[str, dict[str, str]]]] = {}
    raw_policies = registry["workflowPermissionPolicies"]
    if not isinstance(raw_policies, list):
        raise ValueError("workflowPermissionPolicies must be an array")
    for item in raw_policies:
        if not isinstance(item, dict) or set(item) != {
            "workflow",
            "topLevelPermissions",
            "jobOverrides",
        }:
            raise ValueError("invalid workflow permission policy envelope")
        workflow = item["workflow"]
        top_level = item["topLevelPermissions"]
        overrides = item["jobOverrides"]
        if not isinstance(workflow, str) or not WORKFLOW_PATH.fullmatch(workflow):
            raise ValueError(f"invalid reviewed workflow path: {workflow!r}")
        if workflow in policies:
            raise ValueError(f"duplicate workflow permission policy: {workflow}")
        if not isinstance(top_level, dict) or not top_level:
            raise ValueError(f"invalid top-level permission policy for {workflow}")
        if not isinstance(overrides, dict) or not overrides:
            raise ValueError(f"job override policy must not be empty for {workflow}")
        normalized_top: dict[str, str] = {}
        for key, value in top_level.items():
            if (
                not isinstance(key, str)
                or not YAML_KEY.fullmatch(key)
                or value not in PERMISSION_VALUE
            ):
                raise ValueError(f"invalid reviewed top-level permission for {workflow}")
            normalized_top[key] = value
        normalized_jobs: dict[str, dict[str, str]] = {}
        for job, permission_map in overrides.items():
            if not isinstance(job, str) or not YAML_KEY.fullmatch(job):
                raise ValueError(f"invalid reviewed job name for {workflow}")
            if not isinstance(permission_map, dict) or not permission_map:
                raise ValueError(f"invalid reviewed permissions for {workflow} job {job}")
            normalized_permissions: dict[str, str] = {}
            for key, value in permission_map.items():
                if (
                    not isinstance(key, str)
                    or not YAML_KEY.fullmatch(key)
                    or value not in PERMISSION_VALUE
                ):
                    raise ValueError(f"invalid reviewed permissions for {workflow} job {job}")
                normalized_permissions[key] = value
            if "write" not in normalized_permissions.values():
                raise ValueError(f"unnecessary read-only job override for {workflow} job {job}")
            normalized_jobs[job] = normalized_permissions
        policies[workflow] = (normalized_top, normalized_jobs)
    return policies


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow", nargs="+")
    parser.add_argument("--registry", default="Hardening/config/github-actions.json")
    args = parser.parse_args()
    failures: list[str] = []
    try:
        registry = json.loads(Path(args.registry).read_text(encoding="utf-8"))
        if set(registry) != {
            "schemaVersion",
            "verifiedAt",
            "actions",
            "workflowPermissionPolicies",
            "notes",
        } or registry["schemaVersion"] != 2:
            raise ValueError("invalid Action pin registry envelope")
        permission_policies = load_permission_policies(registry)
        if permission_policies != REVIEWED_PERMISSION_POLICIES:
            raise ValueError(
                "registry must contain only the exact reviewed V0.9 release attestation policy"
            )
        registry_path = Path(args.registry).resolve(strict=True)
        if registry_path.parent.name != "config" or registry_path.parent.parent.name != "Hardening":
            raise ValueError("registry must be located at Hardening/config")
        repository_root = registry_path.parent.parent.parent
        approved: dict[str, set[str]] = {}
        for item in registry["actions"]:
            repo = item["repository"]
            sha = item["sha"]
            if not FULL_SHA.fullmatch(sha):
                raise ValueError(f"registry contains a non-SHA pin: {repo}@{sha}")
            approved.setdefault(repo, set()).add(sha)
        paths = list(workflow_paths(args.workflow))
        if not paths:
            raise ValueError("no workflows selected")
        for path in paths:
            if path.is_symlink():
                failures.append(f"{path}: workflow path must not be a symlink")
                continue
            text = path.read_text(encoding="utf-8")
            if "__PIN_" in text or "__REPLACE" in text:
                failures.append(f"{path}: contains a placeholder")
            if re.search(r"^\s*pull_request_target\s*:", text, re.M):
                failures.append(f"{path}: pull_request_target is forbidden")
            try:
                top_level_permissions, job_permissions = permission_blocks(text)
            except ValueError as error:
                failures.append(f"{path}: {error}")
                top_level_permissions, job_permissions = {}, {}
            try:
                workflow_id = path.resolve(strict=True).relative_to(repository_root).as_posix()
            except ValueError:
                workflow_id = None
            policy = permission_policies.get(workflow_id or "")
            if policy is None:
                if job_permissions:
                    failures.append(
                        f"{path}: job-level permissions are absent from the reviewed registry policy"
                    )
            else:
                expected_top_level, expected_jobs = policy
                if top_level_permissions != expected_top_level:
                    failures.append(
                        f"{path}: top-level permissions differ from the reviewed registry policy"
                    )
                if job_permissions != expected_jobs:
                    failures.append(
                        f"{path}: job-level permissions differ from the reviewed registry policy"
                    )
            for name, pattern in DANGEROUS_RUN.items():
                if pattern.search(text):
                    failures.append(f"{path}: dangerous workflow pattern {name}")
            uses_values = USES.findall(text)
            for value in uses_values:
                if value.startswith("./"):
                    failures.append(f"{path}: local Action requires an explicit validator policy: {value}")
                    continue
                if value.startswith("docker://"):
                    if re.search(r"@sha256:[0-9a-f]{64}$", value) is None:
                        failures.append(f"{path}: Docker Action is not pinned to a sha256 digest: {value}")
                    continue
                if "@" not in value:
                    failures.append(f"{path}: unparseable Action reference: {value}")
                    continue
                action, ref = value.rsplit("@", 1)
                if not FULL_SHA.fullmatch(ref):
                    failures.append(f"{path}: {action}@{ref} is not pinned to a full SHA")
                    continue
                repo = repository(action)
                if ref not in approved.get(repo, set()):
                    failures.append(f"{path}: {action}@{ref} is absent from the reviewed pin registry")
                if repo == "actions/checkout":
                    start = text.find(f"uses: {action}@{ref}")
                    following = text[start:start + 500]
                    if "persist-credentials: false" not in following:
                        failures.append(f"{path}: checkout must disable persisted credentials")
            if "uses:" in text and not uses_values:
                failures.append(f"{path}: could not parse Action uses entries")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if failures:
        print("Workflow validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"Validated {len(paths)} workflow(s) against full-SHA Action pins.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
