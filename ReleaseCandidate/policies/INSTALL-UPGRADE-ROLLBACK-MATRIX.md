# V1 install, upgrade, repair, uninstall, and downgrade matrix

This policy turns the scenario inventory in V0.9 pack documents 09, 18, 21,
and 22 into a closed machine-readable gate. The authoritative manifest is
`config/installation-matrix.json`; case IDs may not be added, removed,
renamed, duplicated, or moved between phases without reviewed release-policy
change control.

## Exact case inventory

Clean install:

- `clean.standard.no-old-data`, `clean.admin.no-old-data`, `clean.old-data-only`
- `clean.helper-absent`, `clean.helper-registered`
- `clean.cli-absent`, `clean.cli-broken`
- `clean.factory-core`
- `clean.no-configuration`, `clean.local-configuration`, `clean.remote-configuration`
- `clean.applications-location`, `clean.downloads-translocated`, `clean.read-only-dmg`

Upgrade:

- `upgrade.fixture-v0.1` through `upgrade.fixture-v0.8`
- `upgrade.stable-to-rc`, `upgrade.beta-to-rc`, `upgrade.rc1-to-rc2`, `upgrade.rc-to-1.0`
- `upgrade.tun-off`, `upgrade.tun-on`, `upgrade.system-proxy-on`
- `upgrade.helper-old`, `upgrade.helper-current`, `upgrade.cli-old`, `upgrade.cli-current`
- `upgrade.external-core-active`, `upgrade.blocked-core`, `upgrade.automatic-scenes`
- `upgrade.incomplete-journals`, `upgrade.low-disk`, `upgrade.sparkle-offline`

Repair:

- `repair.helper-reinstall`, `repair.cli`, `repair.support-bundle`, `repair.safe-mode`
- `repair.profile-restore`, `repair.update-journal`, `repair.factory-core-fallback`, `repair.data-export`

Uninstall:

- `uninstall.tun-stop-cleanup`, `uninstall.helper-unregister`, `uninstall.cli-symlink-removal`
- `uninstall.optional-user-data-removal`, `uninstall.no-unknown-process-network-deletion`
- `uninstall.retained-data-policy`

Downgrade:

- `downgrade.no-silent-downgrade`
- `downgrade.manual-previous-stable-schema-guard`
- `downgrade.backup-export-instructions`
- `downgrade.helper-core-compatibility-warning`
- `downgrade.no-write-compatibility-promise`

## Evidence and candidate binding

Only `passed` cases may carry evidence, and every passed case must carry at
least one normalized relative path and nonzero lowercase SHA-256. Verification
resolves those paths beneath a protected evidence root, rejects every symlink,
and compares exact bytes. Pending, failed, and `blockedAbsentSurface` cases
must have an empty evidence array.

The checked-in manifest is intentionally structural No-Go: candidate identity
and artifact are null. A protected candidate-stage packet binds the exact
logical version, monotonic build, and source commit, but keeps `artifact=null`
and every case pending or blocked so it cannot claim that an unbuilt candidate
was tested. The final matrix is executed against the exported, signed,
notarized DMG. Promotion requires every case `passed`, `decision=go`, no
blockers, and an exact artifact record containing:

```text
kind=dmg
filename=Vela-<candidate-version>-arm64.dmg
sha256=<nonzero lowercase SHA-256>
size=<positive exact byte count>
```

Final verification reopens that exact non-symlink file under the supplied
artifact directory and compares both size and SHA-256. Evidence produced for a
different build, commit, candidate version, or DMG is invalid.

## Absent surfaces and rollback safety

The public contract currently marks production CLI, Automation, and Scene
Store surfaces absent. All CLI and automatic-Scenes cases therefore remain
`blockedAbsentSurface`; replacing that status with `passed` or `pending` is a
false release claim. Conversely, the validator rejects an absent-surface block
after the corresponding public contract surfaces are actually present.

Vela never silently downgrades. A manual previous-Stable recovery must retain
the newer-schema write guard, instruct backup/export first, warn about
Helper/Core compatibility, and make no promise that an older App can safely
write newer data. Uninstall evidence must prove bounded cleanup: it may remove
only Vela-owned TUN, Helper, CLI, and optionally user-selected data, never an
unknown PID, route, or interface. Taken together, the uninstall cases must also
prove that no Vela-owned runtime residue remains; deliberately retained user
data must match the documented retention policy.
