#!/usr/bin/env python3
"""Cross-check Vela's visual-recovery contracts and repository manifests.

The pack-level schema validators prove that each document is structurally valid.
This repository validator proves that the documents describe the same closed set
of pages, page states, fixtures, Debug launch allowlists, and baseline axes.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


PACK_RELATIVE = Path("Docs/Vela-Visual-Recovery-v2-Codex-Pack")
VISUAL_RELATIVE = Path("VisualRecovery")
INSPECTOR_VALUES = {"open", "closed", "na"}
CAPTURE_BOUNDARIES = {"mainWindow", "menu", "sheet"}
CROPPED_BOUNDARY_PAGES = {
    "menu": "menuBar",
    "sheet": "tunFlow",
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def load_json(path: Path, failures: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        failures.append(f"{path}: could not load JSON: {error}")
        return {}
    if not isinstance(value, dict):
        failures.append(f"{path}: top-level JSON value must be an object")
        return {}
    return value


def string_list(
    value: Any,
    label: str,
    failures: list[str],
) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        failures.append(f"{label}: expected an array of strings")
        return []
    return value


def report_set_difference(
    label: str,
    actual: set[str],
    expected: set[str],
    failures: list[str],
) -> None:
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        failures.append(f"{label}: missing {missing}")
    if unexpected:
        failures.append(f"{label}: unexpected {unexpected}")


def swift_enum_raw_values(
    source: str,
    enum_name: str,
    failures: list[str],
) -> set[str]:
    declaration = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^{{]*{{", source)
    if declaration is None:
        failures.append(f"Debug allowlist: enum {enum_name} was not found")
        return set()

    opening_brace = source.find("{", declaration.start())
    depth = 0
    closing_brace: int | None = None
    for index in range(opening_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                closing_brace = index
                break
    if closing_brace is None:
        failures.append(f"Debug allowlist: enum {enum_name} has no closing brace")
        return set()

    values: list[str] = []
    block = source[opening_brace + 1 : closing_brace]
    for line in block.splitlines():
        declaration_match = re.match(r"^\s*case\s+([A-Za-z_].*?)\s*(?://.*)?$", line)
        if declaration_match is None:
            continue
        declaration_text = declaration_match.group(1)
        # Switch cases inside enum methods begin with a dot and are intentionally
        # excluded by the declaration regex above.
        for item in declaration_text.split(","):
            item_match = re.fullmatch(
                r'\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*"([^"]+)")?\s*',
                item,
            )
            if item_match is None:
                failures.append(
                    f"Debug allowlist: could not parse {enum_name} case {item.strip()!r}"
                )
                continue
            values.append(item_match.group(2) or item_match.group(1))

    if len(values) != len(set(values)):
        failures.append(f"Debug allowlist: enum {enum_name} has duplicate raw values")
    if not values:
        failures.append(f"Debug allowlist: enum {enum_name} has no cases")
    return set(values)


def swift_page_state_allowlist(
    source: str,
    failures: list[str],
) -> dict[str, set[str]]:
    declaration = re.search(
        r"\bstatic\s+func\s+states\s*\(\s*for\s+page\s*:\s*Page\s*\)"
        r"\s*->\s*\[\s*State\s*\]\s*{",
        source,
    )
    if declaration is None:
        declaration = re.search(
            r"\bvar\s+registeredStates\s*:\s*Set\s*<\s*State\s*>\s*{",
            source,
        )
        if declaration is None:
            failures.append("Debug allowlist: typed page/state catalog was not found")
            return {}

    opening_brace = source.find("{", declaration.start())
    depth = 0
    closing_brace: int | None = None
    for index in range(opening_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                closing_brace = index
                break
    if closing_brace is None:
        failures.append("Debug allowlist: typed page/state catalog has no closing brace")
        return {}

    block = source[opening_brace + 1 : closing_brace]
    result: dict[str, set[str]] = {}
    case_pattern = re.compile(
        r"case\s+(?P<pages>\.[A-Za-z_][A-Za-z0-9_]*"
        r"(?:\s*,\s*\.[A-Za-z_][A-Za-z0-9_]*)*)\s*:"
        r"\s*\[(?P<states>[^\]]*)\]",
        re.DOTALL,
    )
    for match in case_pattern.finditer(block):
        pages = re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)", match.group("pages"))
        states = re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)", match.group("states"))
        if not states:
            failures.append(
                f"Debug allowlist: page/state catalog case {pages!r} has no states"
            )
        for page in pages:
            if page in result:
                failures.append(
                    f"Debug allowlist: page/state catalog declares page {page!r} twice"
                )
            result[page] = set(states)
    if not result:
        failures.append("Debug allowlist: page/state catalog has no parseable cases")
    return result


def validate_repository(root: Path) -> list[str]:
    root = root.resolve()
    failures: list[str] = []
    contracts_root = root / VISUAL_RELATIVE / "Contracts"
    contract_paths = sorted(contracts_root.glob("*.json"))
    if not contract_paths:
        return [f"{contracts_root}: no page contracts found"]

    contract_pages: set[str] = set()
    contract_fixture_fields: dict[str, tuple[str, str]] = {}
    contract_states: set[str] = set()
    contract_states_by_page: dict[str, set[str]] = {}

    for path in contract_paths:
        contract = load_json(path, failures)
        page = contract.get("page")
        if not isinstance(page, str) or not page:
            failures.append(f"{path}: page must be a non-empty string")
            continue
        if page in contract_pages:
            failures.append(f"{path}: duplicate contract page {page!r}")
        contract_pages.add(page)

        states = string_list(contract.get("requiredStates"), f"{path}: requiredStates", failures)
        fixtures = string_list(contract.get("fixtures"), f"{path}: fixtures", failures)
        if len(states) != len(set(states)):
            failures.append(f"{path}: requiredStates contains duplicates")
        if len(fixtures) != len(set(fixtures)):
            failures.append(f"{path}: fixtures contains duplicates")

        if len(fixtures) != len(states):
            failures.append(
                f"{path}: fixtures must map one-to-one to requiredStates"
            )
        contract_states.update(states)
        contract_states_by_page[page] = set(states)
        for state, fixture_id in zip(states, fixtures):
            if not fixture_id.startswith(f"{page}."):
                failures.append(
                    f"{path}: fixture ID {fixture_id!r} must use page prefix {page!r}"
                )
            if fixture_id in contract_fixture_fields:
                failures.append(f"{path}: duplicate fixture ID {fixture_id!r}")
            contract_fixture_fields[fixture_id] = (page, state)

    target_status_path = root / VISUAL_RELATIVE / "Targets/target-status.json"
    target_status = load_json(target_status_path, failures)
    target_pages = set(
        string_list(target_status.get("pages"), f"{target_status_path}: pages", failures)
    )
    report_set_difference(
        "target-status pages",
        target_pages,
        contract_pages,
        failures,
    )

    registry_path = root / VISUAL_RELATIVE / "Fixtures/fixture-registry.json"
    registry = load_json(registry_path, failures)
    registry_items = registry.get("fixtures")
    if not isinstance(registry_items, list):
        failures.append(f"{registry_path}: fixtures must be an array")
        registry_items = []

    registry_fields: dict[str, tuple[str, str]] = {}
    for index, item in enumerate(registry_items):
        label = f"{registry_path}: fixtures[{index}]"
        if not isinstance(item, dict):
            failures.append(f"{label}: fixture must be an object")
            continue
        fixture_id = item.get("id")
        page = item.get("page")
        state = item.get("state")
        if not all(isinstance(value, str) and value for value in (fixture_id, page, state)):
            failures.append(f"{label}: id, page, and state must be non-empty strings")
            continue
        assert isinstance(fixture_id, str)
        assert isinstance(page, str)
        assert isinstance(state, str)
        if fixture_id in registry_fields:
            failures.append(f"{label}: duplicate fixture ID {fixture_id!r}")
        registry_fields[fixture_id] = (page, state)
        contract_fields = contract_fixture_fields.get(fixture_id)
        if contract_fields is not None and contract_fields != (page, state):
            failures.append(
                f"{label}: page/state {(page, state)!r} != contract {contract_fields!r}"
            )

    report_set_difference(
        "fixture registry IDs",
        set(registry_fields),
        set(contract_fixture_fields),
        failures,
    )

    window_matrix_path = root / PACK_RELATIVE / "design/window-matrix.json"
    window_matrix = load_json(window_matrix_path, failures)
    declared_appearances = set(
        string_list(
            window_matrix.get("appearances"),
            f"{window_matrix_path}: appearances",
            failures,
        )
    )
    declared_locales = set(
        string_list(
            window_matrix.get("locales"),
            f"{window_matrix_path}: locales",
            failures,
        )
    )
    declared_window_values: set[str] = set()
    declared_image_dimensions: set[tuple[int, int]] = set()
    windows = window_matrix.get("windows")
    if not isinstance(windows, list):
        failures.append(f"{window_matrix_path}: windows must be an array")
        windows = []
    for index, window in enumerate(windows):
        label = f"{window_matrix_path}: windows[{index}]"
        if not isinstance(window, dict):
            failures.append(f"{label}: window must be an object")
            continue
        width = window.get("width")
        height = window.get("height")
        if (
            not isinstance(width, int)
            or isinstance(width, bool)
            or width <= 0
            or not isinstance(height, int)
            or isinstance(height, bool)
            or height <= 0
        ):
            failures.append(f"{label}: width and height must be positive integers")
            continue
        declared_window_values.add(f"{width}x{height}")
        # Approved targets may be captured at either of the pack-authorized 1x
        # or 2x scales. The baseline schema records pixel dimensions, while the
        # window matrix records the corresponding point dimensions.
        declared_image_dimensions.add((width, height))
        declared_image_dimensions.add((width * 2, height * 2))

    harness_path = root / "VelaVisualHarness/VisualUITestConfiguration.swift"
    try:
        harness_source = harness_path.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"{harness_path}: could not read Debug allowlist: {error}")
        harness_source = ""
    route_catalog_path = root / "VelaVisualHarness/VisualFixtureRouteCatalog.swift"
    try:
        route_catalog_source = route_catalog_path.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"{route_catalog_path}: could not read route catalog: {error}")
        route_catalog_source = ""
    debug_pages = swift_enum_raw_values(harness_source, "Page", failures)
    debug_states = swift_enum_raw_values(harness_source, "State", failures)
    debug_appearances = swift_enum_raw_values(harness_source, "Appearance", failures)
    debug_locales = swift_enum_raw_values(harness_source, "LocaleIdentifier", failures)
    debug_windows = swift_enum_raw_values(harness_source, "WindowSize", failures)
    debug_states_by_page = swift_page_state_allowlist(
        route_catalog_source + "\n" + harness_source,
        failures,
    )
    report_set_difference("Debug Page allowlist", debug_pages, contract_pages, failures)
    report_set_difference("Debug State allowlist", debug_states, contract_states, failures)
    report_set_difference(
        "Debug Appearance allowlist",
        debug_appearances,
        declared_appearances,
        failures,
    )
    report_set_difference(
        "Debug LocaleIdentifier allowlist",
        debug_locales,
        declared_locales,
        failures,
    )
    report_set_difference(
        "Debug WindowSize allowlist",
        debug_windows,
        declared_window_values,
        failures,
    )
    report_set_difference(
        "Debug typed page/state catalog pages",
        set(debug_states_by_page),
        contract_pages,
        failures,
    )
    for page in sorted(contract_pages & debug_states_by_page.keys()):
        report_set_difference(
            f"Debug typed page/state catalog[{page}]",
            debug_states_by_page[page],
            contract_states_by_page.get(page, set()),
            failures,
        )

    baseline_path = root / VISUAL_RELATIVE / "Targets/visual-baseline-manifest.json"
    baseline_manifest = load_json(baseline_path, failures)
    baselines = baseline_manifest.get("baselines")
    if not isinstance(baselines, list):
        failures.append(f"{baseline_path}: baselines must be an array")
        baselines = []
    baseline_scenarios: set[
        tuple[str, str, str, str, int, int, str, str]
    ] = set()
    for index, baseline in enumerate(baselines):
        label = f"{baseline_path}: baselines[{index}]"
        if not isinstance(baseline, dict):
            failures.append(f"{label}: baseline must be an object")
            continue
        page = baseline.get("page")
        state = baseline.get("state")
        appearance = baseline.get("appearance")
        locale = baseline.get("locale")
        width = baseline.get("width")
        height = baseline.get("height")
        inspector = baseline.get("inspector")
        capture_boundary = baseline.get("captureBoundary")
        sha256 = baseline.get("sha256")
        if not isinstance(page, str) or not isinstance(state, str):
            failures.append(f"{label}: page and state must be strings")
        else:
            registered_axes = set(registry_fields.values())
            if (page, state) not in registered_axes:
                failures.append(
                    f"{label}: unregistered page/state {f'{page}.{state}'!r}"
                )
        if appearance not in declared_appearances:
            failures.append(f"{label}: undeclared appearance {appearance!r}")
        if locale not in declared_locales:
            failures.append(f"{label}: undeclared locale {locale!r}")
        if inspector not in INSPECTOR_VALUES:
            failures.append(f"{label}: invalid inspector {inspector!r}")
        if capture_boundary not in CAPTURE_BOUNDARIES:
            failures.append(
                f"{label}: invalid captureBoundary {capture_boundary!r}"
            )
        if not isinstance(sha256, str) or SHA256_PATTERN.fullmatch(sha256) is None:
            failures.append(
                f"{label}: sha256 must be exactly 64 lowercase hexadecimal characters"
            )

        dimensions = (width, height)
        dimensions_are_positive_integers = (
            isinstance(width, int)
            and not isinstance(width, bool)
            and width > 0
            and isinstance(height, int)
            and not isinstance(height, bool)
            and height > 0
        )
        if not dimensions_are_positive_integers:
            failures.append(
                f"{label}: target dimensions must be positive integers, got {dimensions!r}"
            )
        elif capture_boundary == "mainWindow":
            if dimensions not in declared_image_dimensions:
                failures.append(
                    f"{label}: undeclared mainWindow target dimensions {dimensions!r}"
                )
        elif capture_boundary in CROPPED_BOUNDARY_PAGES:
            expected_page = CROPPED_BOUNDARY_PAGES[capture_boundary]
            if page != expected_page:
                failures.append(
                    f"{label}: captureBoundary {capture_boundary!r} is only valid "
                    f"for page {expected_page!r}, got {page!r}"
                )
        if (
            isinstance(page, str)
            and isinstance(state, str)
            and isinstance(appearance, str)
            and isinstance(locale, str)
            and isinstance(width, int)
            and not isinstance(width, bool)
            and isinstance(height, int)
            and not isinstance(height, bool)
            and height > 0
            and width > 0
            and isinstance(inspector, str)
            and inspector in INSPECTOR_VALUES
            and isinstance(capture_boundary, str)
            and capture_boundary in CAPTURE_BOUNDARIES
        ):
            scenario = (
                page,
                state,
                appearance,
                locale,
                width,
                height,
                inspector,
                capture_boundary,
            )
            if scenario in baseline_scenarios:
                failures.append(f"{label}: duplicate baseline scenario {scenario!r}")
            baseline_scenarios.add(scenario)

    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Vela repository root",
    )
    args = parser.parse_args()

    failures = validate_repository(Path(args.root))
    if failures:
        raise SystemExit(
            "Visual recovery contract validation failed:\n- " + "\n- ".join(failures)
        )
    print("Visual recovery contracts are exact and internally consistent.")


if __name__ == "__main__":
    main()
