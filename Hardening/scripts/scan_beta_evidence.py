#!/usr/bin/env python3
"""Fail closed when an exportable evidence tree may contain user data.

This is an independent gate, not a redactor. Export code must first use the
V0.7 Support redactor. Only bounded UTF-8 summaries are accepted here; traces,
archives, images, xcresult bundles, and other opaque formats stay private.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit


MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_FILES = 1000
TEXT_SUFFIXES = {".json", ".jsonl", ".txt", ".log", ".csv", ".tsv", ".md"}
PATTERNS = {
    "authorization": re.compile(rb"authorization\s*:\s*(?:bearer|basic)\s+\S+", re.I),
    "token-query": re.compile(rb"[?&](?:token|key|secret|auth|password)=[^&\s]+", re.I),
    "private-key": re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", re.I),
    "secret-assignment": re.compile(
        rb"(?:controller[-_ ]?secret|password|private[-_ ]?key|access[-_ ]?token)\s*[:=]\s*[^\s,;}]+",
        re.I,
    ),
    "ssid": re.compile(rb"\b(?:SSID|BSSID)\s*[:=]\s*[^\r\n]+", re.I),
    "user-home": re.compile(rb"/Users/(?!<redacted>/|__USER__/|synthetic/)[^/\s]+/"),
    "credential-url": re.compile(rb"https?://[^/@\s]+:[^/@\s]+@", re.I),
}
URL_RE = re.compile(rb"https?://[^\s\"'<>\\]+", re.I)
IPV4_RE = re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")
IPV6_TOKEN_RE = re.compile(rb"(?<![0-9A-Fa-f:])[0-9A-Fa-f:]{2,}(?![0-9A-Fa-f:])")
DOMAIN_RE = re.compile(rb"(?<![A-Za-z0-9-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(?![A-Za-z0-9-])")


def normalize_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def files(root: Path) -> Iterable[Path]:
    if root.is_symlink():
        raise ValueError(f"symlink evidence root is forbidden: {root}")
    if root.is_file():
        yield root
        return
    if not root.is_dir():
        raise ValueError(f"evidence path is not a regular file or directory: {root}")
    count = 0
    for directory, names, filenames in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in names:
            candidate = base / name
            if candidate.is_symlink():
                raise ValueError(f"symlink directory is forbidden: {candidate}")
        for name in filenames:
            candidate = base / name
            if candidate.is_symlink():
                raise ValueError(f"symlink file is forbidden: {candidate}")
            count += 1
            if count > MAX_FILES:
                raise ValueError(f"evidence contains more than {MAX_FILES} files")
            yield candidate


def read_regular(path: Path, maximum: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"non-regular evidence file is forbidden: {path}")
        if info.st_size > maximum:
            raise ValueError(f"evidence file exceeds {maximum} bytes: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            raw = handle.read(maximum + 1)
        if len(raw) > maximum:
            raise ValueError(f"evidence file grew beyond {maximum} bytes: {path}")
        after = os.fstat(descriptor)
        if (info.st_dev, info.st_ino, info.st_size) != (after.st_dev, after.st_ino, after.st_size):
            raise ValueError(f"evidence file changed during scan: {path}")
        return raw
    finally:
        os.close(descriptor)


def json_findings(value: Any, forbidden: set[str], path: str = "$") -> tuple[list[str], int]:
    findings: list[str] = []
    event_count = 0
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            normalized = normalize_key(str(key))
            if normalized in forbidden:
                findings.append(f"forbidden-field:{child_path}")
            if normalized == "events" and isinstance(child, list):
                event_count += len(child)
            child_findings, child_events = json_findings(child, forbidden, child_path)
            findings.extend(child_findings)
            event_count += child_events
    elif isinstance(value, list):
        for index, child in enumerate(value):
            child_findings, child_events = json_findings(child, forbidden, f"{path}[{index}]")
            findings.extend(child_findings)
            event_count += child_events
    elif isinstance(value, str):
        findings.extend(content_findings(value.encode("utf-8"), allow_synthetic_urls=False, detect_domains=False))
    return findings, event_count


def address_allowed(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if address.is_loopback:
        return True
    allowed_networks = (
        ipaddress.ip_network("192.0.2.0/24"),
        ipaddress.ip_network("198.51.100.0/24"),
        ipaddress.ip_network("203.0.113.0/24"),
        ipaddress.ip_network("2001:db8::/32"),
    )
    return any(address in network for network in allowed_networks)


def ip_findings(raw: bytes) -> list[str]:
    findings: list[str] = []
    candidates = [item.decode("ascii") for item in IPV4_RE.findall(raw)]
    candidates.extend(
        item.decode("ascii") for item in IPV6_TOKEN_RE.findall(raw) if b":" in item
    )
    for candidate in candidates:
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if not address_allowed(address):
            findings.append("raw-ip-address")
            break
    return findings


def url_findings(raw: bytes, allow_synthetic_urls: bool) -> list[str]:
    findings: list[str] = []
    for match in URL_RE.findall(raw):
        text = match.decode("utf-8", errors="replace").rstrip(".,);]")
        parsed = urlsplit(text)
        host = (parsed.hostname or "").lower().rstrip(".")
        synthetic = host == "invalid" or host.endswith(".invalid")
        if (
            parsed.scheme.lower() not in {"http", "https"}
            or not host
            or parsed.username is not None
            or parsed.password is not None
            or not allow_synthetic_urls
            or not synthetic
        ):
            findings.append("raw-url")
            break
    return findings


def domain_findings(raw: bytes) -> list[str]:
    for match in DOMAIN_RE.findall(raw):
        domain = match.decode("ascii").lower().rstrip(".")
        if domain != "localhost" and domain != "invalid" and not domain.endswith(".invalid"):
            return ["raw-hostname"]
    return []


def content_findings(raw: bytes, allow_synthetic_urls: bool, detect_domains: bool) -> list[str]:
    findings = [name for name, pattern in PATTERNS.items() if pattern.search(raw)]
    findings.extend(url_findings(raw, allow_synthetic_urls))
    findings.extend(ip_findings(raw))
    if detect_domains:
        findings.extend(domain_findings(raw))
    return findings


def scan(path: Path, raw: bytes, forbidden: set[str], allow_synthetic_urls: bool) -> tuple[list[str], int]:
    suffix = path.suffix.lower()
    if suffix not in TEXT_SUFFIXES:
        return ["unsupported-evidence-format"], 0
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return ["non-utf8-evidence"], 0
    findings = content_findings(raw, allow_synthetic_urls, detect_domains=suffix != ".json")
    events = 0
    if suffix == ".json":
        try:
            value = json.loads(raw, parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            findings.append("invalid-json-evidence")
        else:
            json_results, events = json_findings(value, forbidden)
            # Re-evaluate decoded strings using the requested synthetic-URL policy.
            if allow_synthetic_urls:
                json_results = [item for item in json_results if item != "raw-url"]
                decoded = json.dumps(value, ensure_ascii=False).encode("utf-8")
                json_results.extend(url_findings(decoded, True))
            findings.extend(json_results)
    return sorted(set(findings)), events


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--policy", default="Hardening/config/evidence-policy.json")
    parser.add_argument("--allow-synthetic-urls", action="store_true")
    args = parser.parse_args()
    try:
        policy = json.loads(Path(args.policy).read_text(encoding="utf-8"))
        if policy.get("localOnly") is not True or policy.get("automaticUpload") is not False:
            raise ValueError("evidence policy does not fail closed")
        forbidden = {normalize_key(key) for key in policy["forbiddenFields"]}
        maximum_total = min(int(policy["export"]["maximumBytes"]), MAX_FILE_BYTES)
        maximum_events = int(policy["export"]["maximumEvents"])
        findings: list[tuple[Path, str]] = []
        total = 0
        events = 0
        for path in files(Path(args.path)):
            raw = read_regular(path, MAX_FILE_BYTES)
            total += len(raw)
            if total > maximum_total:
                findings.append((path, "export-total-size-limit"))
                break
            categories, file_events = scan(path, raw, forbidden, args.allow_synthetic_urls)
            events += file_events
            findings.extend((path, category) for category in categories)
        if events > maximum_events:
            findings.append((Path(args.path), "export-event-count-limit"))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    for path, category in findings:
        print(f"{path}: {category}", file=sys.stderr)
    if findings:
        print(f"Evidence privacy scan failed with {len(findings)} finding(s).", file=sys.stderr)
        return 1
    print(f"Beta evidence privacy scan passed ({total} bytes, {events} event records).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
