#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


CLOSED_ISSUE_STATUSES = {"verified", "duplicate", "outOfScope"}


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def blockers(policy: dict[str, Any], readiness: dict[str, Any], channel: str) -> list[str]:
    results: list[str] = []
    for issue in readiness.get("issues", []):
        if issue.get("status") in CLOSED_ISSUE_STATUSES:
            continue
        for rule in policy.get("rules", []):
            if channel in rule.get("blocks", []) and issue.get("severity") in rule.get("severities", []):
                results.append(str(issue.get("id")))
    active = {
        item.get("id")
        for item in readiness.get("conditions", [])
        if item.get("active") is True
    }
    for rule in policy.get("rules", []):
        condition = rule.get("condition")
        if condition in active and channel in rule.get("blocks", []):
            results.append(str(condition))
    return sorted(set(results))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default="Hardening/config/stop-ship-policy.json")
    parser.add_argument("--readiness", default="Hardening/config/release-readiness.json")
    parser.add_argument("--channel", choices=["dogfood", "invite", "publicBeta", "stable"], required=True)
    args = parser.parse_args()
    try:
        found = blockers(load(Path(args.policy)), load(Path(args.readiness)), args.channel)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if found:
        print(f"Stop-Ship active for {args.channel}:", file=sys.stderr)
        for blocker in found:
            print(f"- {blocker}", file=sys.stderr)
        return 1
    print(f"No active Stop-Ship blocker for {args.channel}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
