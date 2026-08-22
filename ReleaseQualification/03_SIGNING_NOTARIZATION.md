# Signing and Notarization Qualification

Date: 2026-08-23

## Exact production candidate

`NOT EXECUTED — RELEASE CONFIGURATION AND EPHEMERAL CREDENTIALS REQUIRED`

No exact production candidate was notarized, stapled, packaged, installed or launched in this qualification continuation.

## Current-source signing and notarization integration sample

An isolated Release archive was built from `80cc6e490eae65c542d4936cf52c157a3b5bd58d` at `/tmp/Vela-RQ-80cc6e4.xcarchive` using the configured Developer ID Application identity. The archive was then exported with the repository's Developer ID `ExportOptions.plist` to `/tmp/Vela-RQ-80cc6e4-export/Vela.app`.

PASS:

- Xcode Release archive and Developer ID export;
- App and Helper identifiers and Team ID;
- App/Helper Developer ID certificate chain and secure timestamps;
- Hardened Runtime for App and Helper;
- strict nested code-sign verification, including Developer ID signatures, Team ID, Hardened Runtime and secure timestamps for Sparkle.framework, Autoupdate, Updater.app, Downloader.xpc and Installer.xpc;
- Helper designated requirement and embedded launch-daemon association.
- Apple notarization submission `1a651f09-1e81-409b-9f6e-818e2b5e7a2f`: `Accepted`;
- stapler validation: passed;
- Gatekeeper assessment: accepted as `Notarized Developer ID`.

Final exported sample identity:

- App CDHash: `d2cff70e4fca88ee588f8928bb789046fa3ee43f`;
- Helper CDHash: `b4a06b6626de89642ae8df66976931de6fa3ad2c`;
- App executable SHA-256: `90013db071062629baca33db5cb1e5e48fc7f51f91c8885a57e2e7f12844cdcb`;
- Helper SHA-256: `9c47699f9a36f7e6c7eb23b7db9747564134f8b20b23b9ec627369caf4731bfb`;
- Mihomo SHA-256: `84f3ccfac6048b35e53daf1cd2a96e79961bac093d047904166164247a905ad0`.

Disposition: **PASS — CURRENT-SOURCE SIGNING/EXPORT/NOTARIZATION INTEGRATION** and **PARTIAL — NOT A PRODUCTION RELEASE CANDIDATE**. The sample used the persistent developer Keychain and a stored notary profile, so it cannot satisfy the reviewed ephemeral release-Keychain and per-run credential contract. It also contains fail-closed placeholder release configuration. It was not installed or launched.

### Intermediate archive negative control

Submission `4b7f8e80-c9b0-42df-a885-613e63733f16` intentionally records what happens when the archive's intermediate App is submitted before `xcodebuild -exportArchive`: Apple returned `Invalid` because Sparkle's embedded Autoupdate, Updater, Downloader and Installer components retained their upstream ad-hoc signatures and lacked secure timestamps.

This is not a production packaging defect. The repository's reviewed production pipeline performs `archive -> exportArchive -> verify -> notarize`; the export step correctly re-signs those components with Vela's Developer ID identity. The accepted exported sample proves the current pipeline ordering. Future qualification must never submit `Vela.xcarchive/Products/Applications/Vela.app` directly.

## Production pipeline blockers

`./Release/scripts/release.sh --dry-run` passes release-tooling structure, 32 Hardening tests, workflow validation, deterministic manifests/checksums, SBOM fixtures, compatibility-lab tooling and Core release fixtures. It then deliberately remains fail-closed. Current blockers include:

- non-production Sparkle feed URL and placeholder EdDSA public key;
- public-contract requirements for absent CLI, Automation and App Intents surfaces;
- missing production Core distribution/catalog/signature endpoints and trust roots;
- missing reviewed dedicated-host compatibility/performance evidence;
- absent production per-run P12, notary API key/profile and Sparkle private-key inputs (the stored local notary profile used for this integration sample is not admissible production evidence);
- no historical release tags/fixtures for the required upgrade matrix.

The production script forbids persistent Keychain fallback. A successful local Developer ID archive cannot bypass these gates.

## Repository-controlled migration evidence

The focused `ProfileMigrationTests` lane passes 11 tests for the current source. It
proves the repository-controlled schema path for:

- transactional and idempotent v1-to-v2 migration with backup;
- real V0.1 field and epoch-date preservation, including unknown metadata;
- v2 no-op behavior;
- invalid-v1 and interrupted-replacement recovery without replacing known-good data;
- profile artifact deletion and bounded revision retention;
- rollback after metadata persistence failure;
- remote-profile metadata persistence without storing a raw secret URL and rejection
  of unsafe URL components.

Disposition: **PASS — REPOSITORY MIGRATION INVARIANTS**. This closes the
repository-controlled schema-migration portion only. It is not a real previous signed
Vela package to exact production candidate upgrade, because the repository contains no
historical release artifact/tag suitable for that matrix. The notarized integration
sample above is deliberately not promoted to a production candidate.

## Read-only installed-bundle inspection

`/Applications/Vela.app` predates the source baseline and is not the qualification candidate. Its metadata names Team `2E56T94S33`, App `dev.yilin.Vela`, Helper `dev.yilin.Vela.Helper`, Hardened Runtime, version 1.0.0 and build `2026071403`. However:

- strict deep App verification fails;
- strict Helper and Mihomo verification fail;
- Gatekeeper assessment returns a signing-subsystem error;
- production release manifest enforcement and update/Core endpoints are absent.

Disposition: **FAIL — NON-CANDIDATE LOCAL ARTIFACT**. This is a release-artifact blocker, not evidence that current source fails to build.

Current-source integration now proves App/Helper designated-requirement compatibility, entitlements, Hardened Runtime, bundle structure, embedded Helper/Core/Sparkle identity, notarization, stapling and Gatekeeper acceptance for the exported sample. Production closure still requires the exact immutable production candidate, ephemeral credentials, package/DMG integrity, clean-machine install, first launch and prior-version package upgrade. Repository schema-migration invariants must not be represented as that missing package-upgrade lane.
