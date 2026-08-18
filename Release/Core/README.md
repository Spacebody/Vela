# Vela Signed Core Release Engineering

This directory implements the Vela 0.6 signed Mihomo Core release boundary. It never selects GitHub `latest`, never installs a Core into a running App/Helper store, and never uploads or publishes an artifact automatically.

The checked-in seed fixes Mihomo `v1.19.28`, the exact darwin-arm64 asset, official archive size/SHA-256, tag, commit, source, and GPL license URL. Production values that are not yet provisioned remain `null` in `config/core-release.json`; `validate_core_release_config.py --production` rejects them.

`catalogURL` and `catalogSignaturesURL` are the reviewed production values embedded into the App by `Release/scripts/release.sh`. Both Xcode configurations intentionally default their corresponding build settings to an empty string, which keeps local and unprovisioned builds in the unconfigured state. Production bundle verification compares the built Info.plist values byte-for-byte with this config and rejects missing, placeholder, or divergent endpoints.

## Offline validation

```bash
./Release/Core/test_core_release_tooling.sh
./Release/Core/prepare_core_release.sh --dry-run
./Release/Core/publish_core_release.sh --dry-run
./Release/Core/publish_core_incident.sh --dry-run
```

Dry-run mode performs policy and fixture checks only. It performs no network request, signing, notarization, staging, upload, or publication.

## Compatibility Lab

The deterministic unit/fixture suite is part of `test_core_release_tooling.sh` and can also be run directly:

```bash
./Release/Core/CompatibilityLab/test_compatibility_lab.sh
```

Run the complete macOS harness with a candidate bundle for the Xcode preflight,
the exact unsigned upstream executable used as the Compatibility Lab candidate,
and the currently trusted Factory Core executable:

```bash
./Release/Core/CompatibilityLab/run_compatibility_harness.sh \
  /absolute/path/to/VelaMihomoCore.bundle \
  /absolute/path/to/unsigned-upstream/mihomo \
  /absolute/path/to/factory/mihomo \
  /absolute/path/to/compatibility-report.json \
  /absolute/path/to/dedicated-host-evidence.json \
  /absolute/path/to/performance-review.json
```

The harness exercises the Xcode `VelaCoreCompatibility` scheme, config corpus, REST and WebSocket contracts, user-backend lifecycle/rollback, port collision handling, and the relative performance workload. System Proxy, TUN, sleep/wake, network-change, and rollback observations must be captured on the dedicated release-lab host and referenced by SHA-256. Performance results also require an independent manual review artifact. Missing privileged evidence, review evidence, or an independently versioned Factory Core is a failure, never a skip or an inferred pass.

The Compatibility Lab directly executes the exact unsigned upstream payload.
Production generation and validation require
`candidateExecutableSHA256 == upstreamPayloadSHA256`; this prevents a report for
candidate A from authorizing payload B. `build_core_bundle.sh` checks that
`upstreamPayloadSHA256` equals the fetched executable before signing. After
Developer ID signing and notarization, `signed-core-identity.json` separately
binds the final executable, all seven bundle files, the report, and the retained
unsigned payload. The signed Catalog file index is the public final-bundle
identity. The report deliberately does not contain the hash of the final bundle
that embeds that same report, avoiding a circular hash/signature contract.

Only the report generated for these exact bytes may be entered as
`compatibilityReport` in `config/core-release.json`. Production validation
requires all eleven gates to pass, a dedicated Apple Silicon release-lab host
with no user data, a candidate distinct from Factory, no deviations, checked-in
suite/corpus/API hashes, explicit dedicated-host and performance-review bytes,
and evidence no older than 30 days. The Pack's legacy report remains usable
only by non-production parser fixtures.

## Protected production flow

The `core-ingest.yml` workflow is manual, checks out an exact annotated tag,
verifies its GPG signature against the protected
`RELEASE_TAG_SIGNING_FINGERPRINT`, is protected by the `core-production`
environment, is limited to a self-hosted Apple Silicon release runner, and pins
every GitHub Action to a full commit SHA. The job creates an ephemeral Keychain,
a run-ID/attempt-bound notary profile, and explicit 0600 Catalog key files. It
prepares a signed/notarized bundle, then stages deterministic split files and a
raw-byte Ed25519-signed Catalog. Upstream and prior-Catalog curl calls disable
ambient `.curlrc` configuration.

For Catalog sequence 2 and later, the tagged config also records the highest
prior sequence, fixes that prior Catalog URL to
`baseURL/catalog-history/sequence-N/core-catalog.json`, and records its expected
raw-byte SHA-256. CI accepts no dispatch input for these values:
`acquire_prior_core_catalog.sh` downloads without redirects from that reviewed
HTTPS URL, and `verify_prior_core_catalog.py` binds the bytes to the expected
digest and reviewed prior sequence. Each stage emits the exact top-level
Catalog and signature envelope again under immutable
`catalog-history/sequence-N/`; an existing sequence directory is never
overwritten. New Catalogs preserve every prior entry/tombstone and permit only
explicit status transitions. `blocked` and `withdrawn` require a bounded reason;
`available` and `recommended` forbid one.

Set `catalog.operation` to `incident`, advance the sequence by exactly one, set
the current Core to `blocked` or `withdrawn`, and provide `blockReason` to use
the separate `core-incident.yml` protected workflow. It invokes
`publish_core_incident.sh`, which copies the verified prior entry bytes and
changes only status/reason plus Catalog-level sequence/times. It accepts no
bundle, compatibility report, file index, Developer ID identity, or notary
credential, so an emergency status update cannot accidentally rebuild or
re-sign the current Core. `catalog.operation=full` remains mandatory for normal
ingest.

Production preparation and staging require `VELA_CORE_RELEASE_EXECUTE=YES`; real Developer ID, notary, compatibility, HTTPS origin, sequence/timestamps, public keyring, and independent Core Catalog signing-key inputs are mandatory. Notarization acceptance is recorded from `notarytool`; the tooling never fabricates a receipt or acceptance status.

The Catalog signature is independent of Sparkle EdDSA, Developer ID, notary
credentials, and GitHub credentials. Private key material may only come from an
explicit user-owned 0600 temporary file or a named entry in an explicit
Keychain, and signature tooling never prints the private key or signature
bytes. Normal publication supports one active signature; configured key
rotation requires exactly two different active/next key IDs and signatures over
the same raw Catalog bytes.

Before any private staging cleanup, both protected workflows create and
self-validate a 0600 private evidence ZIP plus canonical manifest. A full
release archive includes the upstream archive and unsigned executable, signed
bundle, final signed identity, accepted notary receipt and log, Compatibility
Lab report/evidence/review, Catalog bytes/signatures/history, file index, SBOM,
and release-machine/toolchain record. GitHub retains a seven-day operational
copy. That copy is not durable retention: provider-specific remote atomic
publication, long-term private evidence storage/credentials, and staging-client
feed integration remain explicit production STOP-SHIP items.
