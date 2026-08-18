# SemVer, build, support, and downgrade policy

Vela uses Semantic Versioning for its public contract: MAJOR is an incompatible public
contract or supported-data change, MINOR is a backward-compatible feature, PATCH is a
backward-compatible fix, and prereleases use `beta.N` or `rc.N`.

The App marketing version remains the numeric base (`1.0.0`). An RC is identified by the
logical candidate version (`1.0.0-rc.N`), signed tag (`v1.0.0-rc.N`), display label
(`RC N`), existing App update channel (`beta`), and globally unique build. Stable uses
`1.0.0`, `v1.0.0`, the `stable` App channel, and a new build greater than every RC.

Builds use `YYYYMMDDNN`, increase globally, and are never reused after a failed,
withdrawn, or published attempt. Bundle, Appcast, external Release Manifest, and RC
Manifest must agree on the numeric build and marketing version.

Current Stable receives full support. When an immutable previous Stable actually exists
and is retained, it receives documented upgrade and recovery guidance. For the first V1
launch, no previous-Stable availability claim is made until publication and retention
evidence exists. Vela never silently downgrades the App. A manual older install must first
encounter the newer-data write guard and direct the user to backup/export and
compatibility guidance; write compatibility with a newer schema is not promised.
