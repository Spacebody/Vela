# Vela Release Candidate gates

`ReleaseCandidate` contains the repository-side V1.0 release-candidate gates. It does
not make the current checkout release-ready. Machine-readable truth lives in `config/`;
the committed state remains `noGo` until real, reviewable evidence replaces every
pending gate.

The App and Sparkle contracts remain unchanged: RC builds use the existing `beta`
update channel with a `rc.N` prerelease label. The separate RC manifest uses the
logical candidate identity `1.0.0-rc.N` and channel `rc`. V1.0 Stable is rebuilt with a
higher build number, the `stable` App channel, and tag `v1.0.0`.

Development structural check:

```sh
ReleaseCandidate/scripts/preflight.sh
```

This validates schemas and the truthful No-Go state and exits successfully when that
state is internally consistent. It never reports Go.

Protected candidate-stage preflight (before build reservation or secrets):

```sh
ReleaseCandidate/scripts/preflight.sh \
  --version 1.0.0 \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --tag v1.0.0-rc.1 \
  --channel rc \
  --evidence-dir /protected/evidence \
  --audit /protected/evidence/audit-closure.json \
  --installation-matrix /protected/evidence/installation-matrix.json \
  --go-no-go /protected/evidence/go-no-go.json \
  --published-builds /protected/evidence/published-builds.json \
  --support-matrix /protected/evidence/support-matrix.json \
  --candidate-stage
```

Protected preflight is fail-closed: it requires a clean exact tag; a monotonic build
that exactly matches every committed Xcode Release product and the generated
architecture freeze; approved contract/freeze data; passed migration and audit closure;
a complete Go packet;
and no forbidden release-candidate source patterns. It must run before release secrets
are created. Candidate-specific audit and Go/No-Go packets must be immutable external
evidence created after the tag; putting `HEAD` into a tracked packet would create an
impossible commit self-reference. Checked-in packets intentionally remain No-Go
baselines. Gate and audit references are safe paths relative to `--evidence-dir` and are
verified by SHA-256. Optional `--migration`, `--published-builds`, and `--support-matrix`
select other protected evidence inventories. The candidate-stage installation matrix is
required external evidence because it binds the exact candidate version, build, and
commit while truthfully retaining `artifact=null` before the candidate exists.

The complete audit closure is private candidate evidence: it may contain private
finding descriptions, proof paths, owners, and retest details and is never recorded in
the public RC manifest. `generate_rc_manifest.py` additionally requires
`--audit-summary`; that file must exactly match the closure's verified
`publicSummary.path` and `publicSummary.sha256`. The public artifact record is named
`auditSummary`. The readiness report emits only controlled statuses and counts and never
copies free-form audit, migration, or decision text.

Stable uses the same gates with `--channel stable`:

```sh
ReleaseCandidate/scripts/preflight.sh \
  --version 1.0.0 \
  --candidate-version 1.0.0 \
  --build YYYYMMDDNN \
  --tag v1.0.0 \
  --channel stable \
  --evidence-dir /protected/evidence \
  --audit /protected/evidence/audit-closure.json \
  --installation-matrix /protected/evidence/installation-matrix.json \
  --go-no-go /protected/evidence/go-no-go.json \
  --published-builds /protected/evidence/published-builds.json \
  --support-matrix /protected/evidence/support-matrix.json \
  --candidate-stage
```

Stable must have a build greater than every immutable published RC build and uses the
existing Stable update channel. RC uses the Beta App update channel while retaining its
logical `rc.N` candidate identity.

The V1 installation matrix has an exact 58-case inventory covering clean Standard and
Admin installs, V0.1 through V0.8 upgrades, RC transitions, Helper/CLI/Core/TUN/Scenes
states, repair, bounded uninstall, and downgrade safeguards. Structural validation is:

```sh
python3 ReleaseCandidate/scripts/validate_installation_matrix.py \
  ReleaseCandidate/config/installation-matrix.json \
  --allow-pending \
  --public-contract Contracts/v1/public-contract-freeze.json
```

`--allow-pending` is restricted to truthful structural No-Go. Protected preflight uses
the distinct `--candidate-stage` mode: candidate identity must be concrete, every case
must still be pending or `blockedAbsentSurface`, the matrix must remain No-Go, and
`artifact` must be null. This avoids claiming that an unbuilt DMG was tested.

After the final signed and notarized DMG exists, run the matrix on those exact bytes and
validate the promotion packet without either incomplete-mode flag:

```sh
python3 ReleaseCandidate/scripts/validate_installation_matrix.py \
  /protected/evidence/installation-matrix-final.json \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --commit COMMIT \
  --evidence-root /protected/evidence \
  --artifacts-dir /protected/public \
  --public-contract Contracts/v1/public-contract-freeze.json \
  --verify-files
```

Final validation requires all 58 cases passed with hash-verified relative evidence,
`decision=go`, and a `candidate.artifact` record whose filename, size, and SHA-256 match
the exact `Vela-<candidate-version>-arm64.dmg`. Non-passed cases may not carry evidence.
Current CLI and automatic-Scenes cases must remain `blockedAbsentSurface` while those
surfaces remain absent in the public contract, so the current checked-in state cannot be
promoted by replacing missing implementation with fixture claims. The complete policy
and exact IDs are in `policies/INSTALL-UPGRADE-ROLLBACK-MATRIX.md`. Production App
Intents are also absent from the frozen public contract and are therefore an explicit
release-level No-Go enforced by `Release/config/release.json` and its validator.

The promotion preflight consumes the immutable stage rather than rebuilding it:

```sh
ReleaseCandidate/scripts/preflight.sh \
  --version 1.0.0 \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --tag v1.0.0-rc.1 \
  --channel rc \
  --evidence-dir /protected/evidence \
  --audit /protected/evidence/audit-closure.json \
  --installation-matrix /protected/evidence/installation-matrix-final.json \
  --go-no-go /protected/evidence/go-no-go-pre-artifact.json \
  --published-builds /protected/evidence/published-builds.json \
  --support-matrix /protected/evidence/support-matrix.json \
  --promotion --expect-reserved \
  --candidate-stage-path \
    /protected/candidates/candidate-stage-1.0.0-rc.1-YYYYMMDDNN
```

Final promotion is closed by one credential-free, typed evidence gate after the
installation matrix and GitHub attestation verification have completed:

```sh
python3 ReleaseCandidate/scripts/generate_promotion_closure.py \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --commit COMMIT \
  --go-no-go /protected/evidence/private/go-no-go-final.json \
  --installation-matrix /protected/evidence/private/installation-matrix-final.json \
  --candidate-stage-evidence \
    /protected/candidates/candidate-stage-1.0.0-rc.1-YYYYMMDDNN/private/candidate-stage-evidence.json \
  --candidate-stage-root \
    /protected/candidates/candidate-stage-1.0.0-rc.1-YYYYMMDDNN \
  --rc-manifest /protected/public/rc-manifest-1.0.0-rc.1.json \
  --attestation-verification /protected/evidence/private/attestation-verification.json \
  --attestation-bundle /protected/evidence/private/attestation-bundles.jsonl \
  --attestation-trusted-root /protected/evidence/private/attestation-trusted-root.jsonl \
  --subject-checksums /protected/evidence/final-subject-checksums.txt \
  --public-artifacts-dir /protected/public \
  --evidence-root /protected/evidence \
  --output /protected/evidence/private/promotion-closure-1.0.0-rc.1.json
```

The promotion evidence root and its `private` child must already exist, be owned by the
release user, and have exact mode `0700`. The candidate-stage, promotion-evidence, and public-artifact roots must be pairwise
non-overlapping; the private closure output remains strictly below
`evidence-root/private`. The gate reopens every referenced file. It requires one exact candidate and DMG across
the Go packet, 58-case matrix, candidate-stage receipt, RC manifest, and attestation
report; exactly ten passed gates; exactly six candidate-bound approvals; and typed
installation/artifact gate references to the matrix and attestation report. The
attestation subject set must include every RC-manifest public record plus the exact RC
manifest itself, and its separately verified checksum inventory must still match. A
plain verification-result JSON is never trusted: closure reruns
`gh attestation verify --bundle --custom-trusted-root` inside an isolated, token-free
HOME/config environment for the checksum inventory and every subject, including the
DMG's SPDX predicate. The bundle and trusted-root SHA-256 values supplied by the closure
must match the verifier's `O_NOFOLLOW` snapshots before replay, and the original files
are rechecked afterward. It also requires
`verifiedAt <= each of six approvedAt <= closedAt` and rejects future timestamps.
Output is an immutable mode-`0600` private receipt under `evidence-root/private`; it is
never a release asset. See `policies/FINAL-PROMOTION-CLOSURE.md`.

Historical migration fixtures are accepted only when their declared `v0.x`/`v0.x.0`
tag is annotated, signature-valid, resolves to the declared producing commit, and the
fixture checksum matches. Each fixture uses an exact `fixtureMetadata` object containing
`sourceVersion`, `producingTag`, `producingCommit`, `generatorVersion`, and
`fixtureSchemaVersion`; partial provenance on a pending source is rejected.

The lifecycle is deliberately two phase. Protected preflight permits only the current
artifact gate to remain pending; it never claims a not-yet-built DMG passed. The local
immutable RC manifest records `pendingExternal` attestation subjects and pinned workflow
policy. After GitHub's protected workflow attests the DMG, SBOM, and RC manifest, run
`scripts/verify_rc_attestations.sh`; it invokes cryptographic `gh attestation verify`
bound to `Spacebody/Vela`, the exact release workflow, source tag, and source commit.
An embedded JSON claim of `verified` or `notApplicable` is rejected. The post-artifact
verification report and accountable final Go/No-Go record stay outside both the tagged
source and fixed public directory; the verification report is retained as private
release evidence and never rewrites the public inventory it verified.

After the private signed appcast, signed release notes, external release manifest,
SBOM, sealed App ZIP, complete sealed xcarchive, notarization receipts, and dSYM
inventory exist, create the immutable private candidate-stage evidence receipt with
`scripts/generate_candidate_stage_evidence.py`. The generator inventories every file in
the updates directory, cross-checks the external manifest's exact App ZIP, DMG, and
appcast bytes,
and actually invokes the tracked Sparkle artifact-signature verifier. It records only a
controlled verification result tied to the appcast SHA-256; the Sparkle key path and key
material are never serialized. The receipt remains `No-Go` and `promotion=pending`.

Before promotion, run `scripts/validate_candidate_stage_evidence.py --verify-files`
against the same protected evidence root. It rejects changed, added, removed, symlinked,
or escaped artifacts and rebinds the complete updates checksum inventory without
re-signing or requiring the private key. See
[`policies/CANDIDATE-STAGE-EVIDENCE.md`](policies/CANDIDATE-STAGE-EVIDENCE.md) for the
complete command and retention policy.

Attestation verification requires GitHub CLI 2.93.0 or newer. It consumes the fixed final subject inventory, snapshots every
listed file and the checksum inventory itself before invoking GitHub CLI, verifies
ordinary provenance for the inventory and every checksum row, and additionally verifies
the DMG's SPDX 2.3 attestation. It extracts GitHub's signed attestation objects into an
immutable JSONL bundle, obtains and seals the explicit GitHub trusted-root JSONL, then
immediately replays the complete verification with both files and
`--custom-trusted-root` in an isolated environment containing no persistent credential
or GitHub configuration. It rejects every symlink and aborts if an original or snapshot
changes during verification:

```sh
ReleaseCandidate/scripts/verify_rc_attestations.sh \
  --manifest /protected/public/rc-manifest.json \
  --artifacts-dir /protected/public \
  --subject-checksums /protected/evidence/final-subject-checksums.txt \
  --bundle-output /protected/evidence/private/attestation-bundles.jsonl \
  --trusted-root-output /protected/evidence/private/attestation-trusted-root.jsonl \
  --output /protected/evidence/private/attestation-verification.json
```

The bundle, trusted root, and report are durable canonical evidence under that protected
`evidence-root/private` tree. They are mode-`0600`, are never copied into or appended to
the sealed promotion output, and the closure consumes those exact retained paths.

The reference files in `Docs/Vela-v0.9-Release-Candidate-Codex-Pack` are examples only.
They are not production evidence and must never overwrite manifests derived from Vela's
actual source, artifacts, or reviewed lab results.

Published policy is split into `policies/SEMVER-BUILD-SUPPORT.md`,
`policies/RC-BRANCHING.md`, `policies/SUPPORT-V1.md`,
`policies/KNOWN-LIMITATIONS.md`, `policies/INSTALL-UPGRADE-ROLLBACK-MATRIX.md`,
`policies/CANDIDATE-STAGE-EVIDENCE.md`, `policies/FINAL-PROMOTION-CLOSURE.md`, and
`policies/V1-LAUNCH-RUNBOOK.md`.
