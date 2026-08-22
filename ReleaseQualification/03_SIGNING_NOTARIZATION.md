# Signing and Notarization Qualification

Date: 2026-08-22

## Exact production candidate

`NOT EXECUTED — RELEASE CONFIGURATION AND EPHEMERAL CREDENTIALS REQUIRED`

No exact production candidate was notarized, stapled, packaged, installed or launched in this qualification continuation.

## Current-source signing integration sample

An isolated Release archive was built from `a353fad1047a190f07821db0c77c52e597aaa556` at `/tmp/Vela-RQ-a353fad.xcarchive` using the configured Developer ID Application identity.

PASS:

- Xcode Release archive;
- App and Helper identifiers and Team ID;
- App/Helper Developer ID certificate chain and secure timestamps;
- Hardened Runtime for App and Helper;
- strict nested code-sign verification, including Sparkle services and Mihomo;
- Helper designated requirement and embedded launch-daemon association.

EXPECTED FAIL:

- `stapler validate`: no ticket;
- Gatekeeper: `Unnotarized Developer ID`.

Disposition: **PARTIAL — SIGNING INTEGRATION PROVED, NOT A RELEASE CANDIDATE**. The sample used the persistent developer Keychain and therefore cannot satisfy the reviewed ephemeral release-Keychain contract. It was not submitted to Apple or installed.

## Production pipeline blockers

`./Release/scripts/release.sh --dry-run` passes release-tooling structure, 32 Hardening tests, workflow validation, deterministic manifests/checksums, SBOM fixtures, compatibility-lab tooling and Core release fixtures. It then deliberately remains fail-closed. Current blockers include:

- non-production Sparkle feed URL and placeholder EdDSA public key;
- public-contract requirements for absent CLI, Automation and App Intents surfaces;
- missing production Core distribution/catalog/signature endpoints and trust roots;
- missing reviewed dedicated-host compatibility/performance evidence;
- absent per-run P12, notary API key/profile and Sparkle private-key inputs;
- no historical release tags/fixtures for the required upgrade matrix.

The production script forbids persistent Keychain fallback. A successful local Developer ID archive cannot bypass these gates.

## Read-only installed-bundle inspection

`/Applications/Vela.app` predates the source baseline and is not the qualification candidate. Its metadata names Team `2E56T94S33`, App `dev.yilin.Vela`, Helper `dev.yilin.Vela.Helper`, Hardened Runtime, version 1.0.0 and build `2026071403`. However:

- strict deep App verification fails;
- strict Helper and Mihomo verification fail;
- Gatekeeper assessment returns a signing-subsystem error;
- production release manifest enforcement and update/Core endpoints are absent.

Disposition: **FAIL — NON-CANDIDATE LOCAL ARTIFACT**. This is a release-artifact blocker, not evidence that current source fails to build.

Closure requires proof for the exact release SHA: App/Helper designated-requirement compatibility, entitlements, Hardened Runtime, bundle structure, embedded Helper/Core identity, Gatekeeper acceptance, notarization, stapling, package integrity, clean-machine install, first launch and prior-version upgrade.
