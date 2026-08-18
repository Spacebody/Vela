#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from schema_validation import load_and_validate


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("schema")
    parser.add_argument("instances", nargs="+")
    args = parser.parse_args()

    schema = Path(args.schema)
    for instance in args.instances:
        path = Path(instance)
        load_and_validate(path, schema)
        print(f"Schema validation passed: {path}")


if __name__ == "__main__":
    main()
