#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from schema_validation import load_json


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("documents", nargs="+")
    args = parser.parse_args()

    for value in args.documents:
        path = Path(value)
        load_json(path)
        print(f"Strict JSON validation passed: {path}")


if __name__ == "__main__":
    main()
