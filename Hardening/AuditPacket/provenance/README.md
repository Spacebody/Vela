# Provenance

The generated packet requires explicit immutable artifact, release-manifest, and SPDX SBOM
files and records their SHA-256 values. GitHub artifact/SBOM attestations are included only
when the protected GitHub release workflow actually produced them; offline/local releases
must not fabricate GitHub provenance.
