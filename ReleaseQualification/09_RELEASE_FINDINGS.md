# Release Qualification Findings

Date: 2026-08-22

## RQ-001 — Stale visual production-route test

- Severity: P2 (CI release gate)
- Environment: macOS 26.5.2, Xcode 26.6, unsigned Debug test lane.
- Reproduction: run the full Xcode suite at baseline.
- Expected: current supported production route accepted; unsupported loading route rejected.
- Actual: the test expected now-supported `overview.loadedHealthy` to throw.
- Evidence: focused route test reproduced deterministically.
- Owner: test contract.
- Fix: update only test assertions to current route truth.
- Regression proof: supported and unsupported routes are both asserted; focused suite passes.
- Status: CLOSED.

## RQ-002 — Termination snapshot can omit final Mihomo output

- Severity: P2 (diagnostic correctness)
- Environment: full Xcode suite under concurrent load.
- Reproduction: `MihomoProcessManagerTests.unexpectedExitUpdatesStateAndEmitsCapturedTermination` observed empty termination stdout instead of `final-out`.
- Expected: termination snapshot contains bytes already emitted by the child.
- Actual: readability callback could read bytes before appending while termination drained and snapshotted concurrently.
- Evidence: read and append were separated across the FileHandle callback and mutex-protected buffer; the failure appeared under full-suite scheduling pressure.
- Owner: `MihomoProcessManager` output capture.
- Fix: serialize each FileHandle read and its buffer append through existing `ProcessOutputBuffer` mutex; termination drain uses the same boundary.
- Regression proof: MihomoProcessManager and Core lifecycle suites pass five repeated iterations (95 test executions); final full-gate result is in `10_FINAL_QUALIFICATION.md`.
- Status: FIXED.

## RQ-003 — Core probation rollback test wall-clock budget too narrow under full-suite load

- Severity: P2 (test evidence reliability)
- Environment: full Xcode suite under concurrent load.
- Reproduction: late probation rollback remained transiently `.rollingBack` when the test's five-second polling deadline expired.
- Expected: rollback completes and releases the mutation barrier.
- Actual: full-suite MainActor load delayed completion beyond the test-only deadline; isolated repetitions completed.
- Evidence: no deterministic lifecycle failure under repeated focused execution.
- Owner: test timing budget.
- Fix: increase only the evidence wait budget from 5 to 10 seconds; production lifecycle code unchanged.
- Regression proof: five repeated Core lifecycle suite iterations pass.
- Status: CLOSED.

## RQ-004 — Installed App is not a valid current candidate

- Severity: P1 (release artifact blocker)
- Environment: `/Applications/Vela.app` read-only inspection.
- Reproduction: strict code-sign verification and Gatekeeper assessment.
- Expected: exact SHA, valid nested signatures, Gatekeeper acceptance, release manifest and production endpoints.
- Actual: old bundle, strict verification failure, signing-subsystem assessment error and missing production release configuration.
- Owner: release packaging/credentials.
- Fix: create and qualify an exact signed/notarized candidate after explicit authorization and provisioning.
- Regression proof: signed-host and clean-install checklist.
- Status: OPEN — SIGNING/RELEASE CONFIGURATION GATED.

## RQ-005 — Prior performance fixture process residue

- Severity: P3 (evidence harness hygiene)
- Evidence: a stopped `/private/tmp/VelaPerfFixture.app` process remained before baseline capture.
- Fix: terminate the fixture and record it separately from production Vela.
- Status: CLOSED; no production source change.

## RQ-006 — Qualification host contains stale Vela Helper registration

- Severity: P2 (host-evidence contamination; not attributed to current source).
- Environment: current macOS qualification host before installing the exact candidate.
- Reproduction: read-only `launchctl print system/dev.yilin.Vela.Helper` while `/Library/PrivilegedHelperTools/dev.yilin.Vela.Helper` and `/Library/LaunchDaemons/dev.yilin.Vela.Helper.plist` are absent.
- Expected: a clean dedicated host has no prior Vela Helper authority before candidate installation.
- Actual: ServiceManagement retains an inactive build `2026071403` registration with `spawn failed`, last exit `78: EX_CONFIG`, and 246,544 recorded run attempts.
- Impact: Helper/TUN startup and cleanup observations on this host would be ambiguous and cannot qualify the current candidate.
- Owner: qualification-host preparation / prior local installation, not current production source.
- Fix: use a clean dedicated test Mac, or explicitly authorize removal of the stale registration before installing the exact candidate.
- Regression proof: preflight must show no Vela Helper registration, executable, daemon plist, process, lease or TUN interface before candidate installation.
- Status: OPEN — CLEAN HOST OR EXPLICIT CLEANUP AUTHORIZATION REQUIRED.

## RQ-007 — Current-source archive is signed but unnotarized

- Severity: P1 (release artifact blocker).
- Environment: isolated Release archive for `a353fad1047a190f07821db0c77c52e597aaa556`.
- Reproduction: archive with Developer ID, then run strict nested signature, stapler and Gatekeeper checks.
- Expected: exact production candidate is signed, notarized, stapled and Gatekeeper accepted.
- Actual: App/Helper/nested signatures and Hardened Runtime pass; no ticket is stapled and Gatekeeper reports `Unnotarized Developer ID`.
- Owner: release credentials/configuration and candidate pipeline.
- Fix: resolve production stop-ships and execute the reviewed ephemeral-Keychain candidate pipeline with notary API credentials.
- Regression proof: accepted notary receipt, stapler validation, Gatekeeper acceptance and clean-machine launch for the exact candidate bytes.
- Status: OPEN — NOTARIZATION/RELEASE CONFIGURATION GATED.

24h/72h soak, signed-host System Proxy/TUN, network/sleep mutation, notarization, clean install and upgrade remain explicitly unexecuted. They are evidence gaps, not fabricated product findings.
