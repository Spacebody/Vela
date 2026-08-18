#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlparse


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}
SIGNATURE_ATTRIBUTE = f"{{{SPARKLE_NS}}}edSignature"
LENGTH_ATTRIBUTE = f"{{{SPARKLE_NS}}}length"


class PolicyError(ValueError):
    pass


def load_policy(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise PolicyError(f"expected a regular policy file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise PolicyError("appcast policy must be a schemaVersion 1 object")
    return value


def valid_signature(raw: str | None, *, fixture: bool, label: str) -> None:
    if raw is None:
        raise PolicyError(f"{label} is missing an EdDSA signature")
    try:
        decoded = base64.b64decode(raw, validate=True)
    except ValueError as error:
        raise PolicyError(f"{label} signature is not valid base64") from error
    if len(decoded) != 64:
        raise PolicyError(f"{label} signature must decode to 64 bytes")
    if not fixture and decoded == bytes(64):
        raise PolicyError(f"{label} uses the all-zero fixture signature")


def positive_length(raw: str | None, label: str) -> int:
    if raw is None or re.fullmatch(r"[1-9][0-9]*", raw) is None:
        raise PolicyError(f"{label} length must be a positive integer")
    return int(raw)


def validate_https(raw: str, *, fixture: bool, label: str) -> str:
    value = raw.strip()
    parsed = urlparse(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise PolicyError(f"{label} must be fixed HTTPS without credentials/query/fragment: {value}")
    if not fixture and ("__" in value or parsed.hostname.endswith(".invalid") or parsed.hostname in {"example.com", "updates.example.com"}):
        raise PolicyError(f"{label} contains a placeholder host: {value}")
    return value


def find_local_artifact(root: Path, url: str) -> Path:
    name = Path(unquote(urlparse(url).path)).name
    candidates = [path for path in root.rglob(name) if path.is_file() and not path.is_symlink()]
    if len(candidates) != 1:
        raise PolicyError(f"expected exactly one local artifact for {name}, found {len(candidates)}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Vela signed appcast policy")
    parser.add_argument("appcast")
    parser.add_argument("--policy", default="Release/config/appcast-policy.json")
    parser.add_argument("--artifacts-dir")
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-release-notes")
    parser.add_argument("--fixture", action="store_true")
    args = parser.parse_args()

    try:
        policy = load_policy(Path(args.policy))
        path = Path(args.appcast)
        if not path.is_file() or path.is_symlink():
            raise PolicyError(f"expected a regular appcast file: {path}")
        raw = path.read_bytes()
        maximum = policy.get("maximumFeedBytes")
        if not isinstance(maximum, int) or maximum <= 0:
            raise PolicyError("maximumFeedBytes must be a positive integer")
        if len(raw) > maximum:
            raise PolicyError(f"appcast exceeds maximumFeedBytes ({len(raw)} > {maximum})")
        lowered = raw.lower()
        if b"<!doctype" in lowered or b"<!entity" in lowered:
            raise PolicyError("DOCTYPE and ENTITY declarations are forbidden")
        try:
            root = ET.fromstring(raw)
        except ET.ParseError as error:
            raise PolicyError(f"invalid appcast XML: {error}") from error
        if root.tag != "rss":
            raise PolicyError("appcast root must be rss")
        channel = root.find("channel")
        if channel is None:
            raise PolicyError("appcast is missing channel")
        channel_link = channel.findtext("link")
        if channel_link:
            validate_https(channel_link, fixture=args.fixture, label="channel link")

        items = channel.findall("item")
        if not items:
            raise PolicyError("appcast has no update items")
        builds: set[int] = set()
        stable_builds: list[int] = []
        beta_builds: list[int] = []
        stable_releases: list[tuple[str, int]] = []
        beta_releases: list[tuple[str, int]] = []
        artifacts_root = Path(args.artifacts_dir).resolve() if args.artifacts_dir else None
        if bool(args.expected_build) != bool(args.expected_release_notes):
            raise PolicyError(
                "--expected-build and --expected-release-notes must be provided together"
            )
        expected_notes = None
        expected_build = None
        expected_build_seen = False
        if args.expected_build:
            if re.fullmatch(r"[1-9][0-9]*", args.expected_build) is None:
                raise PolicyError("--expected-build must be a positive numeric CFBundleVersion")
            expected_build = int(args.expected_build)
            expected_notes = Path(args.expected_release_notes)
            if not expected_notes.is_file() or expected_notes.is_symlink():
                raise PolicyError("expected release notes must be a regular non-symlink file")
        if not args.fixture and artifacts_root is None:
            raise PolicyError("production appcast validation requires --artifacts-dir")

        for item in items:
            version_node = item.find("sparkle:version", NS)
            short_node = item.find("sparkle:shortVersionString", NS)
            minimum_node = item.find("sparkle:minimumSystemVersion", NS)
            hardware_node = item.find("sparkle:hardwareRequirements", NS)
            channel_node = item.find("sparkle:channel", NS)
            notes_node = item.find("sparkle:releaseNotesLink", NS)
            enclosure = item.find("enclosure")
            required_nodes = {
                "sparkle:version": version_node,
                "sparkle:shortVersionString": short_node,
                "sparkle:minimumSystemVersion": minimum_node,
                "sparkle:hardwareRequirements": hardware_node,
                "sparkle:releaseNotesLink": notes_node,
                "enclosure": enclosure,
            }
            missing = [name for name, node in required_nodes.items() if node is None]
            if missing:
                raise PolicyError(f"appcast item is missing {missing}")
            assert version_node is not None and short_node is not None
            assert minimum_node is not None and hardware_node is not None
            assert notes_node is not None and enclosure is not None

            version_text = (version_node.text or "").strip()
            if re.fullmatch(r"[1-9][0-9]*", version_text) is None:
                raise PolicyError(f"invalid numeric build: {version_text!r}")
            build = int(version_text)
            if build in builds:
                raise PolicyError(f"duplicate appcast build: {build}")
            builds.add(build)
            short_version = (short_node.text or "").strip()
            if not short_version:
                raise PolicyError(f"build {build} has an empty short version")
            base_version_match = re.match(r"^(\d+\.\d+\.\d+)(?:\s|$)", short_version)
            if base_version_match is None:
                raise PolicyError(f"build {build} short version must begin with major.minor.patch")
            base_version = base_version_match.group(1)
            if (minimum_node.text or "").strip() != policy.get("minimumMacOS"):
                raise PolicyError(f"build {build} has the wrong minimum macOS")
            if (hardware_node.text or "").strip() != policy.get("hardware"):
                raise PolicyError(f"build {build} has the wrong hardware requirement")

            if channel_node is None:
                stable_builds.append(build)
                stable_releases.append((base_version, build))
            elif (channel_node.text or "").strip() == "beta":
                beta_builds.append(build)
                beta_releases.append((base_version, build))
            else:
                raise PolicyError(f"build {build} uses an unsupported channel")

            notes_url = validate_https(notes_node.text or "", fixture=args.fixture, label=f"build {build} release notes")
            notes_signature = notes_node.attrib.get(SIGNATURE_ATTRIBUTE)
            notes_length = positive_length(notes_node.attrib.get(LENGTH_ATTRIBUTE), f"build {build} release notes")
            if policy.get("signedReleaseNotesRequired") is True:
                valid_signature(notes_signature, fixture=args.fixture, label=f"build {build} release notes")
            if expected_build is not None and build == expected_build:
                assert expected_notes is not None
                expected_build_seen = True
                if Path(unquote(urlparse(notes_url).path)).name != expected_notes.name:
                    raise PolicyError(
                        f"build {build} release-notes URL does not name the published signed notes"
                    )
                if expected_notes.stat().st_size != notes_length:
                    raise PolicyError(
                        f"build {build} published signed release-notes length does not match"
                    )

            enclosure_url = validate_https(enclosure.attrib.get("url", ""), fixture=args.fixture, label=f"build {build} enclosure")
            enclosure_length = positive_length(enclosure.attrib.get("length"), f"build {build} enclosure")
            valid_signature(enclosure.attrib.get(SIGNATURE_ATTRIBUTE), fixture=args.fixture, label=f"build {build} enclosure")
            if enclosure.attrib.get("type") != "application/octet-stream":
                raise PolicyError(f"build {build} enclosure type must be application/octet-stream")
            if enclosure_url.endswith(".delta") or item.find("sparkle:deltas", NS) is not None:
                raise PolicyError("delta updates are disabled for V0.5")

            if artifacts_root is not None:
                notes_file = find_local_artifact(artifacts_root, notes_url)
                enclosure_file = find_local_artifact(artifacts_root, enclosure_url)
                if notes_file.stat().st_size != notes_length:
                    raise PolicyError(f"build {build} release-notes length does not match local artifact")
                if enclosure_file.stat().st_size != enclosure_length:
                    raise PolicyError(f"build {build} enclosure length does not match local artifact")

        if not stable_builds or not beta_builds:
            raise PolicyError("single feed must contain at least one Stable and one Beta item")
        if expected_build is not None and not expected_build_seen:
            raise PolicyError(f"expected build {expected_build} is absent from the appcast")
        if policy.get("stableMustSupersedeBeta") is True:
            for beta_version, beta_build in beta_releases:
                matching_stable = [
                    stable_build
                    for stable_version, stable_build in stable_releases
                    if stable_version == beta_version
                ]
                if matching_stable and max(matching_stable) <= beta_build:
                    raise PolicyError(
                        f"Stable {beta_version} build must be greater than its Beta build"
                    )

        signature_match = re.search(
            rb"<!--\s*sparkle-signatures:\s*edSignature:\s*([^\s]+)\s*length:\s*([0-9]+)\s*-->\s*$",
            raw,
            re.DOTALL,
        )
        if policy.get("signedFeedRequired") is True:
            if signature_match is None:
                raise PolicyError("appcast is missing Sparkle's trailing signed-feed block")
            feed_signature = signature_match.group(1).decode("ascii")
            valid_signature(feed_signature, fixture=args.fixture, label="signed appcast")
            feed_length = positive_length(signature_match.group(2).decode("ascii"), "signed appcast")
            if not args.fixture and feed_length != signature_match.start():
                raise PolicyError(
                    f"signed appcast length does not match signed prefix ({feed_length} != {signature_match.start()})"
                )

        print(
            f"Appcast policy passed: {len(stable_builds)} Stable, "
            f"{len(beta_builds)} Beta, {len(items)} total"
        )
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, PolicyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
