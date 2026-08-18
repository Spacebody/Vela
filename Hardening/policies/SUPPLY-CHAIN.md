# Supply-chain and attestation policy

Keep Developer ID, notarization, Sparkle EdDSA, independent Core Ed25519, immutable
artifacts, checksums, release manifest, and SPDX SBOM. GitHub Actions are pinned to full
commit SHAs with minimum permissions; Dependabot/Secret Scanning/Push Protection are
repository settings and must be verified separately.

CodeQL/Dependency Review/secret-pattern workflows provide useful coverage but do not
replace manual source, trust-boundary, dependency-license, or release review. Tool absence
or a green empty scan is not a security conclusion.

Artifact and SBOM attestations are generated only inside the protected workflow that owns
the final immutable files. The workflow defaults to `contents: read`; only its isolated
`attest` job has the exact reviewed `contents: read`, `id-token: write`,
`attestations: write`, and `artifact-metadata: write` override. The Hardening workflow
validator binds that complete mapping to the canonical release-workflow path and job name,
and rejects missing, additional, renamed, or relocated permissions. Publishing remains
outside the credential-bearing job, and incomplete real provenance evidence remains an
active Stop-Ship item rather than a fabricated pass.

Offline release provenance may use Apple signature/notary, signed App/Core metadata,
manifest, and checksum evidence, explicitly labeled as offline/internal provenance. It
must never be presented as GitHub artifact attestation.
