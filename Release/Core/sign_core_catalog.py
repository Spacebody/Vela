#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from core_release_lib import (
    CoreReleaseError,
    atomic_write,
    canonical_json_bytes,
    read_regular_bytes,
    sha256_bytes,
    validate_catalog,
    validate_signature_envelope,
)


def validate_secret_file(path: Path, repository_root: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise CoreReleaseError("Core Catalog private key must be an explicit regular non-symlink file")
    canonical = path.resolve(strict=True)
    if stat.S_IMODE(canonical.stat().st_mode) != 0o600:
        raise CoreReleaseError("Core Catalog private key file permissions must be exactly 0600")
    if canonical.stat().st_uid != os.getuid():
        raise CoreReleaseError("Core Catalog private key file must be owned by the release user")
    try:
        canonical.relative_to(repository_root.resolve(strict=True))
    except ValueError:
        pass
    else:
        raise CoreReleaseError("Core Catalog private key may not live in the source checkout")
    temporary = False
    for raw_root in [os.environ.get("RUNNER_TEMP"), os.environ.get("TMPDIR", "/tmp"), "/tmp"]:
        if not raw_root:
            continue
        root = Path(raw_root)
        if not root.is_dir() or root.is_symlink():
            continue
        try:
            canonical.relative_to(root.resolve(strict=True))
            temporary = True
        except ValueError:
            pass
    if not temporary:
        raise CoreReleaseError("Core Catalog private key file must live under RUNNER_TEMP or TMPDIR")
    if canonical.stat().st_size > 4096:
        raise CoreReleaseError("Core Catalog private key file is unexpectedly large")
    return canonical


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="Sign exact raw Core Catalog bytes with an independent Ed25519 key")
    parser.add_argument("catalog")
    parser.add_argument("--key-id", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--private-key-file")
    source.add_argument("--keychain-service")
    parser.add_argument("--keychain-account")
    parser.add_argument("--keychain")
    parser.add_argument("--existing-envelope")
    parser.add_argument("--output", required=True)
    parser.add_argument("--repository-root", default=str(default_root))
    parser.add_argument("--allow-test-key", action="store_true")
    args = parser.parse_args()
    temporary_directory: tempfile.TemporaryDirectory[str] | None = None
    crypto_cache = tempfile.TemporaryDirectory(prefix="vela-core-swift-cache.")
    os.chmod(crypto_cache.name, 0o700)
    try:
        if not args.key_id or len(args.key_id) > 128:
            raise CoreReleaseError("Core Catalog key ID is invalid")
        if "TEST" in args.key_id.upper() and not args.allow_test_key:
            raise CoreReleaseError("test Core Catalog key is forbidden outside explicit fixture mode")
        repository_root = Path(args.repository_root)
        catalog_path = Path(args.catalog)
        catalog_raw = read_regular_bytes(catalog_path, maximum=2 * 1024 * 1024)
        validate_catalog(catalog_raw)
        if args.private_key_file:
            key_path = validate_secret_file(Path(args.private_key_file), repository_root)
        else:
            if not args.keychain_account or not args.keychain:
                raise CoreReleaseError("Keychain signing requires --keychain-service, --keychain-account, and --keychain")
            keychain = Path(args.keychain)
            if not keychain.is_file() or keychain.is_symlink() or stat.S_IMODE(keychain.stat().st_mode) != 0o600:
                raise CoreReleaseError("Core signing Keychain must be an explicit 0600 non-symlink file")
            temporary_directory = tempfile.TemporaryDirectory(prefix="vela-core-sign.")
            os.chmod(temporary_directory.name, 0o700)
            key_path = Path(temporary_directory.name) / "catalog-ed25519.key"
            descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                result = subprocess.run(
                    [
                        "/usr/bin/security", "find-generic-password", "-w",
                        "-s", args.keychain_service, "-a", args.keychain_account, str(keychain),
                    ],
                    stdout=descriptor,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            finally:
                os.close(descriptor)
            if result.returncode != 0 or key_path.stat().st_size == 0:
                raise CoreReleaseError("protected Keychain entry for the Core Catalog key is unavailable")
            key_path = validate_secret_file(key_path, repository_root)
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, signature_name = tempfile.mkstemp(prefix=".core-signature.", dir=output_path.parent)
        os.close(descriptor)
        signature_path = Path(signature_name)
        signature_path.unlink()
        try:
            helper = Path(__file__).with_name("catalog_crypto.swift")
            result = subprocess.run(
                ["/usr/bin/swift", "-module-cache-path", crypto_cache.name, str(helper), "sign", str(catalog_path), str(key_path), str(signature_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=False,
                text=True,
            )
            if result.returncode != 0:
                raise CoreReleaseError("Core Catalog Ed25519 signing failed")
            signature = base64.b64encode(read_regular_bytes(signature_path, maximum=64)).decode("ascii")
        finally:
            signature_path.unlink(missing_ok=True)
        signatures: list[dict[str, str]] = []
        if args.existing_envelope:
            envelope_raw = read_regular_bytes(Path(args.existing_envelope), maximum=64 * 1024)
            envelope = validate_signature_envelope(envelope_raw, catalog_raw, production=not args.allow_test_key)
            signatures = list(envelope["signatures"])
        if any(item["keyID"] == args.key_id for item in signatures):
            raise CoreReleaseError("Core Catalog envelope already contains this key ID")
        signatures.append({"keyID": args.key_id, "algorithm": "ed25519", "signature": signature})
        signatures.sort(key=lambda item: item["keyID"])
        envelope = {"schemaVersion": 1, "catalogSHA256": sha256_bytes(catalog_raw), "signatures": signatures}
        raw = canonical_json_bytes(envelope)
        validate_signature_envelope(raw, catalog_raw, production=not args.allow_test_key)
        atomic_write(output_path, raw)
        print(f"Signed Core Catalog: keyID={args.key_id} catalogSHA256={envelope['catalogSHA256']} output={output_path}")
        return 0
    except (OSError, CoreReleaseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary_directory is not None:
            temporary_directory.cleanup()
        crypto_cache.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
