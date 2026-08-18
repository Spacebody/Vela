# Architecture freeze ADRs

Any change to `Hardening/config/architecture-freeze.json` must be generated from
production source and accompanied by an accepted ADR. The diff gate requires the
exact SHA-256 of the previous and current canonical manifest, named Security and
Release owners, compatibility analysis, and test evidence. `absent` is valid only
for the one-time initialization baseline.

Copy `0000-template.md`; do not weaken the generator or use an allow-list flag to
make an unreviewed privilege, protocol, trust-root, secret, path, or endpoint change
pass CI.
