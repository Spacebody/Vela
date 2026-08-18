# App and Core Updates


Vela App updates use Sparkle signed archives, a signed appcast, Developer ID, and Apple
notarization. Before installation, Vela safely stops TUN and records a recovery journal.

Mihomo core updates use a separate signed catalog. The built-in Factory Core remains
inside Vela and is never replaced at runtime.

A candidate core enters a probation period. If it fails core-specific checks, Vela rolls
back to the previous known-good core or the Factory Core.

## Known Limitations

This Release Candidate declares these non-stop-ship limitations:

- Vela V1 supports arm64 Apple Silicon Macs only; it does not ship an Intel or Universal
  binary.
- Vela V1 requires macOS 15 or later.
- TUN can conflict with another active VPN when both compete for routes or DNS ownership.
  Stop the other VPN before enabling Vela TUN, or use System Proxy mode.
- Subscriptions may provide Mihomo YAML, Base64-encoded YAML, or a supported plain/Base64
  proxy link list. Genuine HTML pages and malformed or unsupported formats are rejected.
- Vela does not silently install an older App over a newer data schema. Follow the
  documented backup, export, last known-good official installer, and recovery flow before
  a manual downgrade.
- The immutable Factory Core is pinned to Mihomo v1.19.29 for the V1 release line. Use a
  compatible, unblocked Core from the signed Vela Core Catalog when one is available.
- SSID-triggered automatic Scenes are not enabled in this RC. A future gated
  implementation would require Location permission before macOS exposes the current Wi-Fi
  name; this build performs no SSID matching.
- Crash and support diagnostics stay local until you explicitly export and share a redacted
  Support Bundle; Vela does not upload them automatically.
- Beta and RC builds are prerelease software and may contain unresolved non-stop-ship
  regressions. Keep a current backup and, if available, retain your last known-good official
  installer; use Stable for production-critical networking.
