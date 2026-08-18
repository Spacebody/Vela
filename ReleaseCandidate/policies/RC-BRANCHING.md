# RC branching and versioning

- `main` remains the integration branch.
- `release/1.0` accepts only approved freeze classes and receives every RC fix.
- Every RC fix is merged back to `main`; two security implementations may not diverge.
- `hotfix/1.0.x` is created only for a coordinated Stable incident.

Tags are annotated and signed: `v1.0.0-rc.1`, `v1.0.0-rc.2`, then `v1.0.0`.
Build numbers use global `YYYYMMDDNN` monotonic ordering and are never reused, including
failed or withdrawn builds. Stable is rebuilt, signed, and notarized with a build higher
than every RC; an RC artifact is never renamed into Stable.

The protected `published-builds.json` input is a schemaVersion 3 allocation ledger despite
its legacy filename. Every attempted build is retained with status `allocated`, `failed`,
`withdrawn`, or `published`; the next build must exceed the high-water mark across all four
states. A published row requires the artifact SHA, while a non-published row may record a
partial artifact SHA but may never be removed to make its number reusable.
Failed or allocated attempts do not consume the SemVer identity: the same RC/Stable version
may be retried only with a build above the global high-water mark. Published and withdrawn
versions are final and cannot be reissued; `withdrawn` is reserved for a candidate that was
made externally available and then withdrawn, not for an internal build failure.

The App's frozen update channel remains `beta` for RCs and `stable` for Stable. The RC
identity is carried by the signed tag, prerelease label, and separate RC manifest.
