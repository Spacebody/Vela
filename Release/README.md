# Vela release engineering

This directory contains the repository-side V1.0 release-candidate pipeline,
V0.8 hardening gates, V0.7 App release gates, and V0.6 signed-Core lifecycle
gates. It is safe to
run the default dry-run from a dirty development checkout:

```bash
./Release/scripts/release.sh --dry-run
```

Dry-run validates configuration, tool availability, dependency locks, and the
release scripts. It does not archive, sign, notarize, staple, generate an
appcast, or publish anything.

A production release is deliberately fail-closed. It requires all of the
following:

- a clean checkout at the exact requested tag;
- the configured Apple Silicon/Xcode toolchain;
- exact Sparkle 2.9.4 and Yams 6.2.2 package pins;
- a non-placeholder HTTPS feed and a valid Sparkle public Ed25519 key;
- a Developer ID Application identity for the configured Team ID;
- a `notarytool` Keychain profile and Sparkle signing tools in a protected
  release account;
- the implemented V0.7 App bundle integrations, including the bundled release
  manifest, Sparkle nested services, Helper, and Mihomo; the absent production
  CLI and App Intents remain explicit Stop-Ships rather than claimed components;
- a signed exact `v1.0.0-rc.N` or `v1.0.0` tag selected as the workflow ref;
- immutable published-build history plus reviewed migration, audit, support,
  and candidate-bound pre-artifact Go/No-Go manifests;
- an immutable `prior-appcast.xml` snapshot plus its independently reviewed
  lowercase SHA-256, and every historical archive/release-note byte referenced
  by that feed;
- explicit `VELA_RELEASE_EXECUTE=YES` plus `--execute`.

The release entrypoint is explicitly two phase and produces artifacts locally only.
`--stage-candidate` builds/signs/notarizes once, seals the App ZIP and complete
xcarchive ZIP, and atomically writes an immutable protected candidate directory while
the decision remains No-Go. After the exact DMG completes soak and the 58-case
installation matrix, `--promote-candidate` reopens and verifies those same bytes; it
does not rebuild or resign. Publishing is a separate, reviewed operation so a partial
upload cannot silently become a release. Run `./Release/scripts/release.sh --help` for
the complete phase-specific evidence arguments.

Candidate-stage, protected-evidence, staging, and public-output roots must be pairwise
non-overlapping. A typical protected layout uses `/protected/candidates` for immutable
candidate stages and `/protected/evidence` for later decisions; neither belongs below
`Release/staging` or `Release/output`. The candidate-stage parent and promotion-output
root must already exist, be owned by the release user, and have mode `0700`.

The requested version/build must equal the committed Release settings and generated
architecture freeze. A workflow input cannot silently override the tagged source
identity. Candidate and final output directories use macOS `RENAME_EXCL`; an output
that appears concurrently is rejected rather than treated as a directory container.
The exclusive rename is anchored to already-open source and destination parent
directory descriptors, so a path-parent rebinding cannot redirect publication.

`Release/scripts/embed_release_resources.py` is the App target's Release-only
build-phase entrypoint. The build phase must invoke it directly and declare the
inputs documented at the top of that script. It runs only when both
`VELA_RELEASE_MANIFEST_REQUIRED=YES` and `VELA_RELEASE_MANIFEST_PATH` are set,
then copies the strict nine-key bundle manifest and the repository's exact
Sparkle/Yams licenses and third-party notices into:

```text
Contents/Resources/VelaReleaseManifest.json
Contents/Resources/ThirdParty/Sparkle/LICENSE
Contents/Resources/ThirdParty/Yams/LICENSE
Contents/Resources/ThirdParty/THIRD_PARTY_NOTICES.md
```

The production release entrypoint supplies the manifest flag/path, feed URL,
Sparkle public key, channel, and prerelease label as explicit archive build
settings. It also stamps `VelaReleaseManifestRequired=YES` into the signed App
Info.plist, so runtime recovery remains fail-closed if the manifest is missing
or invalid. Ordinary Debug and local Release builds stamp `NO` and do not
receive production update metadata; if a manifest is present anyway, runtime
recovery still validates it.

The bundled `VelaReleaseManifest.json` intentionally remains the App reader's
strict nine-key schema. The separate external release manifest records
`source.architectureFreezeSHA256`, calculated from the exact bytes of
`Hardening/config/architecture-freeze.json`. External verification requires a
lowercase SHA-256 and compares it with that approved file, so an architecture
baseline change cannot reuse an older release manifest.

V0.7 documentation acceptance is deliberately split at the packaging boundary:

```bash
SOURCE_DATE_EPOCH=1783987200 \
  python3 Release/scripts/validate_v07_acceptance.py --source \
    --repository-root . --config Release/config/documentation.json \
    --app-version 1.0.0 --app-build 2026071403

python3 Release/scripts/validate_v07_acceptance.py \
  --archive /path/to/Vela.app --repository-root . \
  --config Release/config/documentation.json \
  --app-version 1.0.0 --app-build 2026071403
```

The protected workflow runs source acceptance before creating credentials.
The existing bundle verifier runs archive acceptance after export. The source
gate rebuilds Help hashes/search indexes in memory and compares exact bytes,
validates bilingual catalog/policy parity and placeholders, requires a reviewed
private security contact and Privacy manifest audit, and verifies the
deterministic `VelaDocumentationManifest.json`. The archive gate rechecks App
version/build, compiled localization tables, preserved Help/Policies hierarchy,
Privacy structure, and every embedded documentation hash. The configured
`securityContact`, privacy review fields, and the existing CLI/Automation/Scene
compatibility `null` values remain intentional stop-ship markers until the
underlying work is genuinely reviewed or implemented.

The protected GitHub environment must provide these release credentials:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`;
- `NOTARY_API_KEY_P8_BASE64`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID`;
- `SPARKLE_ED25519_PRIVATE_KEY` containing the Base64 text exported by
  Sparkle's `generate_keys -x` command (do not Base64-decode it in CI);
- `DEVELOPER_ID_APPLICATION_IDENTITY` and `SPARKLE_2_9_4_BIN` as protected
  environment variables;
- `VELA_RELEASE_RUNNER_NAME`, set to the one protected release runner that owns the
  durable candidate, evidence, and promotion roots.

The workflow decodes credentials only beneath `runner.temp`, imports the P12
and Notary profile into a job-specific Keychain, restricts the Keychain search
list to that file, and passes the Sparkle private key through an explicit 0600
temporary file. The credential cleanup step runs with `if: always()`, restores
the runner's original Keychain search list, deletes the ephemeral Keychain,
and removes every temporary private-key file. Release scripts reject login or
system Keychains, implicit signing-identity discovery, Sparkle's default
Keychain lookup, and secret files outside `RUNNER_TEMP`/`TMPDIR`.

Promotion preparation and GitHub attestation intentionally use separate jobs so only
the latter receives OIDC and attestation-write permissions. Both jobs compare
`RUNNER_NAME` with the protected `VELA_RELEASE_RUNNER_NAME`, and the attestation job
also compares it with the exact runner identity exported by the preparation job. This
fail-closed binding is required because the promotion output is durable machine-local
state rather than a mutable workflow artifact. Configure only that runner with the
`vela-release` label; a runner pool behind that label is unsupported for this workflow.

Generated data lives under `Release/staging/` and `Release/output/`; both are
ignored by Git. Public and private artifacts are separated under each release
output. The private directory contains the sealed complete xcarchive ZIP, App ZIP,
dSYM inventory, candidate-stage receipt, and notarization receipts and must not be
uploaded to the public update host. Framework symlinks are allowed only inside the
App/xcarchive container and must resolve inside that same container; control evidence
paths remain regular non-symlink files.

The dSYM inventory is a UUID-binding receipt, not a directory listing. It uses the
fixed `/usr/bin/dwarfdump` for the archived Vela executable and embedded VelaHelper,
and for the CLI only when the frozen public contract declares a production CLI present.
Every published Mach-O UUID must have exactly one matching dSYM UUID, with both binary
and DWARF hashes retained. The current contract freezes the CLI absent, so an absent CLI
is recorded explicitly; a bundled CLI or synthetic `vela.dSYM` fails closed. Candidate
creation and promotion both revalidate the receipt against the xcarchive.

The protected build ledger is mode `0600`, atomically locked, and never reuses a build
number. A failed or cancelled candidate-stage workflow finalizes its allocation as
`failed`. If runner termination prevents cleanup, a release operator must consume the
exact still-`allocated` row before retrying with a higher build:

```bash
python3 ReleaseCandidate/scripts/manage_build_ledger.py \
  --ledger /protected/evidence/published-builds.json finalize \
  --version 1.0.0-rc.1 --build YYYYMMDDNN --channel rc --status failed
```

For V1, the public candidate directory is a fixed recursive inventory. It
contains the DMG, appcast, external release manifest, SBOM, release notes,
contract and architecture freezes, documentation and Privacy manifests,
migration/public-audit-summary/limitations/support evidence, artifact checksums,
the pending-external RC manifest, and a non-promotional
readiness report. `checksums.txt` covers every public file except itself; the
release job rejects symlinks, unhashed extras, missing entries, and changed
bytes before and after GitHub attestations.

The protected workflow requires GitHub CLI 2.93.0 or newer and creates provenance attestations for the complete
checksum subject set and the checksum file, plus an SPDX SBOM attestation for
the DMG. It then runs `gh attestation verify` against a private snapshot bound
to the exact repository, signed tag, source commit, and release workflow, seals the
returned signed attestations as an immutable JSONL bundle, seals the explicit GitHub
trusted-root JSONL, and replays every check offline with
`--bundle --custom-trusted-root`. Both online verification and the token-free offline
replay use fresh HOME/config directories; persistent credentials and configuration are
excluded. Final promotion repeats that replay from `O_NOFOLLOW` snapshots whose hashes
must equal the canonical bundle and trusted-root bindings; the plain report is never a
trust substitute. The mode-`0600` bundle, trusted root, and verification record remain
durable only under the release-user-owned mode-`0700` evidence root's `private` child.
They are not copied into or appended to the sealed promotion output and do not rewrite
the already attested candidate. A final accountable Go/No-Go and promotion record remain
separate external decisions; the workflow never interprets a
`pendingExternal` manifest as permission to publish.

Appcast history is treated as signed evidence, not merely as input data. Before
Sparkle updates the feed, the release script checks the reviewed snapshot hash,
cryptographically verifies its embedded feed signature, and verifies every
referenced historical DMG and signed release-note file against the item-level
Ed25519 signature and length. It then asks Sparkle to generate only the exact
new `CFBundleVersion`, assigns `beta` only to RC items, and repeats both feed and
artifact verification after generation. The signed Markdown that the appcast
actually names is copied byte-for-byte into the public root and included in the
final checksum inventory; the nested human-readable notes copy is retained
separately. The complete audit closure and candidate-bound Go/No-Go packet
remain protected private evidence. Only the closure's path-and-SHA-bound
`audit-summary.md` and controlled gate statuses derived from the private
decision are eligible for public staging.

The scripts under the V0.5 through V0.9 documentation packs are
reference material. The scripts in this directory add repository-specific path
checks, immutable output rules, retained notarization receipts, stricter
nested-code validation, and dry-run/execute separation.

Security-sensitive upstream references:

- Sparkle publishing and signed-feed guidance:
  <https://sparkle-project.org/documentation/publishing/>
- Sparkle configuration keys:
  <https://sparkle-project.org/documentation/customization/>
- Apple notarization guidance:
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
