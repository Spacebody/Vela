# Vela 0.5.0

## Highlights

- Secure signed application updates.
- Stable and Beta update channels.
- Safe TUN shutdown and post-update recovery.

## Compatibility

- macOS 15 or later.
- Apple Silicon only.
- Mihomo v1.19.28.

## Upgrade Notes

Vela safely stops TUN before installing the update and verifies the privileged component
before restoring your previous network mode.

## Privacy

Vela does not send system profiling or crash reports as part of update checks.
