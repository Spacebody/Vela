# Vela Core Compatibility Lab

This directory is the executable compatibility gate for Vela's signed Mihomo
Core releases. It uses only repository-owned fixtures and temporary runtime
directories; it never reads a user's Vela profiles or controller data.

The local harness validates the exact Core version, the configuration corpus,
the v1.19.28 REST/WebSocket contract, twenty user-backend transitions, a
candidate-to-factory rollback, and relative performance measurements. System
Proxy, privileged TUN, sleep/wake, and network-switch checks must come from a
dedicated Apple Silicon test Mac through a reviewed evidence file.

Missing privileged evidence is a test failure, not a skip. A report can say
`passed` only when every required suite-v1 test passed. Production release
validation additionally checks unsigned-payload/candidate/factory hashes and the hashes of the
matrix, corpus manifest, API contract, and dedicated-host evidence. The report
is then embedded in the Developer-ID-signed Core bundle and its exact SHA-256
is included in the raw-byte-signed Core Catalog.

Local deterministic contract tests:

```bash
./Release/Core/CompatibilityLab/test_compatibility_lab.sh
```

Run the non-privileged live lab against the checked-in Factory binary (this is
development evidence only and intentionally produces a failed report because
candidate and Factory are identical and dedicated-host evidence is absent):

```bash
./Release/Core/run_core_compatibility.sh \
  --candidate-executable Vendor/Mihomo/bin/mihomo \
  --upstream-payload Vendor/Mihomo/bin/mihomo \
  --factory-executable Vendor/Mihomo/bin/mihomo \
  --core-id v1.19.28-r1 \
  --output /tmp/vela-compatibility.json
```

Production Compatibility Lab use executes the exact unsigned upstream payload
as both `--candidate-executable` and `--upstream-payload`; the validator requires
their SHA-256 values to be identical and requires that payload to differ from
the Factory baseline. Developer ID signing happens only after this functional
gate. The post-notarization identity and signed Catalog file index separately
bind the final signed executable, avoiding a report that would need to hash a
bundle containing itself. Dedicated-host evidence and independent performance
review must name the same candidate/Factory pair. The output path must not
already exist.

The shared `VelaCoreCompatibility` Xcode scheme and the live lab can be run as
one gate with:

```bash
./Release/Core/CompatibilityLab/run_compatibility_harness.sh \
  CANDIDATE_BUNDLE UNSIGNED_UPSTREAM_MIHOMO FACTORY_MIHOMO OUTPUT_REPORT \
  DEDICATED_HOST_EVIDENCE PERFORMANCE_REVIEW
```
