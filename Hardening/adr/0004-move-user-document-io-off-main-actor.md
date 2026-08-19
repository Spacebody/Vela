# ADR: Move user document IO off MainActor

- Status: Accepted
- Baseline SHA256: 64e34b4bddba6bf1d76561b96f8a3f0968b69390924f6ba4d3c5c6dca2a3a8c9
- Current SHA256: 61155273b0dfe7e471013f2266f96a85b7699ad4f47ac502801a1531fc5b7094
- Security owner: Vela Security Engineering
- Release owner: Vela Release Engineering

## Change

Add two internal, feature-owned actors for user-selected document IO. The Settings
coordinator serializes backup encoding, atomic private writes, reads, and validated
decoding. The Configuration writer serializes YAML encoding and atomic private writes.
AppKit panels and authoritative UI-facing state mutation remain on MainActor.

The generated architecture manifest changes only because the two production Swift
source paths increase the scanned file count from 306 to 308. Its security-signal,
filesystem-literal and URL-literal fingerprints are unchanged.

## Security impact

No entitlement, listener, XPC method, privileged command, remote endpoint, trust root,
or public contract is added. Both exported document types use atomic writes followed by
`0600` permissions because settings backups and runnable configurations can contain
sensitive subscription or proxy material. Settings imports retain the existing 1 MiB
limit, schema validation, runtime barriers, verified commit, and compensation behavior.

## Compatibility

The JSON schema, YAML contents, save-panel interaction, error presentation, settings
transaction, and configuration transaction contracts are unchanged. Files written by
this version remain readable by the existing decoders. The only observable filesystem
change is stricter private permissions for exported configuration YAML.

## Tests

Focused Swift tests cover Settings backup round-trip through real files, `0600`
permissions, the file-based 1 MiB rejection path, Configuration UTF-8 preservation,
private permissions, and MainActor responsiveness during an approximately 8 MB export.
Run the existing architecture, Hardening, workflow, build, and Swift test gates before
accepting this batch.

## Review

Vela Security Engineering accepts the unchanged attack surface and the stricter export
permissions. Vela Release Engineering accepts the two bounded internal source additions
and requires the generated freeze, focused tests, and all existing Hardening gates to
remain green.
