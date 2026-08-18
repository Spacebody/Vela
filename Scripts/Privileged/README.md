# Vela privileged validation scripts

These scripts implement the repository-side V0.3 acceptance gates. Static and
inspection commands are read-only with respect to macOS networking, launchd,
and `SMAppService`. They never install or unregister the helper, signal a
process, or change a route/system proxy.

## Safe gates

```bash
./Scripts/Privileged/test-static-integration.sh
./Scripts/Privileged/validate-fixtures.sh
./Scripts/Privileged/verify-launch-daemon.sh
./Scripts/Privileged/check-tun-cleanup.sh
```

Validate an unsigned or ad-hoc build's layout without treating it as suitable
for authenticated XPC:

```bash
./Scripts/Privileged/verify-privileged-bundle.sh \
  --structure-only --static-mihomo /path/to/Vela.app
```

Validate a development-signed bundle and its shared Team ID:

```bash
./Scripts/Privileged/verify-privileged-bundle.sh /path/to/Vela.app
```

`--structure-only` is intentionally a weaker gate. It does not prove that
`setCodeSigningRequirement` can authenticate the App.

## Developer ID and notarization

The distribution gate requires Developer ID signatures, Hardened Runtime,
secure timestamps, matching non-empty Team IDs, and no prohibited entitlement:

```bash
./Scripts/Privileged/verify-privileged-bundle.sh \
  --distribution /path/to/Vela.app
```

`notarize-app.sh` defaults to a local preflight and performs no upload or
stapling. Submission requires both an explicit option and environment opt-in;
credentials remain in a `notarytool` Keychain profile:

```bash
./Scripts/Privileged/notarize-app.sh /path/to/Vela.app

VELA_RUN_NOTARIZATION=1 \
NOTARY_PROFILE=vela-notary \
./Scripts/Privileged/notarize-app.sh --execute /path/to/Vela.app
```

Do not call `--execute` from ordinary unit tests or CI jobs without a protected,
release-only approval gate.

## Real privileged integration tests

The harness refuses to select a fallback target and runs only the dedicated
`VelaPrivilegedIntegrationTests` target. It is disabled unless both opt-ins are
present:

```bash
VELA_RUN_PRIVILEGED_TESTS=1 \
VELA_PRIVILEGED_TESTS_CONFIRM=YES \
./Scripts/Privileged/run-privileged-integration.sh
```

The operator must first register and approve the exact signed Helper through
Vela. The target never registers or unregisters it; it owns only each opted-in
TUN start/stop and bounded runtime cleanup. The harness compares before/after
process, utun, and system-proxy snapshots and fails if they differ. Its final
diagnostic remains read-only; it deliberately contains no `sudo`, `launchctl`,
process-kill, route-delete, or wildcard cleanup fallback.

See `Docs/Vela-v0.3-Privileged-TUN-Acceptance.md` for the complete evidence
matrix and the gates that require a signed artifact or clean test machine.
