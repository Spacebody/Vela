# Vela Release Qualification Baseline

Date: 2026-08-23
Qualification source: `80cc6e490eae65c542d4936cf52c157a3b5bd58d`

## Source identity

- Branch: `main`.
- Local `HEAD`: `80cc6e490eae65c542d4936cf52c157a3b5bd58d`.
- `origin/main`: `80cc6e490eae65c542d4936cf52c157a3b5bd58d` at continuation capture.
- Worktree: clean before qualification evidence was created.
- Previous release-evidence source baseline: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc`.
- Commits since the previous release-evidence baseline are `bcc0c25`, `a353fad`, `2e40b14` and `80cc6e4`. They close repository-controlled evidence gaps and add migration/accessibility qualification; this continuation does not reopen a closed finding without contradictory runtime evidence.
- No prior engineering finding is reopened by source drift at baseline.

## Required prior evidence read

- `EngineeringReview/16_PRODUCTION_EVIDENCE_DELTA.md`
- `EngineeringReview/17_RENDERED_RUNTIME_EVIDENCE.md`
- `EngineeringReview/18_SIGNED_HOST_EVIDENCE.md`
- `EngineeringReview/19_RELEASE_CLOSURE_REPORT.md`
- `Hardening/README.md`
- `Hardening/config/release-readiness.json`
- `Hardening/config/soak-matrix.json`
- `Hardening/checklists/BETA-RELEASE.md`
- `Hardening/checklists/PERFORMANCE-BUDGET-APPROVAL.md`
- `Release/README.md`
- `Release/config/release.json`

Historical engineering reports remain historical. This directory records qualification of the exact source above and does not rewrite their conclusions.

## Test host

| Field | Exact value |
|---|---|
| macOS | 26.5.2 (25F84) |
| Hardware | MacBook Pro, `MacBookPro18,3`, Apple M1 Pro |
| CPU / memory | 10 cores (8 performance + 2 efficiency), 16 GB |
| Architecture | arm64 |
| Xcode | 26.6 (17F113) |
| Minimum supported macOS | 15.0 |
| Qualification build intent | unsigned repository gates plus an isolated Developer ID export/notarization integration sample under `/tmp`; no installation, launch or network mutation |

Machine serial, hardware UUID and provisioning identifiers are intentionally excluded from committed evidence.

## Source build and component configuration

- Xcode project/scheme: `Vela.xcodeproj` / `Vela`.
- Release build settings: `Release`, arm64, `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=2026071403`.
- Release signing intent: manual `Developer ID Application`, Team ID `2E56T94S33`, Hardened Runtime enabled.
- Bundle identifiers: App `dev.yilin.Vela`; Helper `dev.yilin.Vela.Helper`.
- Mihomo/Core: source manifest and installed bundle both report `v1.19.29`; installed binary reports darwin arm64, Go 1.26.5, `with_gvisor`.
- Sparkle: 2.9.4. Yams: 6.2.2.
- Production App feed/key and Core catalog endpoints remain placeholders or empty and are active fail-closed release-readiness conditions.

## Current installed bundle — not the qualification candidate

`/Applications/Vela.app` exists, but it predates this source baseline and is not accepted as the exact release candidate.

Static read-only inspection found:

- version 1.0.0, build `2026071403`;
- Hardened Runtime flag and Team ID `2E56T94S33` present in the signature metadata;
- App and embedded Helper designated requirements reference the expected bundle identifiers and Team ID;
- embedded launch-daemon metadata associates `dev.yilin.Vela.Helper` with `dev.yilin.Vela`;
- `codesign --verify --deep --strict` fails for the App;
- strict verification also fails independently for the embedded Helper and Mihomo binary;
- Gatekeeper assessment returns a Code Signing subsystem error;
- the installed App has no production release manifest requirement and empty update/Core endpoints.

Disposition: **FAIL — NON-CANDIDATE LOCAL ARTIFACT**. It is neither launched nor treated as proof for current source. Creating, signing, installing, notarizing or launching an exact candidate requires explicit authorization and release credentials.

## Current-source signing and notarization integration sample

An isolated Release archive and Developer ID export were produced from the exact continuation SHA at:

`/tmp/Vela-RQ-80cc6e4.xcarchive`

`/tmp/Vela-RQ-80cc6e4-export/Vela.app`

This is a **signing integration sample, not a release candidate**. It was signed from the user's persistent Keychain to prove project integration; the reviewed release process requires an ephemeral per-run Keychain and the complete production release inputs.

Verified facts:

- archive and Developer ID export completed with identity `Developer ID Application: YILIN ZHENG (2E56T94S33)`;
- App and Helper use Team ID `2E56T94S33`, expected identifiers and Hardened Runtime;
- strict deep App verification and strict Helper verification pass;
- nested Sparkle services, bundled Mihomo and sealed resources pass deep validation;
- App CDHash is `d2cff70e4fca88ee588f8928bb789046fa3ee43f`;
- Helper CDHash is `b4a06b6626de89642ae8df66976931de6fa3ad2c`;
- App, Helper and Mihomo executable SHA-256 values are respectively `90013db071062629baca33db5cb1e5e48fc7f51f91c8885a57e2e7f12844cdcb`, `9c47699f9a36f7e6c7eb23b7db9747564134f8b20b23b9ec627369caf4731bfb` and `84f3ccfac6048b35e53daf1cd2a96e79961bac093d047904166164247a905ad0`;
- exported App notarization submission `1a651f09-1e81-409b-9f6e-818e2b5e7a2f` was `Accepted`;
- stapler validation and Gatekeeper assessment passed as `Notarized Developer ID`.

The sample is not installed, launched, packaged as the production DMG, appcast-signed or accepted as migration/soak/signed-host evidence. It used persistent local credentials rather than the production ephemeral credential contract and contains fail-closed placeholder release configuration.

An earlier negative-control submission of the archive intermediate App, `4b7f8e80-c9b0-42df-a885-613e63733f16`, was invalid because the pre-export Sparkle components remained ad-hoc signed. The production pipeline already performs `exportArchive`; the accepted exported sample confirms that no source change is required.

## Runtime and privileged baseline

- Production Vela process: not running.
- VelaHelper process: not running.
- Installed privileged Vela Helper under `/Library/PrivilegedHelperTools`: not present.
- Installed Vela launch daemon under `/Library/LaunchDaemons`: not present.
- A stale ServiceManagement registration from build `2026071403` remains in `system/dev.yilin.Vela.Helper`. It is inactive, reports `spawn failed`, last exit `78: EX_CONFIG`, and cannot resolve its missing embedded program. This is pre-candidate host contamination and must be removed or avoided by using a clean host before Helper/TUN qualification.
- macOS System Proxy read-back: no enabled proxy dictionary entries at capture time.
- System-extension enumeration was unavailable from the current restricted session and is not used as TUN proof.
- A separate Clash Verge Mihomo process is active. It is outside this qualification candidate and must not be stopped or mutated.
- A stale stopped `/private/tmp/VelaPerfFixture.app` process from earlier evidence capture was identified and terminated before this run. It is recorded as evidence-harness residue, not a Vela production defect.

## Authorization boundary

A Developer ID signing/notarization integration sample was created under `/tmp`; no exact production candidate was created, installed or launched. No helper was installed. No System Proxy, TUN/system network card, route, sleep state, network service or user configuration was mutated.

Signed-host and destructive qualification remains:

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

## Baseline release-readiness state

The repository is intentionally fail-closed. Active conditions include production trust provisioning, privacy/legal approval, required release surfaces, historical migration fixtures, approved performance budgets, external audit, 24-hour and 72-hour soak evidence, multi-user evidence, destructive System Proxy/TUN/sleep evidence, a signed/notarized/stapled candidate, and final SBOM/provenance evidence.

The exact source may proceed through repository-controlled and isolated runtime qualification, but it is not eligible for release declaration while those conditions remain active.
