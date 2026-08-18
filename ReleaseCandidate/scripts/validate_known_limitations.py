#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from _common import GateError, load_json, main_error, reject_forbidden_text, validate_schema


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the Vela V1 Known Limitations policy")
    parser.add_argument("manifest")
    parser.add_argument("--version")
    parser.add_argument("--public-contract")
    args = parser.parse_args()
    try:
        value = load_json(Path(args.manifest), label="known limitations")
        validate_schema(value, "known-limitations.schema.json")
        reject_forbidden_text(value, label="known limitations")
        if args.version and value["version"] != args.version:
            raise GateError("known-limitations version differs from the release marketing version")

        help_topics: set[str] | None = None
        if args.public_contract:
            contract = load_json(Path(args.public_contract), label="Public Contract Freeze")
            topics = contract.get("helpTopics")
            if not isinstance(topics, list) or not all(isinstance(item, str) for item in topics):
                raise GateError("Public Contract Freeze has no valid helpTopics list")
            help_topics = set(topics)

        ids: set[str] = set()
        for item in value["limitations"]:
            item_id = item["id"]
            if item_id in ids:
                raise GateError(f"duplicate Known Limitation ID: {item_id}")
            ids.add(item_id)
            if item["stopShip"] is not False:
                raise GateError(f"Known Limitation cannot be Stop-Ship: {item_id}")
            if "material" in item["impact"].values():
                raise GateError(f"material security/data/network impact must remain Stop-Ship: {item_id}")
            if item["severity"] == "medium" and (
                not item["workaround"] or not item["targetVersion"]
            ):
                raise GateError(f"Medium limitation requires a workaround and target version: {item_id}")
            if item["workaround"] is None and any(
                impact != "none" for impact in item["impact"].values()
            ):
                raise GateError(f"limitation with impact requires a workaround: {item_id}")
            if help_topics is not None and item["helpTopicID"] not in help_topics:
                raise GateError(f"Known Limitation references an unfrozen Help topic: {item_id}")
        print(f"Known Limitations validation passed: {len(ids)} truthful item(s).")
        return 0
    except (GateError, OSError, KeyError, TypeError, ValueError) as error:
        return main_error(error)


if __name__ == "__main__":
    raise SystemExit(main())
