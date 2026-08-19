# Vela V0.8 external security audit packet source

This directory is the reviewable source for an audit packet. It is not a claim that an
external audit, release artifact, SBOM, signature, notarization, or attestation exists.
`Hardening/scripts/generate_audit_packet.py` creates an integrity-indexed packet only from
a clean, exact signed tag and explicit artifact, release-manifest, and SBOM files. Verify
every payload with `verify_audit_packet.py`; archive custody, not a writable directory,
provides operational immutability.

The architecture and attack surface are generated from production source. In particular,
the current baseline has Helper protocol v2 and 19 RPC methods plus the production
SceneStore schema v1, while production CLI, Automation Socket, and App Intents remain absent. Do not replace those nulls
with pack fixtures.

Audit material includes:

- exact scope and eventual artifact hashes;
- architecture, data flows, privilege inventory, and attack surface;
- XPC protocol and schema sources;
- historical and refreshed threat models/security plans;
- test and synthetic fuzz-corpus instructions;
- build/cleanup instructions;
- known limitations and Stop-Ship status;
- a strict finding template.

Production private keys, real subscriptions, user configurations, credentials, raw user
logs, and signing secrets must never be included.
