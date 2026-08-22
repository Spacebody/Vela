# Signing and Notarization Qualification

Date: 2026-08-22

## Exact candidate

`NOT EXECUTED — SIGNING OR AUTHORIZATION REQUIRED`

No exact candidate was archived, Developer-ID signed, notarized, stapled, packaged, installed or launched in this qualification session.

## Read-only installed-bundle inspection

`/Applications/Vela.app` predates the source baseline and is not the qualification candidate. Its metadata names Team `2E56T94S33`, App `dev.yilin.Vela`, Helper `dev.yilin.Vela.Helper`, Hardened Runtime, version 1.0.0 and build `2026071403`. However:

- strict deep App verification fails;
- strict Helper and Mihomo verification fail;
- Gatekeeper assessment returns a signing-subsystem error;
- production release manifest enforcement and update/Core endpoints are absent.

Disposition: **FAIL — NON-CANDIDATE LOCAL ARTIFACT**. This is a release-artifact blocker, not evidence that current source fails to build.

Closure requires proof for the exact release SHA: App/Helper designated-requirement compatibility, entitlements, Hardened Runtime, bundle structure, embedded Helper/Core identity, Gatekeeper acceptance, notarization, stapling, package integrity, clean-machine install, first launch and prior-version upgrade.
