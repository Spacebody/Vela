"""Small dependency-free validator for the JSON Schema subset used by Hardening."""

from __future__ import annotations

import datetime as dt
import json
import math
import re
import uuid
from typing import Any


class SchemaError(ValueError):
    pass


def _resolve(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise SchemaError(f"external schema reference is not supported: {reference}")
    value: Any = root
    for token in reference[2:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or token not in value:
            raise SchemaError(f"invalid schema reference: {reference}")
        value = value[token]
    if not isinstance(value, dict):
        raise SchemaError(f"schema reference is not an object: {reference}")
    return value


def _is_type(value: Any, kind: str) -> bool:
    return {
        "object": lambda: isinstance(value, dict),
        "array": lambda: isinstance(value, list),
        "string": lambda: isinstance(value, str),
        "integer": lambda: isinstance(value, int) and not isinstance(value, bool),
        "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": lambda: isinstance(value, bool),
        "null": lambda: value is None,
    }.get(kind, lambda: False)()


def _format(value: str, name: str) -> bool:
    try:
        if name == "uuid":
            parsed_uuid = uuid.UUID(value)
            if str(parsed_uuid) != value.lower() or len(value) != 36:
                return False
        elif name == "date":
            parsed_date = dt.date.fromisoformat(value)
            if parsed_date.isoformat() != value:
                return False
        elif name == "date-time":
            if re.fullmatch(
                r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
                value,
            ) is None:
                return False
            parsed_datetime = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed_datetime.tzinfo is None or parsed_datetime.utcoffset() is None:
                return False
        else:
            return True
    except ValueError:
        return False
    return True


def validate(value: Any, schema: dict[str, Any], root: dict[str, Any] | None = None, path: str = "$") -> None:
    root = schema if root is None else root
    if "$ref" in schema:
        validate(value, _resolve(root, schema["$ref"]), root, path)
        return

    for keyword in ("allOf", "anyOf", "oneOf"):
        if keyword not in schema:
            continue
        successes = 0
        failures: list[str] = []
        for branch in schema[keyword]:
            try:
                validate(value, branch, root, path)
                successes += 1
            except SchemaError as error:
                failures.append(str(error))
        if keyword == "allOf" and successes != len(schema[keyword]):
            raise SchemaError(f"{path}: allOf failed: {failures}")
        if keyword == "anyOf" and successes == 0:
            raise SchemaError(f"{path}: anyOf failed: {failures}")
        if keyword == "oneOf" and successes != 1:
            raise SchemaError(f"{path}: oneOf matched {successes} branches")

    if "const" in schema and value != schema["const"]:
        raise SchemaError(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError(f"{path}: value {value!r} is not in enum")
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, kind) for kind in kinds):
            raise SchemaError(f"{path}: expected type {kinds}, got {type(value).__name__}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in value]
        if missing:
            raise SchemaError(f"{path}: missing required properties {missing}")
        if len(value) < schema.get("minProperties", 0):
            raise SchemaError(f"{path}: too few properties")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            child = f"{path}.{key}"
            if key in properties:
                validate(item, properties[key], root, child)
            elif additional is False:
                raise SchemaError(f"{path}: unexpected property {key!r}")
            elif isinstance(additional, dict):
                validate(item, additional, root, child)

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise SchemaError(f"{path}: too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise SchemaError(f"{path}: too many items")
        if schema.get("uniqueItems"):
            fingerprints = [
                json.dumps(item, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                for item in value
            ]
            if len(fingerprints) != len(set(fingerprints)):
                raise SchemaError(f"{path}: items are not unique")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(value):
                validate(item, schema["items"], root, f"{path}[{index}]")

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise SchemaError(f"{path}: string is too short")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise SchemaError(f"{path}: string is too long")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            raise SchemaError(f"{path}: string does not match {schema['pattern']!r}")
        if "format" in schema and not _format(value, schema["format"]):
            raise SchemaError(f"{path}: invalid {schema['format']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            raise SchemaError(f"{path}: number is not finite")
        if "minimum" in schema and value < schema["minimum"]:
            raise SchemaError(f"{path}: below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            raise SchemaError(f"{path}: above maximum")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            raise SchemaError(f"{path}: below exclusive minimum")
