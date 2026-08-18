# ADR: Freeze the V1.0 release-candidate architecture

- Status: Accepted
- Baseline SHA256: 0dbdbb90c16a9ea2950741adfade3d08b44961c4f04f8c4ecadbe94986971e52
- Current SHA256: b13dd6f30867075ba1b0de0dd35d1b41c3baa39cb05dccc5ba74a98d949910e6
- Security owner: Vela Security Engineering
- Release owner: Vela Release Engineering

## Change

Regenerate the production architecture inventory for Vela 1.0.0 build 2026071403
after the V0.9 Release Candidate work. The source changes add bundled, bilingual RC
status and support presentation plus repository-side contract, migration, provenance,
two-phase candidate, installation-matrix, attestation, and final-promotion gates.

The generated inventory continues to derive its values from production declarations.
It does not copy aspirational V1 fixtures into absent runtime surfaces.

## Security impact

No new App permission, entitlement, privileged RPC, local listener, network endpoint
category, persistence root, public trust root, or automatic upload is introduced. The
release pipeline now binds the tagged version/build and exact architecture bytes, seals
the App and complete xcarchive containers, and atomically publishes protected evidence.
About UI claims are fail-closed when a signed bundled release manifest is unavailable.

Production CLI, Automation Socket, App Intents, and Scene Store remain explicitly
absent. Unprovisioned App-update and Core-catalog trust roots remain Stop-Ship
conditions; this ADR does not authorize credentials, publication, or a Go decision.

## Compatibility

The App remains Apple-silicon-only with macOS 15.0 minimum. Helper protocol v2 retains
the exact 19-method surface, existing data/profile/configuration/update-journal schemas
remain unchanged, and Scene/CLI/Automation compatibility remains absent. V0.1 through
V0.8 historical migration evidence and physical upgrade/rollback results are still
required externally before promotion.

## Tests

The architecture generator and semantic validator reproduce both freeze files; the
attack-surface manifest binds this exact SHA-256. Contract, candidate evidence,
installation-matrix, build-ledger, promotion-closure, localization/resource, Release
tooling, Swift, Debug/Release build, and launch smoke checks are the required regression
set. External audit, performance, accessibility/privacy, soak, and physical matrix
evidence remain independent release gates.

## Review

Vela Security Engineering accepts the non-expanding source inventory and strengthened
release-evidence boundaries. Vela Release Engineering accepts the version/build and
two-phase exact-byte packaging model. Neither review marks the current candidate Go;
all machine-reported and accountable manual Stop-Ship conditions remain binding.
