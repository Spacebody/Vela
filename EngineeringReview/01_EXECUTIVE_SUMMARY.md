# Executive Summary

Review baseline: `main` through `38927e49843a`, plus the current configuration transaction/fault-injection review batch.

## Outcome

The repository-wide review found no open P0 and no untreated P1 defect in the reviewed source. Confirmed P1 failures were repaired through bounded changes that preserved the existing lifecycle, configuration, privileged, trust and recovery contracts:

- Core activation now releases the shared runtime-mutation lease before public operations return.
- Core transaction verification compares canonical durable bytes rather than an impossible subsecond in-memory timestamp round trip.
- Legacy structured profile migration preserves prepended rules.
- Runtime/update journal persistence failures are no longer silently suppressed.
- Long-lived routed telemetry and privileged lease streams have explicit retention bounds.
- Configuration capture/staging and compilation/validation now have explicit private phase boundaries, while the existing coordinator remains the sole workflow and recovery owner.
- The existing deterministic `FaultInjector` now proves controller-apply rollback restores the previous authoritative revision and removes its journal.

The review did **not** replace `EngineStore`, `CoreLifecycleController`, the privileged boundary, the configuration transaction layer or the Hardening architecture. Existing reliable owners remain authoritative.

## Current architecture assessment

1. `EngineStore` remains a broad `@MainActor @Observable` runtime facade. It owns legitimate aggregate state but also exposes high-rate feature projections. File IO already proven to run on MainActor was moved behind existing concurrent owners. A focused Observation contract now proves that traffic updates do not invalidate proxy-catalog observers; broader view/body extraction still requires production profiling evidence.
2. `CoreLifecycleController` remains the Core workflow facade. Low-level durable state stays in `CoreStore`, download/staging work stays in `CoreFileDownloader`, and the shared runtime mutation gate remains the cross-workflow exclusion boundary.
3. Configuration apply retains validate → stage → persist → apply/restart → health proof → rollback/recovery semantics with atomic durable writes and revision checks.
4. System Proxy and TUN remain independent, composable controls. Their ownership, verification, rollback and helper lease contracts were preserved.
5. Logs, Connections, Rules, Proxies and Configuration presentation work now use bounded or serial latest-wins pipelines where repository evidence showed material MainActor or recomputation risk.

## Verification summary

- Hardening configuration: 12 files validated.
- GitHub workflow pin validation: 9 workflows passed.
- Hardening unit suite: 30/30 passed.
- Static CI lane: 109/109 tests passed; Xcode/Swift tests intentionally excluded by `--static-only`.
- `VelaIPC`: 127/127 tests passed.
- Unsigned arm64 Debug build: passed.
- Unsigned arm64 Release build: passed.
- Focused regression suites for every implementation batch passed before commit; details are retained in the domain reports.
- The generated `Vela/Resources/ReleaseCandidate/baseline.json` was reconciled through the repository's existing deterministic generator and revalidated by the static CI lane.

No signing, notarization, installation, TUN mutation or native System Proxy mutation was performed during this final review pass.

## Remaining known risks

The remaining items are evidence or measurement gaps, not known P0/P1 product defects:

1. Native System Proxy and installed-helper/TUN end-to-end matrices require an explicitly authorized, signed privileged host.
2. The real live-services `AppEnvironment` dependency graph has an isolated construction/termination proof, and configuration rollback now has canonical fault-injection proof at its authoritative transaction boundary. Native process execution and late Core-probation faults remain environment/integration validation targets.
3. Proxy-delay capture now uses a linear catalog/cache projection with a 10,000-entry budget. Instruments/signpost evidence across complete rendered pages remains the prerequisite for another EngineStore extraction.
4. The local Xcode test service started the isolated accessibility test but wedged in the host session and cleanup path (`Waiting for -runningDidFinish` / `waiting for workers to materialize`). The same source read completes in under one millisecond outside XCTest and the result bundle contains no assertion failure; the lane must be rerun on a healthy test service.
5. Release feed, signing identity, production Core trust/evidence and compatibility values remain deliberately fail-closed placeholders. Static validation confirms that they cannot be mistaken for a production release.

## Decision

The current source is materially safer and more maintainable than the starting snapshot without a giant architecture diff. The next work should follow `14_REFACTOR_PLAN.md`: collect runtime measurements and privileged integration evidence first, then extract only the boundaries whose cost or ownership problem is proven.
