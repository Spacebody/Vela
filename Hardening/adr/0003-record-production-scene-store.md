# ADR: Record the production SceneStore in release contracts

- Status: Accepted
- Baseline SHA256: 78180377556e3b1dc243ba39c9849d11240d666da5117eda7a1f8b8f4f4d9a5d
- Current SHA256: 64e34b4bddba6bf1d76561b96f8a3f0968b69390924f6ba4d3c5c6dca2a3a8c9
- Security owner: Vela Security Engineering
- Release owner: Vela Release Engineering

## Change

Correct the generated architecture and public-contract inventories to record the
production `SceneStore`, its schema version 1, and automatic Scene evaluation.
Production composition constructs `SceneStore` and `SceneFeatureController`, while
application bootstrap starts automatic evaluation after recovery permits automatic
services. The previous freeze incorrectly described that compiled production surface
as absent.

The regeneration also records the current complete production-source fingerprint.
CLI, App Intents, and the external Automation protocol remain explicitly absent.

## Security impact

This is a truthful inventory correction, not a new privileged or externally reachable
surface. Scene data remains in the existing app-owned persistence boundary, is decoded
against schema version 1, and is validated before atomic persistence. Automatic Scene
evaluation consumes the existing bounded engine lifecycle event stream; no listener,
socket, XPC method, entitlement, command execution path, remote upload, or trust root is
added.

The Stop-Ship predicate is tightened from an all-surfaces-missing conjunction to an
independent check of every required surface. As a result, implementing one requirement
cannot accidentally hide another missing requirement. App Intents are now included in
that check.

## Compatibility

Existing Scene documents already use schema version 1, so no data migration or public
API change is introduced. Automatic Scene installation and migration matrix entries
move from `blockedAbsentSurface` to `pending` until candidate-bound evidence exists.
CLI-related entries remain blocked, and SSID matching remains an explicitly documented
limitation even though non-SSID Scene evaluation is present.

## Tests

The architecture generator now proves `SceneStoreDocument.currentSchemaVersion`
directly from production Swift source. Architecture, contract, installation-matrix,
migration, and release-candidate tests cover the corrected inventory. Hardening tests
also prove that any one missing required surface keeps the release blocker active.

Run the existing architecture, Hardening, ReleaseCandidate, contract, build, and Swift
test gates before accepting this batch.

## Review

Vela Security Engineering accepts the corrected non-networked Scene persistence and
evaluation inventory and the stricter fail-closed release predicate. Vela Release
Engineering accepts the schema and matrix status correction while retaining all
unfulfilled release requirements as Stop-Ship or pending evidence.
