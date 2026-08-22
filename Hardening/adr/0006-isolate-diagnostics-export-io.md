# ADR: Isolate diagnostics export IO

- Status: Accepted
- Baseline SHA256: 8db901a1e4f5a385d99811d7abdf604450ae16c43f696505fad23d6bab885400
- Current SHA256: 5d00d0a986cf4a6036fe1c3f36d6107e1aa89482b142a77680d165701b194ed1
- Security owner: Vela Security Engineering
- Release owner: Vela Release Engineering

## Change

Add one internal, feature-owned actor that serializes Diagnostics export writes. AppKit
save-panel interaction and authoritative view state remain on MainActor. Encoding and
atomic file IO execute through the actor, and the view owns and cancels its export task
when the Diagnostics page disappears.

The generated architecture manifest changes only because the internal production Swift
source path increases the scanned file count from 308 to 309. The security-signal,
filesystem-literal and URL-literal fingerprints are unchanged. The attack-surface manifest
changes only to bind the new canonical architecture-manifest digest.

## Security impact

No entitlement, listener, XPC method, privileged command, remote endpoint, trust root,
secret category, storage root or public contract is added. Diagnostics exports retain the
existing redaction path. The writer uses an atomic replacement and applies `0600`
permissions so exported reliability evidence and support bundles remain private to the
current user.

## Compatibility

The Diagnostics UI, save-panel destination, filenames, JSON and archive payload bytes,
redaction rules and user-facing error behavior are unchanged. The actor is internal to the
application target and does not expand a cross-target or public API. Existing exports
remain readable by the same tools.

## Tests

Focused Swift tests cover UTF-8 byte preservation, atomic private writes and MainActor
responsiveness during a large export. The Diagnostics view cancels its owned export task
on disappearance. Run the architecture, Hardening, workflow, relevant Xcode, VelaIPC and
unsigned Debug/Release build gates before accepting this batch.

## Review

Vela Security Engineering accepts the unchanged attack surface, retained redaction path
and private output permissions. Vela Release Engineering accepts the bounded internal
source addition while requiring the generated freeze, focused export tests and all
existing fail-closed gates to remain green.
