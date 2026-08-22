# Vela Final Release Qualification

Date: 2026-08-22
Source baseline: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949`

## Decision

**NOT YET QUALIFIED FOR RELEASE**

Repository-controlled qualification reproduced no P0. Two full-suite-load evidence failures were characterized: a real P2 final-output capture race received the smallest local synchronization fix, and a P2 test-only Core rollback timing budget was calibrated without production lifecycle changes. A stale UI route test was corrected to current source truth.

Release remains blocked by evidence that cannot be inferred from repository tests:

- exact Developer-ID signed, notarized and stapled candidate;
- production trust/endpoints/legal/release-readiness inputs;
- signed-host System Proxy and TUN/Helper destructive matrices;
- combined Proxy+TUN transitions;
- repeated sleep/wake and network transitions;
- 24-hour and 72-hour soak;
- healthy-host accessibility runtime;
- previous-version upgrade/migration on the exact candidate.

## Evidence separation

### Repository-controlled correctness

- `./script/ci_test.sh` passed after rerunning outside the restricted sandbox used by the first attempt.
- Hardening validation reports 32 passing tests.
- Static CI reports 109 passing checks.
- VelaIPC reports 127 tests in 21 suites passing.
- Vela Xcode tests report 678 tests in 88 suites passing.
- VelaHelper reports 1 passing test.
- Focused Mihomo/Core suites pass five iterations (95 test executions).
- Unsigned Debug and Release builds pass.

The initial in-sandbox CI attempt was not an application failure: SwiftPM was denied by `sandbox-exec`. The identical repository command passed when allowed to execute with its normal build sandbox behavior. Privileged target availability is not treated as signed-host proof.

### Measured runtime performance

Existing rendered evidence applies to the same production UI source and shows no threshold breach. No new real-use bottleneck was reproduced, so no performance refactor was made.

### Signed-host evidence

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

### Release credential/configuration evidence

`NOT EXECUTED — SIGNING OR AUTHORIZATION REQUIRED`

The installed `/Applications/Vela.app` is an old invalid/non-candidate artifact and cannot close any release lane.

## Architecture preservation

No EngineStore split, Core workflow rewrite, global state owner or speculative abstraction was introduced. Runtime authority, mutation gates, privileged boundaries, configuration journals, Core trust, redaction and FaultInjector remain unchanged.

Do not release until RQ-004 and every explicitly gated matrix above has accepted evidence for the same candidate SHA. Failure to run a lane is not a pass.
