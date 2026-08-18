#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlparse


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}
SIGNATURE_ATTRIBUTE = f"{{{SPARKLE_NS}}}edSignature"
LENGTH_ATTRIBUTE = f"{{{SPARKLE_NS}}}length"


class VerificationError(ValueError):
    pass


def regular_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        raise VerificationError(f"{label} must be a regular non-symlink file")
    return path.resolve()


def unique_artifact(root: Path, url: str, label: str) -> Path:
    name = Path(unquote(urlparse(url).path)).name
    if not name or name in {".", ".."}:
        raise VerificationError(f"{label} URL has no safe artifact basename")
    # Compare names literally. Path.rglob(name) would interpret URL-controlled
    # glob metacharacters such as brackets or asterisks.
    candidates = [
        path
        for path in root.rglob("*")
        if path.name == name and path.is_file() and not path.is_symlink()
    ]
    if len(candidates) != 1:
        raise VerificationError(
            f"{label} must resolve to exactly one local artifact, found {len(candidates)}"
        )
    candidate = candidates[0].resolve()
    if root != candidate and root not in candidate.parents:
        raise VerificationError(f"{label} resolves outside the artifact directory")
    return candidate


def signature(node: ET.Element, label: str) -> str:
    value = node.attrib.get(SIGNATURE_ATTRIBUTE)
    if value is None:
        raise VerificationError(f"{label} is missing an EdDSA signature")
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as error:
        raise VerificationError(f"{label} signature is not canonical Base64") from error
    if len(decoded) != 64 or decoded == bytes(64):
        raise VerificationError(f"{label} signature is not a production Ed25519 signature")
    return value


def expected_length(node: ET.Element, attribute: str, label: str) -> int:
    raw = node.attrib.get(attribute)
    if raw is None or not raw.isascii() or not raw.isdecimal() or raw.startswith("0"):
        raise VerificationError(f"{label} length must be a positive canonical integer")
    value = int(raw)
    if value <= 0:
        raise VerificationError(f"{label} length must be positive")
    return value


def verify_signature(
    sign_update: Path,
    key_file: Path,
    artifact: Path,
    artifact_signature: str,
    label: str,
) -> None:
    result = subprocess.run(
        [
            str(sign_update),
            "--verify",
            "--ed-key-file",
            str(key_file),
            str(artifact),
            artifact_signature,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        raise VerificationError(f"{label} failed Sparkle Ed25519 verification")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Cryptographically verify every artifact referenced by a signed Sparkle feed"
    )
    parser.add_argument("appcast")
    parser.add_argument("--artifacts-dir", required=True)
    parser.add_argument("--sign-update", required=True)
    parser.add_argument("--ed-key-file", required=True)
    args = parser.parse_args()

    try:
        appcast = regular_file(Path(args.appcast), "appcast")
        sign_update = regular_file(Path(args.sign_update), "Sparkle sign_update")
        key_file = regular_file(Path(args.ed_key_file), "Sparkle Ed25519 key")
        root = Path(args.artifacts_dir)
        if not root.is_dir() or root.is_symlink():
            raise VerificationError("artifact directory must be a regular non-symlink directory")
        for path in root.rglob("*"):
            if path.is_symlink():
                raise VerificationError(f"artifact directory contains a symlink: {path}")
        root = root.resolve()

        raw = appcast.read_bytes()
        lowered = raw.lower()
        if b"<!doctype" in lowered or b"<!entity" in lowered:
            raise VerificationError("DOCTYPE and ENTITY declarations are forbidden")
        try:
            document = ET.fromstring(raw)
        except ET.ParseError as error:
            raise VerificationError(f"invalid appcast XML: {error}") from error
        channel = document.find("channel") if document.tag == "rss" else None
        if channel is None:
            raise VerificationError("appcast is missing its RSS channel")
        items = channel.findall("item")
        if not items:
            raise VerificationError("appcast has no update items")

        verified = 0
        for item in items:
            version = item.findtext("sparkle:version", default="", namespaces=NS).strip()
            if not version.isascii() or not version.isdecimal() or version.startswith("0"):
                raise VerificationError("appcast item has an invalid build")
            nodes = (
                (
                    item.find("sparkle:releaseNotesLink", NS),
                    LENGTH_ATTRIBUTE,
                    f"build {version} release notes",
                ),
                (item.find("enclosure"), "length", f"build {version} enclosure"),
            )
            for node, length_attribute, label in nodes:
                if node is None:
                    raise VerificationError(f"{label} is missing")
                artifact_url = node.text if node.text is not None else node.attrib.get("url", "")
                artifact = unique_artifact(root, artifact_url, label)
                length = expected_length(node, length_attribute, label)
                if artifact.stat().st_size != length:
                    raise VerificationError(f"{label} length differs from the signed feed")
                verify_signature(
                    sign_update,
                    key_file,
                    artifact,
                    signature(node, label),
                    label,
                )
                verified += 1

        print(f"Verified {verified} Sparkle artifact signature(s) from {len(items)} feed item(s).")
        return 0
    except (OSError, subprocess.SubprocessError, UnicodeError, VerificationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
