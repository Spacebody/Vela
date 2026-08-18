#!/usr/bin/env python3
"""Generate an immutable, release-bound external-audit packet."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any


class AuditPacketError(RuntimeError):
    pass


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise AuditPacketError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def regular(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise AuditPacketError(f"{label} must be a regular non-symlink file: {path}")


def sha256(path: Path) -> str:
    regular(path, "hash input")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict[str, Any]:
    regular(path, "JSON input")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AuditPacketError(f"{path} must contain an object")
    return value


def copy_regular(source: Path, destination: Path) -> None:
    regular(source, "packet source")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=False)


def preflight_tree(root: Path) -> None:
    if not root.is_dir() or root.is_symlink():
        raise AuditPacketError(f"packet source tree must be a non-symlink directory: {root}")
    for path in root.rglob("*"):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise AuditPacketError(f"packet source tree contains a symlink: {path}")
        if not stat.S_ISDIR(info.st_mode) and not stat.S_ISREG(info.st_mode):
            raise AuditPacketError(f"packet source tree contains a special file: {path}")
        if stat.S_ISREG(info.st_mode) and info.st_size > 20 * 1024 * 1024:
            raise AuditPacketError(f"packet source file is unexpectedly large: {path}")


def inventory_payload(root: Path, large_artifact: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    total = 0
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise AuditPacketError(f"generated packet contains a symlink: {path}")
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode):
            raise AuditPacketError(f"generated packet contains a special file: {path}")
        relative = str(path.relative_to(root))
        if relative == "packet-inventory.json":
            continue
        if info.st_size > 20 * 1024 * 1024 and path != large_artifact:
            raise AuditPacketError(f"unexpected oversized packet file: {relative}")
        total += info.st_size
        entries.append({"path": relative, "size": info.st_size, "sha256": sha256(path)})
    if total > 2 * 1024 * 1024 * 1024:
        raise AuditPacketError("audit packet exceeds the 2 GiB bounded payload limit")
    return entries


def validate_release_inputs(
    manifest: dict[str, Any], sbom: dict[str, Any], artifact: Path,
    version: str, build: int, commit: str, tag: str, architecture_sha256: str,
) -> None:
    app = manifest.get("app", {})
    source = manifest.get("source", {})
    if manifest.get("manifestKind") != "external" or manifest.get("schemaVersion") != 1:
        raise AuditPacketError("release manifest is not an external v1 manifest")
    if app.get("version") != version or app.get("build") != build:
        raise AuditPacketError("release manifest version/build mismatch")
    if source.get("commit") != commit or source.get("tag") != tag:
        raise AuditPacketError("release manifest commit/tag mismatch")
    if source.get("architectureFreezeSHA256") != architecture_sha256:
        raise AuditPacketError("release manifest architecture-freeze SHA mismatch")
    if manifest.get("build", {}).get("sourceDirty") is not False:
        raise AuditPacketError("release manifest reports dirty source")
    dmg = manifest.get("artifacts", {}).get("dmg", {})
    if dmg.get("filename") != artifact.name or dmg.get("sha256") != sha256(artifact):
        raise AuditPacketError("artifact does not match release manifest DMG")
    if sbom.get("spdxVersion") != "SPDX-2.3":
        raise AuditPacketError("SBOM is not SPDX 2.3 JSON")
    packages = sbom.get("packages", [])
    if not any(item.get("name") == "Vela" and item.get("versionInfo") == version for item in packages if isinstance(item, dict)):
        raise AuditPacketError("SBOM does not describe the scoped Vela version")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--release-manifest", required=True)
    parser.add_argument("--sbom", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(args.repository_root).resolve()
    artifact = Path(args.artifact).resolve()
    release_manifest_path = Path(args.release_manifest).resolve()
    sbom_path = Path(args.sbom).resolve()
    output = Path(args.output).resolve()
    output_created = False
    try:
        if git(repo, "status", "--porcelain"):
            raise AuditPacketError("refusing audit packet generation from dirty source")
        commit = git(repo, "rev-parse", "HEAD")
        exact_tag = git(repo, "describe", "--tags", "--exact-match", "HEAD", check=False)
        if exact_tag != args.tag:
            raise AuditPacketError("--tag is not the exact tag at HEAD")
        if git(repo, "cat-file", "-t", f"refs/tags/{args.tag}", check=False) != "tag":
            raise AuditPacketError("audit packet requires an annotated signed tag")
        verify = subprocess.run(["git", "verify-tag", args.tag], cwd=repo, capture_output=True)
        if verify.returncode != 0:
            raise AuditPacketError("audit packet tag signature verification failed")
        for path, label in (
            (artifact, "artifact"),
            (release_manifest_path, "release manifest"),
            (sbom_path, "SBOM"),
        ):
            regular(path, label)
        release_manifest = load(release_manifest_path)
        sbom = load(sbom_path)
        validate_release_inputs(
            release_manifest, sbom, artifact, args.version, args.build, commit, args.tag,
            sha256(repo / "Hardening/config/architecture-freeze.json"),
        )
        architecture_check = subprocess.run(
            [sys.executable, str(repo / "Hardening/scripts/validate_architecture_freeze.py"), "--repository-root", str(repo)],
            text=True, capture_output=True,
        )
        if architecture_check.returncode != 0:
            raise AuditPacketError(architecture_check.stderr.strip() or "architecture validation failed")
        if output.exists() or output.is_symlink():
            raise AuditPacketError(f"refusing to overwrite {output}")
        output.mkdir(parents=True, mode=0o750)
        output_created = True

        preflight_tree(repo / "Hardening/AuditPacket")
        preflight_tree(repo / "Hardening/schemas")
        # Preserve any source symlink instead of following it. Preflight and the
        # final inventory both reject symlinks, closing copy-time exfiltration.
        shutil.copytree(
            repo / "Hardening/AuditPacket", output, dirs_exist_ok=True, symlinks=True
        )
        shutil.copytree(
            repo / "Hardening/schemas", output / "schemas", dirs_exist_ok=True,
            symlinks=True,
        )
        for name in (
            "architecture-freeze.json", "attack-surface.json", "beta-policy.json",
            "stop-ship-policy.json", "release-readiness.json", "migration-matrix.json",
            "performance-budgets.json",
        ):
            copy_regular(repo / "Hardening/config" / name, output / "inventory" / name)

        protocol_files = (
            "VelaIPC/VelaHelperProtocol.swift", "VelaIPC/VelaIPCConstants.swift",
            "VelaIPC/HelperDTOs.swift", "VelaIPC/CoreLifecycleDTOs.swift",
            "VelaIPC/HelperPayloadCodec.swift", "VelaIPC/TunSettings.swift",
            "Configuration/Privileged/dev.yilin.Vela.Helper.plist",
        )
        for relative in protocol_files:
            copy_regular(repo / relative, output / "protocols/source" / relative)
        security_docs = (
            "Docs/Vela-v0.3-Privileged-TUN-Codex-Pack/03-SECURITY-THREAT-MODEL.md",
            "Docs/Vela-v0.3-Privileged-TUN-Codex-Pack/18-SECURITY-TEST-PLAN.md",
            "Docs/Vela-v0.5-Secure-Updates-Release-Codex-Pack/04-UPDATE-SECURITY-POLICY.md",
            "Docs/Vela-v0.5-Secure-Updates-Release-Codex-Pack/19-SECURITY-TEST-PLAN.md",
            "Docs/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/03-THREAT-MODEL.md",
            "Docs/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/19-SECURITY-TEST-PLAN.md",
            "Docs/Vela-v0.7-Localization-Onboarding-Support-Codex-Pack/22-SECURITY-TEST-PLAN.md",
            "Docs/Vela-v0.8-Public-Beta-Hardening-Codex-Pack/24-SECURITY-TEST-PLAN.md",
        )
        for relative in security_docs:
            docs_relative = Path(relative).relative_to("Docs")
            copy_regular(repo / relative, output / "security-tests/plans" / docs_relative)
        copy_regular(release_manifest_path, output / "release/release-manifest.json")
        copy_regular(sbom_path, output / "release/sbom.spdx.json")
        copy_regular(artifact, output / "release" / artifact.name)

        scope = {
            "schemaVersion": 1,
            "commit": commit,
            "tag": args.tag,
            "version": args.version,
            "build": args.build,
            "sourceDirty": False,
            "tagSignatureVerified": True,
            "artifact": {"filename": artifact.name, "sha256": sha256(artifact), "size": artifact.stat().st_size},
            "releaseManifestSHA256": sha256(release_manifest_path),
            "sbomSHA256": sha256(sbom_path),
            "architectureFreezeSHA256": sha256(repo / "Hardening/config/architecture-freeze.json"),
            "githubAttestationIncluded": False,
            "githubAttestationNote": "Include only verified output from the protected GitHub artifact-producing workflow; never fabricate it for an offline release.",
        }
        (output / "scope.json").write_text(json.dumps(scope, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(output / "scope.json", 0o640)

        secret_pattern = re.compile(
            rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|"
            rb"Authorization:\s*(?:Bearer|Basic)\s+\S+|"
            rb"\b(?:gh[oprsu]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b|"
            rb"(?:password|access[_ -]?token|controller[_ -]?secret)\s*[:=]\s*[^\s,;}]+",
            re.I,
        )
        copied_artifact = output / "release" / artifact.name
        entries = inventory_payload(output, copied_artifact)
        for entry in entries:
            path = output / entry["path"]
            if path == copied_artifact or path.suffix.lower() not in {
                ".json", ".md", ".txt", ".swift", ".plist", ".yaml", ".yml"
            }:
                continue
            if secret_pattern.search(path.read_bytes()):
                raise AuditPacketError(f"generated packet contains secret material: {path}")
        inventory = {
            "schemaVersion": 1,
            "scope": "Every regular payload file except packet-inventory.json itself",
            "entryCount": len(entries),
            "entries": entries,
        }
        inventory_path = output / "packet-inventory.json"
        inventory_path.write_text(
            json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.chmod(inventory_path, 0o640)
    except (OSError, KeyError, ValueError, json.JSONDecodeError, AuditPacketError) as error:
        if output_created and output.exists() and output.is_dir():
            shutil.rmtree(output)
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
