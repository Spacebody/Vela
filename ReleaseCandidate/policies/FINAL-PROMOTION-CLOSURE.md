# Final promotion closure

Promotion closes only through `scripts/generate_promotion_closure.py`. The gate
consumes protected external evidence produced after the tagged candidate was
built; it never rewrites the tagged checkout, the immutable RC manifest, or a
public artifact.

## Typed inputs

The gate requires all of the following real, non-symlink inputs:

- the final Go/No-Go packet;
- the final 58-case installation matrix;
- the private candidate-stage evidence receipt;
- the immutable public RC manifest and every file it records;
- the GitHub CLI attestation-verification report;
- the immutable offline GitHub attestation JSONL bundle;
- the immutable GitHub attestation trusted-root JSONL used for offline replay; and
- the checksum inventory that was itself verified by GitHub CLI.

Candidate-stage records are resolved against a dedicated immutable stage root;
final matrix, decision, and attestation records are resolved against the separate
promotion evidence root. This preserves the original candidate receipt and avoids
interpreting its relative paths in a later evidence directory. Safety checks follow
only consumed receipt/file paths and do not reject legitimate internal framework
symlinks inside a signed App or archive that is not itself being treated as JSON
evidence.

The promotion-evidence root and its `private` child must both be canonical,
release-user-owned directories with exact mode `0700`. The candidate-stage,
promotion-evidence, and public-artifact roots are required to be
pairwise non-overlapping. The private closure output is the only intentional child: it
must be a new file under `<evidence-root>/private`, and therefore can never reside under
the candidate-stage or public-artifact root.

The candidate version, monotonic build, source commit, tag, architecture freeze,
signing certificate, and final DMG identity are cross-checked instead of trusted
from a single JSON field. The DMG identity is its exact
`filename + size + SHA-256` tuple. Candidate-stage evidence must reopen the same
DMG and its retained App/archive/notary receipts. The installation matrix must
reopen that DMG and all 58 case-evidence files.

The final Go/No-Go decision must be `go`, contain exactly ten passed gates and
the six accountable approval roles, and every approval must bind the same
version, build, commit, and DMG SHA-256. Its `installation` gate may reference
only the exact final matrix file. Its `artifact` gate may reference only the
exact attestation-verification report. A generic evidence hash is not a typed
substitute for either proof.

Time is part of the closure contract. The attestation verification must precede or equal
each of the six approvals, and every approval must precede or equal closure creation:
`verifiedAt <= approvedAt <= closedAt`. A future `verifiedAt` or `approvedAt` is rejected.

The attestation report must validate against its fixed schema and bind
`Spacebody/Vela`, the protected release workflow, exact source tag and commit,
the exact RC manifest, the exact DMG, the public checksum artifact, and every
other public record named by the RC manifest. The separately attested subject
checksum inventory, offline bundle, and custom trusted root are reopened and matched by
filename, size, and SHA-256. These JSON/hash bindings are not treated as proof. The
closure itself requires GitHub CLI 2.93.0 or newer and runs
`gh attestation verify --bundle --custom-trusted-root` in a fresh HOME/config
environment with every API token and persistent credential excluded. It first copies
the bundle and trusted root through `O_NOFOLLOW` descriptors into private immutable
snapshots, requires their SHA-256 values to equal the closure's canonical bindings,
and rechecks the originals after replay. Verification binds the repository, workflow,
signer digest, source digest, and exact tag while replaying SLSA provenance for the
checksum inventory and every subject plus the DMG's SPDX predicate. If the verifier is
absent or too old, the bundle/trusted root is invalid or changes, or any subject is not
covered, closure fails.

## Private immutable output

Successful closure creates one schema-validated `promotionClosure` JSON file
under `<evidence-root>/private`. Creation is atomic, mode `0600`, and refuses to
overwrite an existing path. The output contains only candidate identity,
cryptographic records, gate/approval inventories, and typed bindings; it does
not copy approval names, private findings, decision prose, or other sensitive
evidence. It must never be placed in the public artifact directory or release
assets.

The attestation bundle, custom trusted root, and verification report remain separate,
durable mode-`0600` records at their canonical paths under
`<evidence-root>/private`. They are never copied into, appended to, or otherwise used to
mutate the sealed promotion output; the closure only binds and consumes those exact
retained files.

Tracked structural readiness remains truthful for the tagged source and is not
edited after build. Post-build installation, attestation, and accountable final
approval are represented by the protected external inputs and this private
closure, not by mutating repository baselines.
