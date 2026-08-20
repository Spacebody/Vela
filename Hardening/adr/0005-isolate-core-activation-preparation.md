# ADR: Isolate Core activation preparation

- Status: Accepted
- Baseline SHA256: 61155273b0dfe7e471013f2266f96a85b7699ad4f47ac502801a1531fc5b7094
- Current SHA256: 8db901a1e4f5a385d99811d7abdf604450ae16c43f696505fad23d6bab885400
- Security owner: Vela Security Engineering
- Release owner: Vela Release Engineering

## Change

Extract the candidate-resolution, prevalidation, backend-selection and runtime-snapshot
preparation phase from `CoreLifecycleController.activate` into one private helper and a
private immutable preparation value. The controller remains the sole public workflow
facade. Journal creation, durable Core selection, runtime start, health proof, probation,
commit, cancellation and rollback retain their existing order and owners.

The generated architecture manifest changes only in the security-signal fingerprint
because the same activation safety checks now reside in a named private preparation
phase. The production source list, filesystem literals, URL literals and generated attack
surface entries are unchanged.

## Security impact

No entitlement, listener, XPC method, privileged command, endpoint, trust root, secret,
storage path or public contract is added. Candidate catalogue trust, installed-binary
preflight, privileged-store parity, helper policy, durable journal and rollback checks are
preserved. Preparation still completes before the activation journal and destructive
runtime mutation begin, and the runtime-running snapshot is captured at the same point as
before the extraction.

## Compatibility

The public activation API, CoreStore schema, activation journal schema, runtime snapshot,
Helper contract and error presentation are unchanged. Same-Core activation remains a
no-op with awaited mutation-lease release. Existing cancellation, rollback and probation
semantics are retained.

## Tests

`CoreLifecycleControllerTests` passes all seven controller-level cases covering same-Core
and failed-activation lease release, cancellation rollback and journal cleanup, rollback
failure retention, candidate health failure restoration and healthy probation commit.
Run the architecture, Hardening, workflow, static CI and unsigned Release build gates
before accepting this batch.

## Review

Vela Security Engineering accepts the unchanged trust and privileged boundaries and the
more explicit pre-mutation validation phase. Vela Release Engineering accepts the bounded
internal refactor while requiring the generated freeze and all existing fail-closed gates
to remain green.
