#!/usr/bin/env python3
"""Dependency-free Vela V0.7 documentation and archive acceptance primitives."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import tempfile
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable
from urllib.parse import urlparse
from xml.parsers.expat import ExpatError


class AcceptanceError(ValueError):
    """A deterministic V0.7 acceptance failure."""


EXPECTED_LOCALES = ["en", "zh-Hans"]
EXPECTED_POLICY_FILES = [
    "ACCESSIBILITY.md",
    "PRIVACY.md",
    "SECURITY.md",
    "SUPPORT.md",
]
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
SEMVER_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BUILD_PATTERN = re.compile(r"20[0-9]{8}")
STABLE_KEY_PATTERN = re.compile(r"[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+")
HELP_ID_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
WORD_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]+")
INTERNAL_HELP_LINK_PATTERN = re.compile(r"\]\(help:([a-z0-9-]+)\)")
MARKDOWN_LINK_PATTERN = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)")
PRINTF_PATTERN = re.compile(
    r"%(?:[1-9][0-9]*\$)?[-+#0 ']*[0-9]*(?:\.[0-9]+)?"
    r"(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"
)
BRACE_PATTERN = re.compile(r"\{[A-Za-z_][A-Za-z0-9_.]*\}")
UNSAFE_HELP_PATTERNS = [
    re.compile(r"<\s*script", re.IGNORECASE),
    re.compile(r"<\s*iframe", re.IGNORECASE),
    re.compile(r"javascript\s*:", re.IGNORECASE),
    re.compile(r"\bfile\s*:", re.IGNORECASE),
    re.compile(r"\bdata\s*:", re.IGNORECASE),
    re.compile(r"<\s*img", re.IGNORECASE),
]
CONTENT_PLACEHOLDER_PATTERNS = [
    re.compile(r"\b(?:TODO|TBD|FIXME|CHANGEME)\b", re.IGNORECASE),
    re.compile(r"__[^\n]+__"),
    re.compile(r"<#.+?#>"),
    re.compile(r"example\.invalid", re.IGNORECASE),
    re.compile(r"replace\s+this\s+template", re.IGNORECASE),
    re.compile(r"replace\s+with\s+(?:a\s+)?real", re.IGNORECASE),
    re.compile(r"公开发布前[^\n]*(?:替换|真实)", re.IGNORECASE),
    re.compile(r"(?:本模板|模板)[^\n]*(?:替换|真实联系方式)", re.IGNORECASE),
    re.compile(r"(?:待补充|待替换|占位符)"),
]


def canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def help_json_bytes(value: object) -> bytes:
    """Match the checked-in Help generator's stable insertion-order format."""
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def sha256_file(path: Path) -> str:
    require_regular_file(path, "hash input")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise AcceptanceError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise AcceptanceError(f"{label} must be a regular non-symlink file: {path}")


def require_regular_directory(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise AcceptanceError(f"{label} is missing: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise AcceptanceError(f"{label} must be a regular non-symlink directory: {path}")


def load_json(path: Path, label: str) -> dict:
    require_regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"{label} is not valid UTF-8 JSON: {path}: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError(f"{label} must contain a JSON object: {path}")
    return value


def relative_path(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty repository-relative path")
    candidate = PurePosixPath(value)
    if (
        candidate.is_absolute()
        or "\\" in value
        or any(part in {"", ".", ".."} for part in candidate.parts)
    ):
        raise AcceptanceError(f"{label} is unsafe: {value!r}")
    return candidate


def contained_path(root: Path, value: object, label: str) -> Path:
    relative = relative_path(value, label)
    candidate = root.joinpath(*relative.parts)
    current = root
    for part in relative.parts:
        current = current / part
        if current.exists() or current.is_symlink():
            try:
                mode = current.lstat().st_mode
            except FileNotFoundError as error:
                raise AcceptanceError(f"{label} disappeared during validation: {current}") from error
            if stat.S_ISLNK(mode):
                raise AcceptanceError(f"{label} may not traverse a symlink: {current}")
    try:
        candidate.resolve(strict=False).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError) as error:
        raise AcceptanceError(f"{label} escapes its trusted root: {value!r}") from error
    return candidate


def load_config(repository_root: Path, config_path: Path) -> dict:
    root = repository_root.resolve(strict=True)
    if not config_path.is_absolute():
        config_path = contained_path(root, config_path.as_posix(), "documentation config")
    else:
        try:
            config_path.resolve(strict=False).relative_to(root)
        except ValueError as error:
            raise AcceptanceError("documentation config must be inside the repository") from error
    config = load_json(config_path, "documentation config")
    expected_keys = {
        "schemaVersion",
        "appVersion",
        "appBuild",
        "sourceDateEpoch",
        "locales",
        "resourceRoot",
        "catalogs",
        "help",
        "policies",
        "privacyManifest",
        "documentationManifest",
        "securityContact",
        "privacyReview",
        "archive",
    }
    if set(config) != expected_keys:
        raise AcceptanceError(
            "documentation config keys differ from the fail-closed V0.7 schema: "
            f"missing={sorted(expected_keys - set(config))}, "
            f"unexpected={sorted(set(config) - expected_keys)}"
        )
    if config["schemaVersion"] != 1:
        raise AcceptanceError("documentation config schemaVersion must be 1")
    if not isinstance(config["appVersion"], str) or SEMVER_PATTERN.fullmatch(
        config["appVersion"]
    ) is None:
        raise AcceptanceError("documentation config appVersion must be major.minor.patch")
    if not isinstance(config["appBuild"], int) or BUILD_PATTERN.fullmatch(
        str(config["appBuild"])
    ) is None:
        raise AcceptanceError("documentation config appBuild must use YYYYMMDDNN")
    if not isinstance(config["sourceDateEpoch"], int) or config["sourceDateEpoch"] < 0:
        raise AcceptanceError("documentation config sourceDateEpoch must be a non-negative integer")
    if config["locales"] != EXPECTED_LOCALES:
        raise AcceptanceError("documentation config locales must be exactly en and zh-Hans")
    relative_path(config["resourceRoot"], "resourceRoot")
    relative_path(config["privacyManifest"], "privacyManifest")
    relative_path(config["documentationManifest"], "documentationManifest")
    if not isinstance(config["catalogs"], list) or not config["catalogs"]:
        raise AcceptanceError("documentation config catalogs must be a non-empty array")
    catalog_names: list[str] = []
    for item in config["catalogs"]:
        if not isinstance(item, dict) or set(item) != {"name", "path"}:
            raise AcceptanceError("each catalog config must contain exactly name and path")
        if not isinstance(item["name"], str) or not item["name"]:
            raise AcceptanceError("catalog name must be non-empty")
        relative_path(item["path"], f"catalog {item['name']} path")
        catalog_names.append(item["name"])
    if sorted(catalog_names) != ["Errors", "InfoPlist", "Localizable"]:
        raise AcceptanceError("catalogs must be exactly Errors, InfoPlist, and Localizable")
    help_config = config["help"]
    if not isinstance(help_config, dict) or set(help_config) != {
        "root",
        "index",
        "articleHashes",
        "searchIndexPattern",
        "maximumArticleBytes",
    }:
        raise AcceptanceError("help config has unexpected structure")
    relative_path(help_config["root"], "help root")
    relative_path(help_config["index"], "help index")
    relative_path(help_config["articleHashes"], "help article hashes")
    pattern = help_config["searchIndexPattern"]
    if not isinstance(pattern, str) or pattern.count("{locale}") != 1:
        raise AcceptanceError("help searchIndexPattern must contain exactly one {locale}")
    for locale in EXPECTED_LOCALES:
        relative_path(pattern.format(locale=locale), f"help search index for {locale}")
    if not isinstance(help_config["maximumArticleBytes"], int) or not (
        1 <= help_config["maximumArticleBytes"] <= 1024 * 1024
    ):
        raise AcceptanceError("help maximumArticleBytes is outside the accepted range")
    policies = config["policies"]
    if not isinstance(policies, dict) or set(policies) != {"root", "files"}:
        raise AcceptanceError("policies config has unexpected structure")
    relative_path(policies["root"], "policies root")
    if policies["files"] != EXPECTED_POLICY_FILES:
        raise AcceptanceError("policy files must be the four reviewed V0.7 policy documents")
    review = config["privacyReview"]
    if not isinstance(review, dict) or set(review) != {
        "requiredReasonAPIsReviewed",
        "trackingAndDataReviewed",
        "reviewedBy",
        "reviewedAt",
    }:
        raise AcceptanceError("privacyReview has unexpected structure")
    archive = config["archive"]
    if not isinstance(archive, dict) or set(archive) != {"resourcesPath"}:
        raise AcceptanceError("archive config must contain only resourcesPath")
    if archive["resourcesPath"] != "Contents/Resources":
        raise AcceptanceError("archive resourcesPath must be Contents/Resources")
    return config


def configured_epoch(config: dict, *, require_environment: bool) -> int:
    raw = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    if not raw:
        if require_environment:
            raise AcceptanceError(
                "SOURCE_DATE_EPOCH is required for deterministic source acceptance"
            )
        return config["sourceDateEpoch"]
    if re.fullmatch(r"[0-9]+", raw) is None:
        raise AcceptanceError("SOURCE_DATE_EPOCH must be a non-negative integer")
    value = int(raw)
    if value != config["sourceDateEpoch"]:
        raise AcceptanceError(
            "SOURCE_DATE_EPOCH differs from Release/config/documentation.json"
        )
    return value


def generated_at(epoch: int) -> str:
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError) as error:
        raise AcceptanceError("SOURCE_DATE_EPOCH is outside the supported UTC range") from error


def resource_root(repository_root: Path, config: dict) -> Path:
    root = contained_path(repository_root, config["resourceRoot"], "resourceRoot")
    require_regular_directory(root, "V0.7 resource root")
    return root


def read_text_limited(path: Path, maximum: int, label: str) -> tuple[bytes, str]:
    require_regular_file(path, label)
    raw = path.read_bytes()
    if len(raw) > maximum:
        raise AcceptanceError(f"{label} exceeds {maximum} bytes: {path}")
    try:
        return raw, raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AcceptanceError(f"{label} is not UTF-8: {path}") from error


def strip_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"^[#>*\d.\s-]+", "", text, flags=re.MULTILINE)
    return text


def tokenize(text: str, locale: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", strip_markdown(text)).casefold()
    result = set(WORD_PATTERN.findall(normalized))
    if locale == "zh-Hans":
        for sequence in CJK_PATTERN.findall(normalized):
            result.add(sequence)
            result.update(sequence[index : index + 2] for index in range(max(0, len(sequence) - 1)))
    return sorted(token for token in result if token)


def build_search_index(help_root: Path, index: dict, locale: str) -> dict:
    output_articles = []
    for article in index["articles"]:
        metadata = article["locales"][locale]
        path = contained_path(help_root, metadata["path"], f"help article {article['id']}")
        raw, text = read_text_limited(path, 1024 * 1024, "help article")
        headings = re.findall(r"^#{1,3}\s+(.+)$", text, flags=re.MULTILINE)
        body = strip_markdown(text)
        output_articles.append(
            {
                "id": article["id"],
                "category": article["category"],
                "order": article["order"],
                "title": metadata["title"],
                "keywords": metadata["keywords"],
                "headings": headings,
                "tokens": tokenize(
                    " ".join(
                        [metadata["title"], *metadata["keywords"], *headings, body]
                    ),
                    locale,
                ),
                "excerpt": " ".join(body.split())[:240],
                "sha256": sha256_bytes(raw),
            }
        )
    return {"schemaVersion": 1, "locale": locale, "articles": output_articles}


def validate_help_root(help_root: Path, config: dict) -> dict:
    require_regular_directory(help_root, "Help resource directory")
    help_config = config["help"]
    index_path = contained_path(help_root, help_config["index"], "Help index")
    index = load_json(index_path, "Help index")
    if set(index) != {
        "schemaVersion",
        "contentSchemaVersion",
        "sourceLanguage",
        "supportedLocales",
        "categories",
        "articles",
    }:
        raise AcceptanceError("Help index has unexpected top-level keys")
    if index["schemaVersion"] != 1 or index["contentSchemaVersion"] != 1:
        raise AcceptanceError("Help index schema versions must both be 1")
    if index["sourceLanguage"] != "en" or index["supportedLocales"] != EXPECTED_LOCALES:
        raise AcceptanceError("Help index locale contract must be en plus zh-Hans")
    if not isinstance(index["categories"], list) or not isinstance(index["articles"], list):
        raise AcceptanceError("Help categories and articles must be arrays")
    category_ids: set[str] = set()
    for category in index["categories"]:
        if not isinstance(category, dict) or set(category) != {"id", "order"}:
            raise AcceptanceError("Help category entries must contain exactly id and order")
        if HELP_ID_PATTERN.fullmatch(str(category["id"])) is None:
            raise AcceptanceError(f"unsafe Help category id: {category['id']!r}")
        if not isinstance(category["order"], int) or category["id"] in category_ids:
            raise AcceptanceError(f"invalid or duplicate Help category: {category['id']!r}")
        category_ids.add(category["id"])
    ids: set[str] = set()
    expected_files = {
        help_config["index"],
        help_config["articleHashes"],
        *(
            help_config["searchIndexPattern"].format(locale=locale)
            for locale in EXPECTED_LOCALES
        ),
    }
    article_hashes: dict[str, dict[str, str]] = {}
    maximum = help_config["maximumArticleBytes"]
    for article in index["articles"]:
        if not isinstance(article, dict) or set(article) != {
            "id",
            "category",
            "order",
            "related",
            "locales",
        }:
            raise AcceptanceError("Help article entries have unexpected structure")
        identifier = article["id"]
        if not isinstance(identifier, str) or HELP_ID_PATTERN.fullmatch(identifier) is None:
            raise AcceptanceError(f"unsafe Help article id: {identifier!r}")
        if identifier in ids:
            raise AcceptanceError(f"duplicate Help article id: {identifier}")
        ids.add(identifier)
        if article["category"] not in category_ids or not isinstance(article["order"], int):
            raise AcceptanceError(f"invalid category/order for Help article: {identifier}")
        if not isinstance(article["related"], list) or not all(
            isinstance(item, str) for item in article["related"]
        ):
            raise AcceptanceError(f"invalid related list for Help article: {identifier}")
        if not isinstance(article["locales"], dict) or set(article["locales"]) != set(
            EXPECTED_LOCALES
        ):
            raise AcceptanceError(f"Help article lacks exact locale parity: {identifier}")
        article_hashes[identifier] = {}
        for locale in EXPECTED_LOCALES:
            metadata = article["locales"][locale]
            if not isinstance(metadata, dict) or set(metadata) != {"path", "title", "keywords"}:
                raise AcceptanceError(f"invalid Help metadata for {identifier}/{locale}")
            if not isinstance(metadata["title"], str) or not metadata["title"].strip():
                raise AcceptanceError(f"empty Help title for {identifier}/{locale}")
            if not isinstance(metadata["keywords"], list) or not all(
                isinstance(keyword, str) and keyword.strip() for keyword in metadata["keywords"]
            ):
                raise AcceptanceError(f"invalid Help keywords for {identifier}/{locale}")
            relative = relative_path(metadata["path"], f"Help path for {identifier}/{locale}")
            if not relative.parts or relative.parts[0] != locale:
                raise AcceptanceError(f"Help article path is outside its locale: {metadata['path']}")
            path = contained_path(help_root, metadata["path"], "Help article")
            raw, text = read_text_limited(path, maximum, "Help article")
            if not text.startswith(f"# {metadata['title']}"):
                raise AcceptanceError(f"Help heading/title mismatch: {metadata['path']}")
            for pattern in UNSAFE_HELP_PATTERNS:
                if pattern.search(text):
                    raise AcceptanceError(f"unsafe markup in Help article: {metadata['path']}")
            for destination in MARKDOWN_LINK_PATTERN.findall(text):
                if destination.startswith("help:"):
                    continue
                if destination.startswith("#"):
                    continue
                parsed = urlparse(destination)
                if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                    raise AcceptanceError(
                        f"Help article link is not a safe HTTPS/help link: {metadata['path']}: {destination}"
                    )
            expected_files.add(relative.as_posix())
            article_hashes[identifier][locale] = sha256_bytes(raw)
    for article in index["articles"]:
        for target in article["related"]:
            if target not in ids:
                raise AcceptanceError(f"broken related Help id: {article['id']} -> {target}")
        for locale in EXPECTED_LOCALES:
            path = contained_path(
                help_root,
                article["locales"][locale]["path"],
                "Help article",
            )
            text = path.read_text(encoding="utf-8")
            for target in INTERNAL_HELP_LINK_PATTERN.findall(text):
                if target not in ids:
                    raise AcceptanceError(f"broken inline Help id: {target} in {path}")
    expected_article_hash_bytes = help_json_bytes(
        {"schemaVersion": 1, "hashes": article_hashes}
    )
    article_hash_path = contained_path(
        help_root, help_config["articleHashes"], "Help article hashes"
    )
    require_regular_file(article_hash_path, "Help article hashes")
    if article_hash_path.read_bytes() != expected_article_hash_bytes:
        raise AcceptanceError(
            "Help article-hashes.json differs byte-for-byte from a temporary deterministic rebuild"
        )
    for locale in EXPECTED_LOCALES:
        expected_search = help_json_bytes(build_search_index(help_root, index, locale))
        relative = help_config["searchIndexPattern"].format(locale=locale)
        search_path = contained_path(help_root, relative, f"Help search index {locale}")
        require_regular_file(search_path, f"Help search index {locale}")
        if search_path.read_bytes() != expected_search:
            raise AcceptanceError(
                f"{relative} differs byte-for-byte from a temporary deterministic rebuild"
            )
    actual_files: set[str] = set()
    for path in help_root.rglob("*"):
        relative = path.relative_to(help_root).as_posix()
        if path.name.startswith("."):
            raise AcceptanceError(f"hidden build artifact is forbidden in Help resources: {relative}")
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise AcceptanceError(f"symlink is forbidden in Help resources: {relative}")
        if stat.S_ISREG(mode):
            actual_files.add(relative)
        elif not stat.S_ISDIR(mode):
            raise AcceptanceError(f"unsupported filesystem item in Help resources: {relative}")
    if actual_files != expected_files:
        raise AcceptanceError(
            "Help resource inventory differs from help-index.json: "
            f"missing={sorted(expected_files - actual_files)}, "
            f"unexpected={sorted(actual_files - expected_files)}"
        )
    return index


def unit_map(localization: dict, label: str) -> dict[tuple[str, ...], str]:
    result: dict[tuple[str, ...], str] = {}

    def visit(value: object, path: tuple[str, ...]) -> None:
        if isinstance(value, dict):
            if "stringUnit" in value:
                unit = value["stringUnit"]
                if not isinstance(unit, dict) or set(unit) != {"state", "value"}:
                    raise AcceptanceError(f"{label} has an invalid stringUnit")
                if unit["state"] != "translated":
                    raise AcceptanceError(f"{label} contains a non-translated stringUnit")
                if not isinstance(unit["value"], str) or not unit["value"].strip():
                    raise AcceptanceError(f"{label} contains an empty translation")
                result[path + ("stringUnit",)] = unit["value"]
            for key in sorted(value):
                if key != "stringUnit":
                    visit(value[key], path + (key,))
        elif isinstance(value, list):
            for index, item in enumerate(value):
                visit(item, path + (str(index),))

    visit(localization, ())
    if not result:
        raise AcceptanceError(f"{label} has no translated stringUnit")
    return result


def normalized_placeholders(value: str) -> Counter[str]:
    tokens: list[str] = []
    for token in PRINTF_PATTERN.findall(value.replace("%%", "")):
        tokens.append(re.sub(r"^%[1-9][0-9]*\$", "%", token))
    tokens.extend(BRACE_PATTERN.findall(value))
    return Counter(tokens)


def validate_catalogs(repository_root: Path, config: dict) -> dict[str, dict]:
    resources = resource_root(repository_root, config)
    result: dict[str, dict] = {}
    info_path = contained_path(repository_root, "Vela/Info.plist", "source Info.plist")
    require_regular_file(info_path, "source Info.plist")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    for item in sorted(config["catalogs"], key=lambda value: value["name"]):
        name = item["name"]
        path = contained_path(resources, item["path"], f"{name} string catalog")
        catalog = load_json(path, f"{name} string catalog")
        if set(catalog) != {"sourceLanguage", "strings", "version"}:
            raise AcceptanceError(f"{name}.xcstrings has unexpected top-level keys")
        if catalog["sourceLanguage"] != "en" or catalog["version"] != "1.0":
            raise AcceptanceError(f"{name}.xcstrings must use sourceLanguage en and version 1.0")
        strings = catalog["strings"]
        if not isinstance(strings, dict) or not strings:
            raise AcceptanceError(f"{name}.xcstrings must contain at least one string")
        for key, record in strings.items():
            if not isinstance(key, str) or not key:
                raise AcceptanceError(f"{name}.xcstrings contains an invalid key")
            if name != "InfoPlist" and STABLE_KEY_PATTERN.fullmatch(key) is None:
                raise AcceptanceError(f"{name}.xcstrings key is not stable/dotted: {key}")
            if not isinstance(record, dict) or set(record) != {"comment", "localizations"}:
                raise AcceptanceError(f"{name}.xcstrings record has unexpected structure: {key}")
            if not isinstance(record["comment"], str) or not record["comment"].strip():
                raise AcceptanceError(f"{name}.xcstrings key lacks a translator comment: {key}")
            localizations = record["localizations"]
            if not isinstance(localizations, dict) or set(localizations) != set(EXPECTED_LOCALES):
                raise AcceptanceError(f"{name}.xcstrings key lacks exact locale parity: {key}")
            units = {
                locale: unit_map(localizations[locale], f"{name}/{key}/{locale}")
                for locale in EXPECTED_LOCALES
            }
            if set(units["en"]) != set(units["zh-Hans"]):
                raise AcceptanceError(f"{name}.xcstrings variation parity differs for key: {key}")
            for unit_path in units["en"]:
                english = units["en"][unit_path]
                chinese = units["zh-Hans"][unit_path]
                if normalized_placeholders(english) != normalized_placeholders(chinese):
                    raise AcceptanceError(
                        f"{name}.xcstrings placeholder parity differs for key: {key}"
                    )
                for value in (english, chinese):
                    if any(pattern.search(value) for pattern in CONTENT_PLACEHOLDER_PATTERNS):
                        raise AcceptanceError(f"{name}.xcstrings contains placeholder copy: {key}")
            if name == "InfoPlist" and key not in info:
                raise AcceptanceError(
                    f"InfoPlist.xcstrings localizes a key absent from Vela/Info.plist: {key}"
                )
        result[name] = catalog
    return result


def validate_security_contact(config: dict, security_documents: Iterable[str]) -> None:
    contact = config["securityContact"]
    if not isinstance(contact, dict) or set(contact) != {"uri", "display"}:
        raise AcceptanceError(
            "securityContact is an intentional stop-ship until a real private contact is reviewed"
        )
    uri = contact["uri"]
    display = contact["display"]
    if not isinstance(uri, str) or not isinstance(display, str) or not display.strip():
        raise AcceptanceError("securityContact uri/display must be non-empty strings")
    parsed = urlparse(uri)
    if parsed.scheme != "mailto" or not parsed.path or parsed.query or parsed.fragment:
        raise AcceptanceError("securityContact uri must be a fixed mailto address")
    address = parsed.path
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[A-Za-z]{2,}", address):
        raise AcceptanceError("securityContact mailto address is malformed")
    domain = address.rsplit("@", 1)[1].lower()
    if domain.endswith((".invalid", ".example", ".test", ".localhost")) or domain in {
        "example.com",
        "example.net",
        "example.org",
    }:
        raise AcceptanceError("securityContact may not use an example/reserved domain")
    if "__" in uri or "placeholder" in uri.lower():
        raise AcceptanceError("securityContact contains a placeholder")
    for document in security_documents:
        if uri not in document and display not in document and address not in document:
            raise AcceptanceError(
                "both localized SECURITY.md files must publish the configured private contact"
            )


def validate_policies_root(policies_root: Path, config: dict) -> None:
    require_regular_directory(policies_root, "Policies resource directory")
    expected_files: set[str] = set()
    security_documents: list[str] = []
    problems: list[str] = []
    for locale in EXPECTED_LOCALES:
        locale_root = contained_path(policies_root, locale, f"Policies locale {locale}")
        require_regular_directory(locale_root, f"Policies locale {locale}")
        for name in EXPECTED_POLICY_FILES:
            relative = f"{locale}/{name}"
            expected_files.add(relative)
            path = contained_path(policies_root, relative, "policy document")
            _, text = read_text_limited(path, 256 * 1024, "policy document")
            if not text.startswith("# "):
                raise AcceptanceError(f"policy document lacks an H1 heading: {relative}")
            for pattern in CONTENT_PLACEHOLDER_PATTERNS:
                if pattern.search(text):
                    problems.append(f"policy document contains placeholder copy: {relative}")
                    break
            if name == "SECURITY.md":
                security_documents.append(text)
    actual_files: set[str] = set()
    for path in policies_root.rglob("*"):
        relative = path.relative_to(policies_root).as_posix()
        if path.name.startswith("."):
            problems.append(
                f"hidden build artifact is forbidden in Policies resources: {relative}"
            )
            continue
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise AcceptanceError(f"symlink is forbidden in Policies resources: {relative}")
        if stat.S_ISREG(mode):
            actual_files.add(relative)
        elif not stat.S_ISDIR(mode):
            raise AcceptanceError(f"unsupported filesystem item in Policies resources: {relative}")
    if actual_files != expected_files:
        problems.append(
            "Policies locale/file parity differs: "
            f"missing={sorted(expected_files - actual_files)}, "
            f"unexpected={sorted(actual_files - expected_files)}"
        )
    try:
        validate_security_contact(config, security_documents)
    except AcceptanceError as error:
        problems.append(str(error))
    if problems:
        raise AcceptanceError("; ".join(problems))


def validate_privacy_manifest(path: Path, config: dict) -> dict:
    require_regular_file(path, "PrivacyInfo.xcprivacy")
    if path.stat().st_size > 1024 * 1024:
        raise AcceptanceError("PrivacyInfo.xcprivacy exceeds 1 MiB")
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise AcceptanceError("PrivacyInfo.xcprivacy is not a valid property list") from error
    if not isinstance(value, dict) or set(value) != {
        "NSPrivacyAccessedAPITypes",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
    }:
        raise AcceptanceError("PrivacyInfo.xcprivacy has unexpected top-level structure")
    if type(value["NSPrivacyTracking"]) is not bool or value["NSPrivacyTracking"] is not False:
        raise AcceptanceError("NSPrivacyTracking must be the Boolean false")
    domains = value["NSPrivacyTrackingDomains"]
    if not isinstance(domains, list) or domains:
        raise AcceptanceError("tracking=false requires an empty NSPrivacyTrackingDomains array")
    collected = value["NSPrivacyCollectedDataTypes"]
    accessed = value["NSPrivacyAccessedAPITypes"]
    if not isinstance(collected, list) or not isinstance(accessed, list):
        raise AcceptanceError("Privacy manifest data/API declarations must be arrays")
    for entry in collected:
        if not isinstance(entry, dict) or set(entry) != {
            "NSPrivacyCollectedDataType",
            "NSPrivacyCollectedDataTypeLinked",
            "NSPrivacyCollectedDataTypePurposes",
            "NSPrivacyCollectedDataTypeTracking",
        }:
            raise AcceptanceError("Privacy collected-data entry has unexpected structure")
        if not isinstance(entry["NSPrivacyCollectedDataType"], str) or not entry[
            "NSPrivacyCollectedDataType"
        ].startswith("NSPrivacyCollectedDataType"):
            raise AcceptanceError("Privacy collected-data type is malformed")
        if type(entry["NSPrivacyCollectedDataTypeLinked"]) is not bool or type(
            entry["NSPrivacyCollectedDataTypeTracking"]
        ) is not bool:
            raise AcceptanceError("Privacy collected-data flags must be Booleans")
        purposes = entry["NSPrivacyCollectedDataTypePurposes"]
        if not isinstance(purposes, list) or not purposes or not all(
            isinstance(item, str) and item.startswith("NSPrivacyCollectedDataTypePurpose")
            for item in purposes
        ):
            raise AcceptanceError("Privacy collected-data purposes are malformed")
    seen_api_types: set[str] = set()
    for entry in accessed:
        if not isinstance(entry, dict) or set(entry) != {
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
        }:
            raise AcceptanceError("Privacy accessed-API entry has unexpected structure")
        api_type = entry["NSPrivacyAccessedAPIType"]
        reasons = entry["NSPrivacyAccessedAPITypeReasons"]
        if not isinstance(api_type, str) or not api_type.startswith("NSPrivacyAccessedAPICategory"):
            raise AcceptanceError("Privacy accessed-API category is malformed")
        if api_type in seen_api_types:
            raise AcceptanceError(f"duplicate Privacy accessed-API category: {api_type}")
        seen_api_types.add(api_type)
        if not isinstance(reasons, list) or not reasons or not all(
            isinstance(reason, str) and re.fullmatch(r"[A-Z0-9]{2,8}\.[0-9]+", reason)
            for reason in reasons
        ):
            raise AcceptanceError(f"Privacy reason codes are malformed for {api_type}")
    serialized = plistlib.dumps(value, fmt=plistlib.FMT_XML).decode("utf-8")
    if any(pattern.search(serialized) for pattern in CONTENT_PLACEHOLDER_PATTERNS):
        raise AcceptanceError("PrivacyInfo.xcprivacy contains placeholder content")
    review = config["privacyReview"]
    pending_reviews = [
        name
        for name in ("requiredReasonAPIsReviewed", "trackingAndDataReviewed")
        if review[name] is not True
    ]
    if pending_reviews:
        raise AcceptanceError(
            "privacy review is an intentional stop-ship until audited: "
            + ", ".join(pending_reviews)
        )
    if not isinstance(review["reviewedBy"], str) or not review["reviewedBy"].strip():
        raise AcceptanceError("privacy review requires a non-empty reviewedBy value")
    reviewed_at = review["reviewedAt"]
    if not isinstance(reviewed_at, str) or re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", reviewed_at
    ) is None:
        raise AcceptanceError("privacy review requires a UTC reviewedAt timestamp")
    return value


def validate_project(repository_root: Path, version: str, build: int) -> None:
    project_path = contained_path(
        repository_root, "Vela.xcodeproj/project.pbxproj", "Xcode project"
    )
    require_regular_file(project_path, "Xcode project")
    text = project_path.read_text(encoding="utf-8")
    region_match = re.search(r"knownRegions\s*=\s*\((.*?)\);", text, flags=re.DOTALL)
    if region_match is None:
        raise AcceptanceError("Xcode project lacks knownRegions")
    regions = {
        token.strip().strip('"')
        for token in region_match.group(1).split(",")
        if token.strip()
    }
    if not set(EXPECTED_LOCALES).issubset(regions) or "Base" not in regions:
        raise AcceptanceError("Xcode knownRegions must contain en, zh-Hans, and Base")
    versions = re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", text)
    builds = re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*([^;]+);", text)
    if not versions or {item.strip().strip('"') for item in versions} != {version}:
        raise AcceptanceError(f"all Xcode target marketing versions must be {version}")
    if not builds or {item.strip().strip('"') for item in builds} != {str(build)}:
        raise AcceptanceError(f"all Xcode target build numbers must be {build}")
    for marker in [
        "PBXFileSystemSynchronizedRootGroup",
        "path = Vela;",
        "/* Resources */",
    ]:
        if marker not in text:
            raise AcceptanceError(f"Xcode resource membership contract lacks: {marker}")


def documentation_manifest(
    repository_root: Path,
    config: dict,
    app_version: str,
    app_build: int,
    epoch: int,
) -> dict:
    if SEMVER_PATTERN.fullmatch(app_version) is None:
        raise AcceptanceError("app version must be major.minor.patch")
    if BUILD_PATTERN.fullmatch(str(app_build)) is None:
        raise AcceptanceError("app build must use YYYYMMDDNN")
    resources = resource_root(repository_root, config)
    help_root = contained_path(resources, config["help"]["root"], "Help root")
    policies_root = contained_path(resources, config["policies"]["root"], "Policies root")
    index = load_json(
        contained_path(help_root, config["help"]["index"], "Help index"),
        "Help index",
    )
    catalogs = []
    for item in sorted(config["catalogs"], key=lambda value: value["name"]):
        path = contained_path(resources, item["path"], f"{item['name']} catalog")
        catalog = load_json(path, f"{item['name']} catalog")
        strings = catalog.get("strings")
        if not isinstance(strings, dict):
            raise AcceptanceError(f"{item['name']} catalog has no strings object")
        catalogs.append(
            {
                "name": item["name"],
                "path": item["path"],
                "keyCount": len(strings),
                "sha256": sha256_file(path),
            }
        )
    articles = []
    for article in index.get("articles", []):
        locales = {}
        for locale in EXPECTED_LOCALES:
            metadata = article["locales"][locale]
            path = contained_path(help_root, metadata["path"], "Help article")
            locales[locale] = {
                "path": f"{config['help']['root']}/{metadata['path']}",
                "sha256": sha256_file(path),
            }
        articles.append({"id": article["id"], "locales": locales})
    policies = []
    for locale in EXPECTED_LOCALES:
        for name in EXPECTED_POLICY_FILES:
            relative = f"{locale}/{name}"
            path = contained_path(policies_root, relative, "policy document")
            policies.append(
                {
                    "locale": locale,
                    "name": name,
                    "path": f"{config['policies']['root']}/{relative}",
                    "sha256": sha256_file(path),
                }
            )
    help_files = []
    for relative in [
        config["help"]["index"],
        config["help"]["articleHashes"],
        *(
            config["help"]["searchIndexPattern"].format(locale=locale)
            for locale in EXPECTED_LOCALES
        ),
    ]:
        path = contained_path(help_root, relative, "Help metadata")
        help_files.append(
            {
                "path": f"{config['help']['root']}/{relative}",
                "sha256": sha256_file(path),
            }
        )
    privacy_path = contained_path(
        resources, config["privacyManifest"], "Privacy manifest"
    )
    manifest = {
        "schemaVersion": 1,
        "appVersion": app_version,
        "appBuild": app_build,
        "generatedAt": generated_at(epoch),
        "locales": EXPECTED_LOCALES,
        "catalogs": catalogs,
        "help": {"files": help_files},
        "articles": articles,
        "policies": policies,
        "privacyManifest": {
            "path": config["privacyManifest"],
            "sha256": sha256_file(privacy_path),
        },
    }
    for value in walk_strings(manifest):
        if value.startswith("/") or re.match(r"^[A-Za-z]:[\\/]", value):
            raise AcceptanceError("documentation manifest may not contain absolute paths")
    return manifest


def walk_strings(value: object) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)


def validate_manifest_bytes(
    path: Path,
    repository_root: Path,
    config: dict,
    app_version: str,
    app_build: int,
    epoch: int,
) -> dict:
    require_regular_file(path, "VelaDocumentationManifest.json")
    if path.stat().st_size > 2 * 1024 * 1024:
        raise AcceptanceError("VelaDocumentationManifest.json exceeds 2 MiB")
    expected = documentation_manifest(repository_root, config, app_version, app_build, epoch)
    expected_bytes = canonical_json_bytes(expected)
    if path.read_bytes() != expected_bytes:
        raise AcceptanceError(
            "VelaDocumentationManifest.json differs byte-for-byte from its deterministic rebuild"
        )
    loaded = load_json(path, "VelaDocumentationManifest.json")
    if loaded != expected:
        raise AcceptanceError("VelaDocumentationManifest.json semantic content drifted")
    return loaded


def collect_checks(checks: Iterable[tuple[str, Callable[[], None]]]) -> list[str]:
    failures: list[str] = []
    for label, check in checks:
        try:
            check()
        except (AcceptanceError, OSError, KeyError, TypeError, ValueError) as error:
            failures.append(f"{label}: {error}")
    return failures


def validate_source(
    repository_root: Path,
    config: dict,
    app_version: str,
    app_build: int,
    *,
    require_epoch_environment: bool = True,
) -> list[str]:
    epoch_holder: dict[str, int] = {}

    def check_epoch() -> None:
        epoch_holder["value"] = configured_epoch(
            config, require_environment=require_epoch_environment
        )

    def epoch() -> int:
        if "value" not in epoch_holder:
            epoch_holder["value"] = configured_epoch(
                config, require_environment=require_epoch_environment
            )
        return epoch_holder["value"]

    resources = resource_root(repository_root, config)
    help_root = contained_path(resources, config["help"]["root"], "Help root")
    policies_root = contained_path(resources, config["policies"]["root"], "Policies root")
    privacy_path = contained_path(
        resources, config["privacyManifest"], "Privacy manifest"
    )
    manifest_path = contained_path(
        resources, config["documentationManifest"], "documentation manifest"
    )
    checks: list[tuple[str, Callable[[], None]]] = [
        ("SOURCE_DATE_EPOCH", check_epoch),
        (
            "version/config",
            lambda: validate_requested_version(config, app_version, app_build),
        ),
        ("Xcode project", lambda: validate_project(repository_root, app_version, app_build)),
        ("string catalogs", lambda: validate_catalogs(repository_root, config)),
        ("Help", lambda: validate_help_root(help_root, config)),
        ("Policies", lambda: validate_policies_root(policies_root, config)),
        ("PrivacyInfo", lambda: validate_privacy_manifest(privacy_path, config)),
        (
            "documentation manifest",
            lambda: validate_manifest_bytes(
                manifest_path,
                repository_root,
                config,
                app_version,
                app_build,
                epoch(),
            ),
        ),
    ]
    return collect_checks(checks)


def validate_requested_version(config: dict, app_version: str, app_build: int) -> None:
    if app_version != config["appVersion"]:
        raise AcceptanceError(
            f"requested version {app_version} differs from documentation config {config['appVersion']}"
        )
    if app_build != config["appBuild"]:
        raise AcceptanceError(
            f"requested build {app_build} differs from documentation config {config['appBuild']}"
        )


def parse_strings_file(path: Path) -> dict:
    require_regular_file(path, "compiled localization table")
    raw = path.read_bytes()
    try:
        value = plistlib.loads(raw)
        if isinstance(value, dict):
            return value
    except (plistlib.InvalidFileException, ExpatError, ValueError):
        pass
    text: str | None = None
    for encoding in ("utf-8-sig", "utf-16"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        raise AcceptanceError(f"compiled localization table has unknown encoding: {path}")
    if text.lstrip().startswith("<?xml"):
        normalized_xml = re.sub(
            r'(<\?xml[^>]*\bencoding=)["\'][^"\']+["\']',
            r'\1"UTF-8"',
            text,
            count=1,
            flags=re.IGNORECASE,
        )
        try:
            value = plistlib.loads(normalized_xml.encode("utf-8"))
        except (plistlib.InvalidFileException, ExpatError, ValueError) as error:
            raise AcceptanceError(f"compiled XML localization table is invalid: {path}") from error
        if not isinstance(value, dict):
            raise AcceptanceError(f"compiled localization table is not a dictionary: {path}")
        return value
    without_comments = re.sub(r"/\*.*?\*/|//[^\n]*", " ", text, flags=re.DOTALL)
    result = {}
    entry_pattern = re.compile(
        r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;'
    )
    for match in entry_pattern.finditer(without_comments):
        key = json.loads(f'"{match.group(1)}"')
        value = json.loads(f'"{match.group(2)}"')
        result[key] = value
    if not result and without_comments.strip():
        raise AcceptanceError(f"compiled localization table could not be parsed: {path}")
    return result


def validate_compiled_localizations(
    resources: Path, catalogs: dict[str, dict], config: dict
) -> None:
    for locale in EXPECTED_LOCALES:
        locale_root = contained_path(resources, f"{locale}.lproj", f"{locale} lproj")
        require_regular_directory(locale_root, f"{locale} lproj")
        for item in config["catalogs"]:
            name = item["name"]
            table_path = contained_path(locale_root, f"{name}.strings", f"{name} strings")
            values = parse_strings_file(table_path)
            expected_keys = set(catalogs[name]["strings"])
            if set(values) != expected_keys:
                raise AcceptanceError(
                    f"compiled {locale}/{name}.strings key parity differs: "
                    f"missing={sorted(expected_keys - set(values))}, "
                    f"unexpected={sorted(set(values) - expected_keys)}"
                )


def validate_embedded_hashes(resources: Path, manifest: dict) -> None:
    entries: list[dict] = []
    entries.extend(manifest["help"]["files"])
    for article in manifest["articles"]:
        entries.extend(article["locales"].values())
    entries.extend(manifest["policies"])
    entries.append(manifest["privacyManifest"])
    for entry in entries:
        path_value = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(path_value, str) or SHA256_PATTERN.fullmatch(str(digest)) is None:
            raise AcceptanceError("documentation manifest contains an invalid hash entry")
        path = contained_path(resources, path_value, "embedded documentation resource")
        if sha256_file(path) != digest:
            raise AcceptanceError(f"embedded documentation hash mismatch: {path_value}")


def validate_archive(
    repository_root: Path,
    config: dict,
    app_path: Path,
    app_version: str,
    app_build: int,
) -> list[str]:
    failures: list[str] = []
    try:
        require_regular_directory(app_path, "Vela.app")
        if app_path.suffix != ".app":
            raise AcceptanceError("archive mode requires a .app bundle")
        try:
            app_path.resolve(strict=True).relative_to(repository_root.resolve(strict=True))
        except ValueError:
            # Release staging commonly lives under the repository, but callers may
            # validate a copied App elsewhere. The bundle itself remains symlink-safe.
            pass
        for path in app_path.rglob("*"):
            if stat.S_ISLNK(path.lstat().st_mode):
                relative = path.relative_to(app_path).as_posix()
                if relative.startswith("Contents/Resources/Help/") or relative.startswith(
                    "Contents/Resources/Policies/"
                ) or relative in {
                    "Contents/Resources/PrivacyInfo.xcprivacy",
                    "Contents/Resources/VelaDocumentationManifest.json",
                }:
                    raise AcceptanceError(f"documentation archive resource is a symlink: {relative}")
    except (AcceptanceError, OSError) as error:
        return [f"App bundle: {error}"]

    resources = contained_path(app_path, config["archive"]["resourcesPath"], "App Resources")
    info_path = contained_path(app_path, "Contents/Info.plist", "App Info.plist")
    epoch = configured_epoch(config, require_environment=False)
    manifest_path = contained_path(
        resources, config["documentationManifest"], "embedded documentation manifest"
    )
    help_root = contained_path(resources, config["help"]["root"], "embedded Help")
    policies_root = contained_path(
        resources, config["policies"]["root"], "embedded Policies"
    )
    privacy_path = contained_path(
        resources, config["privacyManifest"], "embedded PrivacyInfo"
    )
    manifest_holder: dict[str, dict] = {}
    catalogs_holder: dict[str, dict] = {}

    def check_info() -> None:
        require_regular_file(info_path, "App Info.plist")
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        if str(info.get("CFBundleShortVersionString")) != app_version:
            raise AcceptanceError("archive CFBundleShortVersionString differs from release request")
        if str(info.get("CFBundleVersion")) != str(app_build):
            raise AcceptanceError("archive CFBundleVersion differs from release request")
        if info.get("CFBundleIdentifier") != "dev.yilin.Vela":
            raise AcceptanceError("archive bundle identifier is not dev.yilin.Vela")
        if str(info.get("LSMinimumSystemVersion")) != "15.0":
            raise AcceptanceError("archive minimum macOS is not 15.0")

    def check_catalogs() -> None:
        catalogs_holder.update(validate_catalogs(repository_root, config))

    def check_manifest() -> None:
        manifest_holder["value"] = validate_manifest_bytes(
            manifest_path,
            repository_root,
            config,
            app_version,
            app_build,
            epoch,
        )

    def check_hashes() -> None:
        manifest = manifest_holder.get("value")
        if manifest is None:
            return
        validate_embedded_hashes(resources, manifest)

    def check_compiled() -> None:
        catalogs = catalogs_holder or validate_catalogs(repository_root, config)
        validate_compiled_localizations(resources, catalogs, config)

    checks: list[tuple[str, Callable[[], None]]] = [
        ("version/config", lambda: validate_requested_version(config, app_version, app_build)),
        ("App Info.plist", check_info),
        ("source catalogs", check_catalogs),
        ("embedded Help", lambda: validate_help_root(help_root, config)),
        ("embedded Policies", lambda: validate_policies_root(policies_root, config)),
        ("embedded PrivacyInfo", lambda: validate_privacy_manifest(privacy_path, config)),
        ("embedded documentation manifest", check_manifest),
        ("embedded documentation hashes", check_hashes),
        ("compiled localization tables", check_compiled),
    ]
    failures.extend(collect_checks(checks))
    return failures


def atomic_write(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise AcceptanceError(f"refusing unsafe documentation manifest output: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def create_self_test_fixture(root: Path) -> tuple[dict, Path]:
    resources = root / "Vela/Resources"
    help_root = resources / "Help"
    policies_root = resources / "Policies"
    localization = resources / "Localization"
    for path in [help_root / "en", help_root / "zh-Hans", localization]:
        path.mkdir(parents=True, exist_ok=True)
    version = "0.7.0"
    build = 2026071401
    contact = "security@spacebody.dev"
    index = {
        "schemaVersion": 1,
        "contentSchemaVersion": 1,
        "sourceLanguage": "en",
        "supportedLocales": EXPECTED_LOCALES,
        "categories": [{"id": "getting-started", "order": 10}],
        "articles": [
            {
                "id": "getting-started",
                "category": "getting-started",
                "order": 10,
                "related": [],
                "locales": {
                    "en": {
                        "path": "en/getting-started.md",
                        "title": "Getting Started",
                        "keywords": ["start"],
                    },
                    "zh-Hans": {
                        "path": "zh-Hans/getting-started.md",
                        "title": "开始使用",
                        "keywords": ["开始"],
                    },
                },
            }
        ],
    }
    (help_root / "help-index.json").write_bytes(help_json_bytes(index))
    (help_root / "en/getting-started.md").write_text(
        "# Getting Started\n\nUse Vela Help.\n", encoding="utf-8"
    )
    (help_root / "zh-Hans/getting-started.md").write_text(
        "# 开始使用\n\n使用 Vela 帮助。\n", encoding="utf-8"
    )
    hashes = {
        "getting-started": {
            locale: sha256_file(help_root / index["articles"][0]["locales"][locale]["path"])
            for locale in EXPECTED_LOCALES
        }
    }
    (help_root / "article-hashes.json").write_bytes(
        help_json_bytes({"schemaVersion": 1, "hashes": hashes})
    )
    for locale in EXPECTED_LOCALES:
        (help_root / f"search-index-{locale}.json").write_bytes(
            help_json_bytes(build_search_index(help_root, index, locale))
        )
    for locale in EXPECTED_LOCALES:
        locale_root = policies_root / locale
        locale_root.mkdir(parents=True, exist_ok=True)
        for name in EXPECTED_POLICY_FILES:
            title = name.removesuffix(".md").title()
            body = f"# Vela {title}\n\nReviewed Vela policy.\n"
            if name == "SECURITY.md":
                body += f"\nReport privately to {contact}.\n"
            (locale_root / name).write_text(body, encoding="utf-8")
    info = {
        "CFBundleIdentifier": "dev.yilin.Vela",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(build),
        "LSMinimumSystemVersion": "15.0",
        "NSLocationUsageDescription": "Location usage",
    }
    (root / "Vela").mkdir(parents=True, exist_ok=True)
    with (root / "Vela/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    catalog_keys = {
        "Localizable": "app.help.open",
        "Errors": "error.help.unavailable",
        "InfoPlist": "NSLocationUsageDescription",
    }
    for name, key in catalog_keys.items():
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                key: {
                    "comment": "Self-test translator context.",
                    "localizations": {
                        "en": {
                            "stringUnit": {"state": "translated", "value": f"{name} value"}
                        },
                        "zh-Hans": {
                            "stringUnit": {"state": "translated", "value": f"{name} 值"}
                        },
                    },
                }
            },
            "version": "1.0",
        }
        (localization / f"{name}.xcstrings").write_bytes(canonical_json_bytes(catalog))
    privacy = {
        "NSPrivacyAccessedAPITypes": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
    }
    with (resources / "PrivacyInfo.xcprivacy").open("wb") as handle:
        plistlib.dump(privacy, handle)
    project = root / "Vela.xcodeproj/project.pbxproj"
    project.parent.mkdir(parents=True, exist_ok=True)
    project.write_text(
        """PBXFileSystemSynchronizedRootGroup path = Vela;
/* Resources */
knownRegions = (en, Base, \"zh-Hans\", );
MARKETING_VERSION = 0.7.0;
MARKETING_VERSION = 0.7.0;
CURRENT_PROJECT_VERSION = 2026071401;
CURRENT_PROJECT_VERSION = 2026071401;
""",
        encoding="utf-8",
    )
    config = {
        "schemaVersion": 1,
        "appVersion": version,
        "appBuild": build,
        "sourceDateEpoch": 1783987200,
        "locales": EXPECTED_LOCALES,
        "resourceRoot": "Vela/Resources",
        "catalogs": [
            {"name": "Localizable", "path": "Localization/Localizable.xcstrings"},
            {"name": "Errors", "path": "Localization/Errors.xcstrings"},
            {"name": "InfoPlist", "path": "Localization/InfoPlist.xcstrings"},
        ],
        "help": {
            "root": "Help",
            "index": "help-index.json",
            "articleHashes": "article-hashes.json",
            "searchIndexPattern": "search-index-{locale}.json",
            "maximumArticleBytes": 262144,
        },
        "policies": {"root": "Policies", "files": EXPECTED_POLICY_FILES},
        "privacyManifest": "PrivacyInfo.xcprivacy",
        "documentationManifest": "VelaDocumentationManifest.json",
        "securityContact": {"uri": f"mailto:{contact}", "display": contact},
        "privacyReview": {
            "requiredReasonAPIsReviewed": True,
            "trackingAndDataReviewed": True,
            "reviewedBy": "release-self-test",
            "reviewedAt": "2026-07-14T00:00:00Z",
        },
        "archive": {"resourcesPath": "Contents/Resources"},
    }
    config_path = root / "Release/config/documentation.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_bytes(canonical_json_bytes(config))
    manifest = documentation_manifest(root, config, version, build, config["sourceDateEpoch"])
    (resources / "VelaDocumentationManifest.json").write_bytes(canonical_json_bytes(manifest))
    app = root / "fixture/Vela.app"
    app_resources = app / "Contents/Resources"
    app_resources.mkdir(parents=True, exist_ok=True)
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    shutil.copytree(help_root, app_resources / "Help")
    shutil.copytree(policies_root, app_resources / "Policies")
    shutil.copy2(resources / "PrivacyInfo.xcprivacy", app_resources / "PrivacyInfo.xcprivacy")
    shutil.copy2(
        resources / "VelaDocumentationManifest.json",
        app_resources / "VelaDocumentationManifest.json",
    )
    for locale in EXPECTED_LOCALES:
        locale_root = app_resources / f"{locale}.lproj"
        locale_root.mkdir()
        for name, key in catalog_keys.items():
            with (locale_root / f"{name}.strings").open("wb") as handle:
                plistlib.dump({key: f"{name}-{locale}"}, handle, fmt=plistlib.FMT_BINARY)
    return config, app


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="vela-v07-acceptance.") as temporary:
        root = Path(temporary)
        config, app = create_self_test_fixture(root)
        previous_epoch = os.environ.get("SOURCE_DATE_EPOCH")
        os.environ["SOURCE_DATE_EPOCH"] = str(config["sourceDateEpoch"])
        try:
            failures = validate_source(root, config, config["appVersion"], config["appBuild"])
            if failures:
                raise AcceptanceError(f"positive source fixture failed: {failures}")
            failures = validate_archive(
                root, config, app, config["appVersion"], config["appBuild"]
            )
            if failures:
                raise AcceptanceError(f"positive archive fixture failed: {failures}")

            search = root / "Vela/Resources/Help/search-index-en.json"
            original_search = search.read_bytes()
            search.write_bytes(original_search + b" ")
            failures = validate_source(root, config, config["appVersion"], config["appBuild"])
            if not any("temporary deterministic rebuild" in failure for failure in failures):
                raise AcceptanceError("search-index byte-drift fixture was unexpectedly accepted")
            search.write_bytes(original_search)

            policy = root / "Vela/Resources/Policies/en/SUPPORT.md"
            original_policy = policy.read_text(encoding="utf-8")
            policy.write_text(original_policy + "\nTODO\n", encoding="utf-8")
            failures = validate_source(root, config, config["appVersion"], config["appBuild"])
            if not any("placeholder copy" in failure for failure in failures):
                raise AcceptanceError("policy placeholder fixture was unexpectedly accepted")
            policy.write_text(original_policy, encoding="utf-8")

            original_contact = config["securityContact"]
            config["securityContact"] = None
            failures = validate_source(root, config, config["appVersion"], config["appBuild"])
            if not any("securityContact is an intentional stop-ship" in failure for failure in failures):
                raise AcceptanceError("missing security-contact fixture was unexpectedly accepted")
            config["securityContact"] = original_contact

            archived_article = app / "Contents/Resources/Help/en/getting-started.md"
            archived_article.write_text("# Getting Started\n\nTampered.\n", encoding="utf-8")
            failures = validate_archive(
                root, config, app, config["appVersion"], config["appBuild"]
            )
            if not any("hash mismatch" in failure for failure in failures):
                raise AcceptanceError("archive hash-drift fixture was unexpectedly accepted")
        finally:
            if previous_epoch is None:
                os.environ.pop("SOURCE_DATE_EPOCH", None)
            else:
                os.environ["SOURCE_DATE_EPOCH"] = previous_epoch
