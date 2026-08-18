# Vela 0.5.0

## Highlights

- Secure signed application updates and release verification.

## Improvements

- Stable and Beta channels share one signed feed.

## Fixes

- Update preparation uses bounded TUN cleanup before installation.

## Security

- Update archives, appcasts, and external release notes require EdDSA signatures.

## Compatibility

- macOS 15 or later.
- Apple Silicon only.
- Mihomo v1.19.29.

## Upgrade Notes

- Vela stops TUN before installation and restores state only after compatibility checks.

## Known Issues

- Returning from Beta to Stable requires a newer Stable build; automatic downgrade is disabled.

## Open Source Notices

See the third-party notices included with Vela.
