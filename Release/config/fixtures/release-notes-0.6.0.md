# Vela 0.6.0

## Highlights

- Signed Mihomo Core lifecycle with immutable Factory fallback and explicit activation.

## Improvements

- Core Catalog verification enforces raw-byte Ed25519 signatures, monotonic sequence, expiry, and fixed file roles.

## Fixes

- Core activation and App updates share one mutation gate with durable recovery state.

## Security

- External Core bundles require exact hashes, Developer ID signing, strict preflight, and independent Helper verification.

## Compatibility

- macOS 15 or later.
- Apple Silicon only.
- Mihomo v1.19.29.

## Upgrade Notes

- Installed external Cores remain opt-in; Vela does not automatically activate a downloaded Core.

## Known Issues

- Production Core distribution remains unavailable until the protected Catalog origin and release trust roots are provisioned.

## Open Source Notices

See the bundled GPL license, source provenance, SBOM, and third-party notices.
