# ADR: Record the V0.8 architecture freeze baseline

- Status: BaselineRecorded
- Baseline SHA256: absent
- Current SHA256: 0dbdbb90c16a9ea2950741adfade3d08b44961c4f04f8c4ecadbe94986971e52
- Security owner: unassigned
- Release owner: unassigned

## Change

Record the production source as it exists at the start of V0.8. This ADR does not
authorize a code or architecture change. The generator records Helper protocol v2 with
19 RPC methods, Helper 0.6.0, Mihomo v1.19.28, Sparkle 2.9.4, fixed user/root storage
roots, and the current endpoint categories.

It deliberately records the production CLI, Automation Socket, App Intents, and Scene
Store as absent instead of copying the aspirational V0.4/V0.8 fixture values.

## Security impact

No new entry point, privilege, secret, persistence, network category, trust root, or
recovery behavior is introduced. The baseline exposes two pre-existing release blockers:
the production Sparkle public key/feed and Core Catalog keyring/endpoints are not
provisioned in source.

## Compatibility

This is a read-only inventory. App, Helper, Core, update, profile, configuration, and
journal schema values are generated from their production declarations. Null
CLI/Automation/Scene compatibility remains null.

## Tests

The generator is deterministic, the semantic validator re-generates from source, the
attack-surface file binds the architecture SHA, and the script self-tests cover stale
baselines and unapproved changes. No TUN, route, proxy, Helper, or user data is touched.

## Review

This records an engineering baseline only. Security and Release owner approval remains a
Public Beta Stop-Ship item; future architecture changes require an `Accepted` ADR with
named owners and matching before/after hashes.
