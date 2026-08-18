#!/usr/bin/env python3
"""Small, dependency-free JSON Schema validator for this visual-recovery pack.

The pack deliberately avoids downloading validation code in release CI.  This
module implements the Draft 2020-12 keywords used by the checked-in schemas;
unknown assertion keywords fail closed so a schema cannot silently outgrow the
validator.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any


class JSONSchemaValidationError(ValueError):
    def __init__(self, errors: list[str]) -> None:
        self.errors = errors
        super().__init__("JSON Schema validation failed:\n- " + "\n- ".join(errors))


SUPPORTED_KEYWORDS = {
    "$schema",
    "$id",
    "title",
    "description",
    "type",
    "const",
    "enum",
    "required",
    "properties",
    "additionalProperties",
    "items",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "minLength",
    "maxLength",
    "pattern",
    "format",
}
SUPPORTED_TYPES = {"object", "array", "string", "integer", "number", "boolean", "null"}

RFC3339_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def _reject_nonfinite_number(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value!r}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=_reject_nonfinite_number,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise JSONSchemaValidationError([f"{path}: invalid JSON: {error}"]) from error


def load_and_validate(instance_path: Path, schema_path: Path) -> Any:
    instance = load_json(instance_path)
    schema = load_json(schema_path)
    validate_instance(instance, schema, source=str(instance_path))
    return instance


def validate_instance(instance: Any, schema: dict[str, Any], source: str = "instance") -> None:
    errors: list[str] = []
    _validate_schema_definition(schema, "$", errors)
    if errors:
        raise JSONSchemaValidationError(
            [f"{source}: invalid schema: {error}" for error in errors]
        )
    _validate(instance, schema, "$", errors)
    if errors:
        raise JSONSchemaValidationError([f"{source}: {error}" for error in errors])


def _validate_schema_definition(
    schema: Any,
    path: str,
    errors: list[str],
) -> None:
    if not isinstance(schema, dict):
        errors.append(f"{path}: schema node must be an object")
        return

    unsupported = sorted(set(schema) - SUPPORTED_KEYWORDS)
    if unsupported:
        errors.append(f"{path}: unsupported schema keyword(s): {unsupported}")

    expected_type = schema.get("type")
    if expected_type is not None:
        type_names = [expected_type] if isinstance(expected_type, str) else expected_type
        if (
            not isinstance(type_names, list)
            or not type_names
            or not all(isinstance(item, str) for item in type_names)
        ):
            errors.append(f"{path}: schema type must be a string or non-empty string array")
        else:
            unknown_types = sorted(set(type_names) - SUPPORTED_TYPES)
            if unknown_types:
                errors.append(f"{path}: unsupported schema type(s): {unknown_types}")

    properties = schema.get("properties")
    if properties is not None:
        if not isinstance(properties, dict):
            errors.append(f"{path}: schema properties must be an object")
        else:
            for key, child in properties.items():
                _validate_schema_definition(child, _property_path(path, key), errors)

    items = schema.get("items")
    if items is not None:
        _validate_schema_definition(items, f"{path}.items", errors)

    additional = schema.get("additionalProperties")
    if additional is not None and not isinstance(additional, bool):
        _validate_schema_definition(additional, f"{path}.additionalProperties", errors)


def _validate(instance: Any, schema: Any, path: str, errors: list[str]) -> None:
    if not isinstance(schema, dict):
        errors.append(f"{path}: schema node must be an object")
        return

    unsupported = sorted(set(schema) - SUPPORTED_KEYWORDS)
    if unsupported:
        errors.append(f"{path}: unsupported schema keyword(s): {unsupported}")
        return

    expected_type = schema.get("type")
    if expected_type is not None:
        type_names = [expected_type] if isinstance(expected_type, str) else expected_type
        if not isinstance(type_names, list) or not all(
            isinstance(item, str) for item in type_names
        ):
            errors.append(f"{path}: schema type must be a string or string array")
            return
        if not any(_matches_type(instance, type_name) for type_name in type_names):
            errors.append(
                f"{path}: expected type {type_names}, got {_instance_type(instance)}"
            )
            return

    if "const" in schema and not _json_equal(instance, schema["const"]):
        errors.append(f"{path}: value does not equal required const")

    if "enum" in schema:
        values = schema["enum"]
        if not isinstance(values, list):
            errors.append(f"{path}: schema enum must be an array")
        elif not any(_json_equal(instance, value) for value in values):
            errors.append(f"{path}: value is not in enum {values}")

    if isinstance(instance, dict):
        _validate_object(instance, schema, path, errors)
    elif isinstance(instance, list):
        _validate_array(instance, schema, path, errors)
    elif isinstance(instance, str):
        _validate_string(instance, schema, path, errors)
    elif _is_number(instance):
        _validate_number(instance, schema, path, errors)


def _validate_object(
    instance: dict[str, Any],
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    required = schema.get("required", [])
    if not isinstance(required, list) or not all(isinstance(item, str) for item in required):
        errors.append(f"{path}: schema required must be a string array")
        return
    for key in required:
        if key not in instance:
            errors.append(f"{path}: missing required property {key!r}")

    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        errors.append(f"{path}: schema properties must be an object")
        return
    for key, child_schema in properties.items():
        if key in instance:
            _validate(instance[key], child_schema, _property_path(path, key), errors)

    additional = schema.get("additionalProperties", True)
    extras = sorted(set(instance) - set(properties))
    if additional is False:
        for key in extras:
            errors.append(f"{_property_path(path, key)}: additional property is not allowed")
    elif isinstance(additional, dict):
        for key in extras:
            _validate(instance[key], additional, _property_path(path, key), errors)
    elif additional is not True:
        errors.append(f"{path}: additionalProperties must be boolean or an object")


def _validate_array(
    instance: list[Any],
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    minimum = schema.get("minItems")
    maximum = schema.get("maxItems")
    if minimum is not None and len(instance) < minimum:
        errors.append(f"{path}: expected at least {minimum} item(s), got {len(instance)}")
    if maximum is not None and len(instance) > maximum:
        errors.append(f"{path}: expected at most {maximum} item(s), got {len(instance)}")
    if schema.get("uniqueItems") is True:
        canonical = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
        if len(canonical) != len(set(canonical)):
            errors.append(f"{path}: array items must be unique")

    item_schema = schema.get("items")
    if item_schema is not None:
        for index, value in enumerate(instance):
            _validate(value, item_schema, f"{path}[{index}]", errors)


def _validate_string(
    instance: str,
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    minimum = schema.get("minLength")
    maximum = schema.get("maxLength")
    if minimum is not None and len(instance) < minimum:
        errors.append(f"{path}: string is shorter than {minimum}")
    if maximum is not None and len(instance) > maximum:
        errors.append(f"{path}: string is longer than {maximum}")
    pattern = schema.get("pattern")
    if pattern is not None:
        try:
            matched = re.search(pattern, instance) is not None
        except re.error as error:
            errors.append(f"{path}: invalid schema regex: {error}")
        else:
            if not matched:
                errors.append(f"{path}: string does not match pattern {pattern!r}")
    format_name = schema.get("format")
    if format_name == "date-time" and not _valid_rfc3339(instance):
        errors.append(f"{path}: expected an RFC 3339 date-time")
    elif format_name not in {None, "date-time"}:
        errors.append(f"{path}: unsupported string format {format_name!r}")


def _validate_number(
    instance: int | float,
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    comparisons = (
        ("minimum", lambda value, limit: value >= limit, ">="),
        ("maximum", lambda value, limit: value <= limit, "<="),
        ("exclusiveMinimum", lambda value, limit: value > limit, ">"),
        ("exclusiveMaximum", lambda value, limit: value < limit, "<"),
    )
    for key, predicate, symbol in comparisons:
        if key in schema and not predicate(instance, schema[key]):
            errors.append(f"{path}: expected value {symbol} {schema[key]}")


def _matches_type(instance: Any, type_name: str) -> bool:
    return {
        "object": isinstance(instance, dict),
        "array": isinstance(instance, list),
        "string": isinstance(instance, str),
        "integer": isinstance(instance, int) and not isinstance(instance, bool),
        "number": _is_number(instance),
        "boolean": isinstance(instance, bool),
        "null": instance is None,
    }.get(type_name, False)


def _instance_type(instance: Any) -> str:
    if instance is None:
        return "null"
    if isinstance(instance, bool):
        return "boolean"
    if isinstance(instance, dict):
        return "object"
    if isinstance(instance, list):
        return "array"
    if isinstance(instance, str):
        return "string"
    if isinstance(instance, int):
        return "integer"
    if isinstance(instance, float):
        return "number"
    return type(instance).__name__


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _json_equal(left: Any, right: Any) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    return left == right


def _property_path(path: str, key: str) -> str:
    return f"{path}.{key}" if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) else f"{path}[{key!r}]"


def _valid_rfc3339(value: str) -> bool:
    if not RFC3339_PATTERN.fullmatch(value):
        return False
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        return False
    return parsed.tzinfo is not None
