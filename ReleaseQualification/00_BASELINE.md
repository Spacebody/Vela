# Vela Release Qualification Baseline

Date: 2026-08-22
Qualification source: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949`

## Source identity

- Branch: `main`.
- Local `HEAD`: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949`.
- `origin/main`: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949` at baseline capture.
- Worktree: clean before qualification evidence was created.
- Previous release-evidence source baseline: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc`.
- The commits after that evidence source are documentation-only: `bcc0c25 docs: close release evidence review`.
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
| Qualification build intent | unsigned Debug and unsigned Release repository gates; no signed candidate creation without explicit authorization |

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

## Runtime and privileged baseline

- Production Vela process: not running.
- VelaHelper process: not running.
- Installed privileged Vela Helper under `/Library/PrivilegedHelperTools`: not present.
- Installed Vela launch daemon under `/Library/LaunchDaemons`: not present.
- macOS System Proxy read-back: no enabled proxy dictionary entries at capture time.
- System-extension enumeration was unavailable from the current restricted session and is not used as TUN proof.
- A separate Clash Verge Mihomo process is active. It is outside this qualification candidate and must not be stopped or mutated.
- A stale stopped `/private/tmp/VelaPerfFixture.app` process from earlier evidence capture was identified and terminated before this run. It is recorded as evidence-harness residue, not a Vela production defect.

## Authorization boundary

No signed candidate was created, installed or launched. No helper was installed. No System Proxy, TUN/system network card, route, sleep state, network service or user configuration was mutated.

Signed-host and destructive qualification remains:

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

## Baseline release-readiness state

The repository is intentionally fail-closed. Active conditions include production trust provisioning, privacy/legal approval, required release surfaces, historical migration fixtures, approved performance budgets, external audit, 24-hour and 72-hour soak evidence, multi-user evidence, destructive System Proxy/TUN/sleep evidence, a signed/notarized/stapled candidate, and final SBOM/provenance evidence.

The exact source may proceed through repository-controlled and isolated runtime qualification, but it is not eligible for release declaration while those conditions remain active.
