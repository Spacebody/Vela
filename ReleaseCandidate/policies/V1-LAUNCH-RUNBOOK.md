# V1 launch runbook

## T-7 days

- Freeze `release/1.0`, select the final RC, begin the real 72-hour soak.
- Close the audit, documentation/localization, support, and previous-Stable gates.
- Keep the full audit closure and private finding evidence in the protected evidence bundle; publish only its hash-bound verified public summary.

## T-2 days

- Assemble the immutable Go/No-Go packet, migration/update matrix, incident drill,
  release notes, limitations, and signed artifact verification. Do not publish.

## T-0

- Build Stable with a build above every RC.
- Run the full protected release pipeline, RC-to-Stable update, clean install, and final
  accountable Go approval.
- Retain the private GitHub attestation JSONL bundle, custom trusted-root JSONL, and
  report at their canonical durable evidence paths. With GitHub CLI 2.93.0 or newer,
  replay `--bundle --custom-trusted-root` in an isolated token-free environment for the
  checksum inventory, every subject, and DMG SPDX predicate. Do not copy these records
  into the sealed promotion output; close only after all six approvals satisfy
  `verifiedAt <= approvedAt <= closedAt`.

## Publish and first 24 hours

Publish immutable artifacts, checksums and signed feed; verify a clean-machine update;
publish notes, documentation, and previous Stable; then monitor downloads and S0/S1
support while freezing nonessential merges.
