#!/usr/bin/env python3
"""Generate Vela's architecture freeze from the production source tree.

The generator intentionally does not infer unimplemented V0.4 fixture features.  A
missing CLI, Automation Socket, App Intent, or Scene Store remains represented as
``null``/``absent``.  The output contains categories and path templates only; it
never reads runtime user data, Keychain values, or release credentials.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


GENERATOR_VERSION = 1


class ManifestError(RuntimeError):
    pass


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ManifestError(f"cannot read {path}: {error}") from error


def json_file(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(read(path))
    except json.JSONDecodeError as error:
        raise ManifestError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"expected JSON object in {path}")
    return value


def one_match(pattern: str, text: str, label: str, flags: int = 0) -> str:
    matches = re.findall(pattern, text, flags)
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise ManifestError(f"expected one {label}, found {unique!r}")
    return unique[0]


def swift_int(name: str, text: str) -> int:
    return int(one_match(rf"\b{name}\s*=\s*(\d+)\b", text, name))


def swift_string(name: str, text: str) -> str:
    return one_match(rf'\b{name}\s*=\s*"([^"]+)"', text, name)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_versions(repo: Path) -> list[dict[str, str]]:
    resolved = json_file(
        repo
        / "Vela.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    )
    results: list[dict[str, str]] = []
    for pin in resolved.get("pins", []):
        if not isinstance(pin, dict) or not isinstance(pin.get("state"), dict):
            raise ManifestError("malformed SwiftPM pin")
        state = pin["state"]
        results.append(
            {
                "identity": str(pin.get("identity")),
                "version": str(state.get("version")),
                "revision": str(state.get("revision")),
            }
        )
    return sorted(results, key=lambda item: item["identity"])


def helper_methods(protocol_source: str) -> list[str]:
    body = one_match(
        r"@objc\s+public\s+protocol\s+VelaHelperProtocol\s*\{(.*?)\n\}",
        protocol_source,
        "VelaHelperProtocol body",
        re.S,
    )
    methods = re.findall(r"^\s*func\s+([A-Za-z][A-Za-z0-9_]*)\s*\(", body, re.M)
    if len(methods) != len(set(methods)) or not methods:
        raise ManifestError("Helper RPC methods are empty or duplicated")
    return methods


def schema_versions(repo: Path, constants: str) -> dict[str, int | None]:
    compatibility = json_file(repo / "Release/config/compatibility.json")
    schemas = compatibility.get("schemas")
    if not isinstance(schemas, dict):
        raise ManifestError("Release compatibility schemas are missing")
    # Values below are checked against their source declarations instead of
    # copied from the V0.8 pack's aspirational fixture.
    checks = {
        "rootData": swift_int("rootDataSchemaVersion", constants),
        "coreData": swift_int("coreDataSchemaVersion", constants),
        "xpcPayload": swift_int("schemaVersion", constants),
        "profile": int(schemas["profile"]),
        "configurationLayer": int(schemas["configuration"]),
        "scene": schemas.get("scene"),
        "updateJournal": int(schemas["updateJournal"]),
    }
    source_checks = [
        (
            repo / "Vela/Core/Configuration/Profile.swift",
            "ProfileDatabaseEnvelope.currentSchemaVersion",
            r"struct\s+ProfileDatabaseEnvelope.*?currentSchemaVersion\s*=\s*(\d+)",
            checks["profile"],
        ),
        (
            repo / "Vela/Core/ConfigurationWorkbench/ConfigurationModels.swift",
            "ConfigurationLayer.currentSchemaVersion",
            r"struct\s+ConfigurationLayer\b.*?currentSchemaVersion\s*=\s*(\d+)",
            checks["configurationLayer"],
        ),
        (
            repo / "Vela/Core/Updates/UpdateJournal.swift",
            "UpdateJournal.currentSchemaVersion",
            r"struct\s+UpdateJournal\b.*?currentSchemaVersion\s*=\s*(\d+)",
            checks["updateJournal"],
        ),
    ]
    for path, label, pattern, expected in source_checks:
        actual = int(one_match(pattern, read(path), label, re.S))
        if actual != expected:
            raise ManifestError(f"{label}={actual} disagrees with compatibility={expected}")

    checks.update(
        {
            "rootStartTransaction": int(
                one_match(
                    r"struct\s+RootTransactionRecord\b.*?currentSchemaVersion\s*=\s*(\d+)",
                    read(repo / "VelaIPC/Sources/VelaPrivilegedCore/RootTransactionStore.swift"),
                    "RootTransactionRecord.currentSchemaVersion",
                    re.S,
                )
            ),
            "rootCoreStore": int(
                one_match(
                    r"struct\s+RootCoreStoreState\b.*?currentSchemaVersion\s*=\s*(\d+)",
                    read(repo / "VelaIPC/Sources/VelaPrivilegedCore/RootCoreStore.swift"),
                    "RootCoreStoreState.currentSchemaVersion",
                    re.S,
                )
            ),
            "rootCoreInstallTransaction": int(
                one_match(
                    r"struct\s+RootCoreInstallTransaction\b.*?currentSchemaVersion\s*=\s*(\d+)",
                    read(repo / "VelaIPC/Sources/VelaPrivilegedCore/RootCoreStore.swift"),
                    "RootCoreInstallTransaction.currentSchemaVersion",
                    re.S,
                )
            ),
            "userCoreStore": int(
                one_match(
                    r"struct\s+CoreStoreState\b.*?supportedSchemaVersion\s*=\s*(\d+)",
                    read(repo / "Vela/Core/CoreLifecycle/CoreStoreModels.swift"),
                    "CoreStoreState.supportedSchemaVersion",
                    re.S,
                )
            ),
            "onboarding": int(
                one_match(
                    r"struct\s+OnboardingProgress\b.*?currentSchemaVersion\s*=\s*(\d+)",
                    read(repo / "Vela/Core/Onboarding/OnboardingModels.swift"),
                    "OnboardingProgress.currentSchemaVersion",
                    re.S,
                )
            ),
            "help": 1,
            "supportBundle": 1,
            "releaseManifest": 1,
        }
    )
    return checks


def core_trust_roots(source: str) -> tuple[int, list[str]]:
    version = swift_int("version", source)
    empty = re.search(
        r"public\s+static\s+let\s+all\s*:\s*\[CoreCatalogTrustRoot\]\s*=\s*\[\s*\]",
        source,
    )
    if empty:
        return version, []
    ids = sorted(set(re.findall(r'keyID:\s*"([^"]+)"', source)))
    if not ids:
        raise ManifestError("Core trust-root source is neither empty nor parseable")
    return version, ids


def release_build_settings(pbx: str, bundle_identifier: str) -> dict[str, str]:
    blocks = re.findall(
        r"/\* Release \*/\s*=\s*\{.*?buildSettings\s*=\s*\{(.*?)\n\s*\};\s*name\s*=\s*Release;\s*\};",
        pbx,
        re.S,
    )
    matching = [
        block
        for block in blocks
        if re.search(
            rf"^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*{re.escape(bundle_identifier)};\s*$",
            block,
            re.M,
        )
    ]
    if len(matching) != 1:
        raise ManifestError(
            f"expected one Release build configuration for {bundle_identifier}, found {len(matching)}"
        )
    settings: dict[str, str] = {}
    for name, raw in re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*([^;]+);\s*$", matching[0], re.M):
        value = raw.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        settings[name] = value
    return settings


def yes_no(settings: dict[str, str], name: str) -> bool:
    value = settings.get(name)
    if value not in {"YES", "NO"}:
        raise ManifestError(f"Release setting {name} must be explicit YES/NO, found {value!r}")
    return value == "YES"


def https_host(value: str, label: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ManifestError(f"{label} is not a fixed credential-free HTTPS URL")
    return parsed.hostname


def fingerprint(values: list[str]) -> str:
    return hashlib.sha256(("\n".join(sorted(values)) + "\n").encode("utf-8")).hexdigest()


def surface_discovery(repo: Path) -> dict[str, Any]:
    """Fingerprint security-relevant signals across the complete production source tree.

    This complements exact field parsing: a new source file, endpoint literal,
    storage literal, entitlement/XPC/socket/process/keychain line, or automation
    entry-point signal changes the freeze even before the generator understands a
    new feature in detail.
    """

    candidates = [
        *sorted((repo / "Vela").rglob("*.swift")),
        *sorted((repo / "VelaIPC").rglob("*.swift")),
        *sorted((repo / "Configuration").rglob("*.plist")),
    ]
    production = [
        path
        for path in candidates
        if not {"Tests", "VelaTests", "Fixtures", ".build"}.intersection(path.parts)
    ]
    signal = re.compile(
        r"(?i)(https?://|URL\s*\(|NSXPC|Mach|NWListener|socket|listen|bind|"
        r"SecItem|Keychain|Application\s+Support|appending(?:PathComponent|\(path:)|"
        r"CommandLine|AppIntent|Automation|SceneStore|SMAppService|Process\s*\(|"
        r"executable|entitlement|authorization|bundleIdentifier|serviceName)"
    )
    url_literal = re.compile(r'https?://[^\s"\'<>]+', re.I)
    filesystem_literal = re.compile(
        r'(?:~/Library|/Library|Contents/(?:Helpers|Library))/[^\s"\']*'
    )
    paths: list[str] = []
    signals: list[str] = []
    urls: list[str] = []
    filesystem: list[str] = []
    for path in production:
        relative = str(path.relative_to(repo))
        paths.append(relative)
        source = read(path)
        for line in source.splitlines():
            normalized = " ".join(line.split())
            if normalized and signal.search(normalized):
                signals.append(f"{relative}:{normalized}")
        urls.extend(f"{relative}:{value}" for value in url_literal.findall(source))
        filesystem.extend(
            f"{relative}:{value}" for value in filesystem_literal.findall(source)
        )
    return {
        "scannedFileCount": len(paths),
        "sourcePathListSHA256": fingerprint(paths),
        "securitySignalSHA256": fingerprint(signals),
        "urlLiteralSHA256": fingerprint(urls),
        "filesystemLiteralSHA256": fingerprint(filesystem),
    }


def build(repo: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    constants_path = repo / "VelaIPC/VelaIPCConstants.swift"
    protocol_path = repo / "VelaIPC/VelaHelperProtocol.swift"
    pbx_path = repo / "Vela.xcodeproj/project.pbxproj"
    compatibility_path = repo / "Release/config/compatibility.json"
    release_path = repo / "Release/config/release.json"
    mihomo_path = repo / "Vendor/Mihomo/manifest.json"
    keyring_path = repo / "VelaIPC/CoreCatalogTrust.swift"
    subscription_secrets_path = repo / "Vela/Core/Subscriptions/SubscriptionSecrets.swift"
    application_directories_path = repo / "Vela/Core/Persistence/ApplicationDirectories.swift"
    privileged_directories_path = repo / "VelaIPC/Sources/VelaPrivilegedCore/PrivilegedDirectories.swift"
    fixed_layout_path = repo / "VelaIPC/Sources/VelaPrivilegedCore/FixedMihomoPreflight.swift"
    connectivity_path = repo / "Vela/Core/Network/ConnectivityProbe.swift"
    proxy_probe_path = repo / "Vela/Core/Proxies/ProxyOperationState.swift"

    constants = read(constants_path)
    protocol_source = read(protocol_path)
    pbx = read(pbx_path)
    compatibility = json_file(compatibility_path)
    release = json_file(release_path)
    mihomo = json_file(mihomo_path)
    keyring_source = read(keyring_path)
    subscription_secrets = read(subscription_secrets_path)
    application_directories = read(application_directories_path)
    privileged_directories = read(privileged_directories_path)
    fixed_layout = read(fixed_layout_path)
    connectivity_source = read(connectivity_path)
    proxy_probe_source = read(proxy_probe_path)

    app_id = swift_string("mainBundleIdentifier", constants)
    helper_id = swift_string("helperIdentifier", constants)
    helper_min = swift_int("protocolMinimum", constants)
    helper_max = swift_int("protocolMaximum", constants)
    helper_version = swift_string("helperSemanticVersion", constants)
    helper_build = swift_string("helperBuild", constants)
    expected_mihomo = swift_string("expectedMihomoVersion", constants)
    methods = helper_methods(protocol_source)
    app_release = release_build_settings(pbx, app_id)

    product = release.get("product", {})
    if product.get("bundleIdentifier") != app_id or product.get("helperIdentifier") != helper_id:
        raise ManifestError("Release identifiers disagree with VelaIPC constants")
    team_id = str(product.get("teamIdentifier"))
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ManifestError("invalid Developer Team identifier")
    if expected_mihomo != mihomo.get("version"):
        raise ManifestError("Mihomo version disagrees with vendor manifest")

    release_cross_checks = {
        "ARCHS": str(product.get("architecture")),
        "MACOSX_DEPLOYMENT_TARGET": str(product.get("minimumMacOS")),
        "DEVELOPMENT_TEAM": team_id,
    }
    for name, expected in release_cross_checks.items():
        actual = app_release.get(name)
        if actual is None:
            inherited = sorted(
                set(re.findall(rf"^\s*{re.escape(name)}\s*=\s*([^;]+);\s*$", pbx, re.M))
            )
            actual = inherited[0] if len(inherited) == 1 else None
        if actual != expected:
            raise ManifestError(
                f"App Release {name}={actual!r} disagrees with release config {expected!r}"
            )

    versions = sorted(set(re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", pbx)))
    builds = sorted(set(re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*([^;]+);", pbx)))
    if len(versions) != 1 or len(builds) != 1:
        raise ManifestError(f"project versions are inconsistent: {versions}, {builds}")
    if compatibility.get("automationProtocol") is not None:
        raise ManifestError("Automation protocol is declared but no production surface is expected")
    if compatibility.get("cliProtocol") is not None:
        raise ManifestError("CLI protocol is declared but no production surface is expected")

    core_keyset_version, core_key_ids = core_trust_roots(keyring_source)
    update_key = release.get("updates", {}).get("publicEDKey")
    update_provisioned = isinstance(update_key, str) and not update_key.startswith("__")
    schemas = schema_versions(repo, constants)
    packages = package_versions(repo)
    sparkle = next((item for item in packages if item["identity"] == "sparkle"), None)
    if sparkle is None or sparkle["version"] != "2.9.4":
        raise ManifestError("Sparkle 2.9.4 pin is missing")

    keychain_service = swift_string("defaultService", subscription_secrets)
    application_bundle_identifier = swift_string(
        "defaultBundleIdentifier", application_directories
    )
    if application_bundle_identifier != app_id:
        raise ManifestError("ApplicationDirectories bundle identifier disagrees with VelaIPC")
    privileged_ancestor = one_match(
        r'fileURLWithPath:\s*"([^"]+)"',
        privileged_directories,
        "privileged trusted ancestor",
    )
    if r"\(VelaIPCConstants.mainBundleIdentifier)/Privileged" not in privileged_directories:
        raise ManifestError("Privileged root is no longer derived from the fixed App identifier")
    bundle_paths = sorted(
        set(re.findall(r'appending\(path:\s*"([^"]+)"\)', fixed_layout))
    )
    required_bundle_paths = {
        "Contents/Library/LaunchServices/VelaHelper",
        "Contents/Helpers/mihomo",
    }
    if set(bundle_paths) != required_bundle_paths:
        raise ManifestError(f"fixed privileged bundle paths changed: {bundle_paths}")
    connectivity_url = one_match(
        r'defaultURL\s*=\s*URL\(string:\s*"([^"]+)"\)',
        connectivity_source,
        "ConnectivityProbe default URL",
    )
    proxy_probe_url = one_match(
        r'static\s+let\s+url\s*=\s*"([^"]+)"',
        proxy_probe_source,
        "ProxyOperationState probe URL",
    )
    fixed_probe_hosts = sorted(
        {
            https_host(connectivity_url, "ConnectivityProbe default URL"),
            https_host(proxy_probe_url, "ProxyOperationState probe URL"),
        }
    )

    sources = [
        str(path.relative_to(repo))
        for path in (
            constants_path,
            protocol_path,
            pbx_path,
            compatibility_path,
            release_path,
            mihomo_path,
            keyring_path,
            subscription_secrets_path,
            application_directories_path,
            privileged_directories_path,
            fixed_layout_path,
            connectivity_path,
            proxy_probe_path,
            repo / "Configuration/Privileged/dev.yilin.Vela.Helper.plist",
        )
    ]
    manifest: dict[str, Any] = {
        "schemaVersion": 1,
        "generatorVersion": GENERATOR_VERSION,
        "sources": sources,
        "surfaceDiscovery": surface_discovery(repo),
        "product": {
            "marketingVersion": versions[0],
            "build": builds[0],
            "minimumMacOS": str(product.get("minimumMacOS")),
            "architectures": [str(product.get("architecture"))],
        },
        "identifiers": {
            "application": app_id,
            "helper": helper_id,
            "helperMachService": helper_id,
            "cli": None,
            "appGroup": None,
            "appIntentIdentifiers": [],
        },
        "protocols": {
            "helper": {
                "minimum": helper_min,
                "maximum": helper_max,
                "methodCount": len(methods),
                "methods": methods,
            },
            "automation": None,
            "cli": None,
        },
        "schemas": schemas,
        "trustRoots": [
            {
                "kind": "developerIDTeam",
                "identifier": team_id,
                "status": "configured",
            },
            {
                "kind": "sparkleEdDSA",
                "identifier": None,
                "status": "configured" if update_provisioned else "unprovisioned",
            },
            {
                "kind": "coreCatalogEd25519",
                "identifier": core_key_ids,
                "keySetVersion": core_keyset_version,
                "status": "configured" if core_key_ids else "unprovisioned",
            },
        ],
        "bundledComponents": [
            {
                "name": "Vela",
                "version": versions[0],
                "build": builds[0],
                "architecture": "arm64",
            },
            {
                "name": "VelaHelper",
                "version": helper_version,
                "build": helper_build,
                "architecture": "arm64",
            },
            {
                "name": "mihomo",
                "version": expected_mihomo,
                "architecture": str(mihomo.get("architecture")),
                "runtimeDownloadAllowed": bool(mihomo.get("runtimeDownloadAllowed")),
            },
            {
                "name": "Sparkle",
                "version": sparkle["version"],
                "revision": sparkle["revision"],
            },
        ],
        "keychainCategories": [
            {
                "service": keychain_service,
                "accountTemplate": "<profile-uuid>",
                "valueCategory": "subscription URL and authentication envelope",
            }
        ],
        "filesystem": {
            "userRoots": [
                f"~/Library/Application Support/{application_bundle_identifier}",
            ],
            "privilegedRoots": [
                f"{privileged_ancestor}/{app_id}/Privileged",
            ],
            "bundlePaths": [
                *[f"Vela.app/{path}" for path in bundle_paths],
                f"Vela.app/Contents/Library/LaunchDaemons/{helper_id}.plist",
            ],
            "arbitraryRootPathAccepted": False,
            "arbitraryPIDAccepted": False,
            "arbitraryCommandAccepted": False,
        },
        "networkEndpointCategories": [
            {
                "id": "loopbackController",
                "origin": "fixed loopback endpoint allocated by Vela",
                "scheme": "http/ws",
            },
            {
                "id": "userConfiguredSubscriptionOrProvider",
                "origin": "explicit user configuration",
                "scheme": "https; http only after explicit insecure opt-in",
            },
            {
                "id": "signedAppUpdateFeed",
                "origin": "release configuration",
                "scheme": "https",
                "status": "unprovisioned" if not update_provisioned else "configured",
            },
            {
                "id": "signedCoreCatalogAndArtifacts",
                "origin": "release configuration and signed catalog",
                "scheme": "https",
                "status": "unprovisioned" if not core_key_ids else "configured",
            },
            {
                "id": "fixedConnectivityProbe",
                "origin": "Vela source allowlist",
                "hosts": fixed_probe_hosts,
                "scheme": "https",
            },
            {
                "id": "userOpenedExternalLink",
                "origin": "explicit user action",
                "scheme": "https",
            },
        ],
        "capabilities": [
            "userMihomoProcess",
            "privilegedMihomoProcess",
            "systemProxy",
            "tun",
            "genericPasswordKeychain",
            "subscriptionHTTP",
            "sparkleAppUpdate",
            "signedCoreLifecycle",
            "offlineHelp",
            "localSupportExport",
        ],
        "absentSurfaces": [
            "productionCLI",
            "productionAutomationSocket",
            "productionAppIntents",
            "productionSceneStore",
            "networkExtension",
            "remoteAnalytics",
            "automaticCrashUpload",
            "remoteFeatureFlags",
        ],
        "releaseSecurity": {
            "appSandbox": yes_no(app_release, "ENABLE_APP_SANDBOX"),
            "hardenedRuntime": yes_no(app_release, "ENABLE_HARDENED_RUNTIME"),
            "explicitEntitlementsFile": bool(app_release.get("CODE_SIGN_ENTITLEMENTS")),
            "privacyManifest": "Vela/Resources/PrivacyInfo.xcprivacy",
        },
    }

    attack_surface: dict[str, Any] = {
        "schemaVersion": 1,
        "architectureManifestSHA256": hashlib.sha256(
            (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        ).hexdigest(),
        "processes": [
            {"id": "app", "binary": "Vela", "uid": "logged-in user"},
            {"id": "helper", "binary": "VelaHelper", "uid": "root"},
            {
                "id": "userCore",
                "binary": "mihomo",
                "uid": "logged-in user",
                "owner": "Vela",
            },
            {
                "id": "privilegedCore",
                "binary": "mihomo",
                "uid": "root",
                "owner": "VelaHelper",
            },
            {"id": "sparkle", "binary": "Sparkle services", "uid": "logged-in user"},
        ],
        "localInterfaces": [
            {
                "id": "helperXPC",
                "transport": "Mach/XPC",
                "endpoint": helper_id,
                "authentication": "Apple code signature, exact App identifier and Team",
                "bounded": True,
            },
            {
                "id": "mihomoController",
                "transport": "loopback HTTP/WebSocket",
                "endpoint": "ephemeral loopback port",
                "authentication": "session controller secret",
                "bounded": True,
            },
        ],
        "externalInputs": [
            {
                "id": "profileAndSubscriptionContent",
                "trust": "untrusted user/provider content",
                "controls": ["size limits", "YAML validation", "protected path policy", "mihomo -t"],
            },
            {
                "id": "appUpdate",
                "trust": "untrusted network, trusted only after Sparkle verification",
                "controls": ["HTTPS", "signed feed", "EdDSA", "code signing", "notarization"],
                "readiness": "stopShipUntilProductionFeedAndKey",
            },
            {
                "id": "coreCatalog",
                "trust": "untrusted network, trusted only after raw-byte Ed25519 verification",
                "controls": ["HTTPS", "signature", "sequence", "expiry", "hash", "code signing"],
                "readiness": "stopShipUntilProductionEndpointsAndKeyring",
            },
            {
                "id": "bundledHelpAndPolicy",
                "trust": "signed bundle resource",
                "controls": ["manifest hash", "bounded parser", "external-link policy"],
            },
        ],
        "privilegedOperations": [
            "prepare/stage/commit/abort fixed-root configuration start",
            "start/stop/lease/cleanup owned privileged mihomo",
            "bounded startup log retrieval",
            "prepare/stage/commit/abort fixed-role signed Core install",
            "list/refresh/remove/validate signed Core records",
        ],
        "dataStores": [
            {
                "id": "userApplicationSupport",
                "pathTemplate": "~/Library/Application Support/dev.yilin.Vela",
                "owner": "logged-in user",
            },
            {
                "id": "rootRuntimeAndCoreStore",
                "pathTemplate": "/Library/Application Support/dev.yilin.Vela/Privileged",
                "owner": "root",
            },
            {
                "id": "subscriptionKeychain",
                "service": "dev.yilin.Vela.subscription",
                "owner": "logged-in user",
            },
        ],
        "explicitlyAbsent": manifest["absentSurfaces"],
    }
    return manifest, attack_surface


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_or_verify(path: Path, value: dict[str, Any], verify: bool) -> None:
    encoded = canonical(value)
    if verify:
        try:
            existing = path.read_bytes()
        except OSError as error:
            raise ManifestError(f"cannot verify {path}: {error}") from error
        if existing != encoded:
            raise ManifestError(
                f"{path} is stale; regenerate with generate_architecture_manifest.py"
            )
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(encoded)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--architecture-output", required=True)
    parser.add_argument("--attack-surface-output", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repository_root).resolve()
    try:
        manifest, attack_surface = build(repo)
        write_or_verify(Path(args.architecture_output), manifest, args.verify)
        write_or_verify(Path(args.attack_surface_output), attack_surface, args.verify)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    action = "Verified" if args.verify else "Generated"
    print(f"{action} architecture freeze and attack-surface manifests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
