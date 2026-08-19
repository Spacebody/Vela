# Test Gaps

## Existing proof baseline

The repository already has unusually strong unit coverage for the transition coordinator, runtime configuration transaction/journal, system proxy compare-and-swap recovery, privileged filesystem, IPC schema, controller decoding/retry, connection projection performance, logging privacy and Hardening contracts. Gaps below are scoped to missing proof, not absence of the underlying mechanisms.

## Findings

### TEST-CORE-001

- **Severity:** P1 proof gap
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift:659-861`; `VelaTests/CoreLifecycle/CoreLifecycleControllerTests.swift`
- **Line/Type:** activation cancellation/probation/rollback composition
- **Evidence:** The transition coordinator suite proves generic cancellation and rollback. Core activation itself persists a transaction, switches resolver/state, starts and health-proves a candidate, transfers its mutation lease to probation, and launches cancellation rollback in a fresh MainActor task. Focused tests now prove lease release for same-Core and pre-transaction failure, cancellation after journal creation, and durable manual-repair state when automatic rollback also fails; probation commit/rollback remains uncovered.
- **Impact:** A future edit could leave the Core journal, active resolver or runtime mutation lease inconsistent even while generic transition tests pass.
- **Fix:** Extend the existing Core lifecycle fixture with deterministic phase hooks/fault injection; do not create a second transition framework.
- **Test:** Covered: cancel after transaction creation with journal/Core/lease assertions, canonical subsecond journal update, and rollback failure requiring manual repair with retained failed journal. Remaining: candidate health failure; probation success; probation failure; runtime/backend snapshot assertions.
- **Status:** Partially closed. The reproduced cancellation defect is fixed and its regression test passes; the remaining probation and fault-injection matrix must be closed before final Definition of Done.

### TEST-NET-001

- **Severity:** P2 integration gap
- **File:** `VelaTests/SystemProxy/`; `VelaPrivilegedIntegrationTests/`
- **Line/Type:** native network adapter composition
- **Evidence:** `SystemProxyManagerTests` provides deterministic partial failure, external modification, verification and recovery coverage. The privileged integration target currently contains only the handshake/status smoke path and does not exercise the real macOS network service adapter.
- **Impact:** An entitlement, command-output or OS-version integration regression can pass the pure actor suite.
- **Fix:** Add an opt-in, environment-gated native integration scenario that snapshots and restores the exact test service. Never run it unguarded in ordinary unit CI.
- **Test:** Enable -> verify -> restore, partial failure, stale ownership and external modification.
- **Status:** Open P2 integration proof gap.

### TEST-TUN-001

- **Severity:** P2 integration gap
- **File:** `VelaPrivilegedIntegrationTests/`; `VelaIPC/Tests/VelaPrivilegedCoreTests/`
- **Line/Type:** helper/TUN long-running lifecycle
- **Evidence:** IPC and privileged-core suites cover schema, leases, cleanup and bounded process waits. No installed-helper integration matrix was found for lease expiry, helper crash, sleep/wake and stop timeout through production AppEnvironment wiring.
- **Impact:** Cross-process lifecycle regressions can escape unit fakes.
- **Fix:** Reuse the privileged integration target and existing fault injection. Keep tests opt-in where root/helper installation is required.
- **Test:** Start TUN -> lease active -> controller ready -> stop -> cleanup proof; helper crash; lease expiry; sleep/wake; stop timeout.
- **Status:** Open P2 integration proof gap.

### TEST-CONFIG-001

- **Severity:** P2 integration gap
- **File:** `VelaTests/Configuration/RuntimeConfigTransactionCoordinatorTests.swift`; `VelaTests/App/`
- **Line/Type:** production wiring composition
- **Evidence:** The coordinator suite covers health-failure rollback, reload/restart failure, crash recovery and journal retention. It does not execute the complete native process/controller adapters assembled by AppEnvironment.
- **Impact:** Production adapter ordering can regress independently from the authoritative transaction actor.
- **Fix:** Add an AppEnvironment integration harness that injects the existing faults while retaining the real composition order.
- **Test:** Apply -> restart -> health proof -> prior-state restore; controller timeout; process failure; relaunch recovery.
- **Status:** Open P2 integration proof gap.

### TEST-PERF-001

- **Severity:** P2 performance proof gap
- **File:** `VelaTests/Rules/RulesPresentationTests.swift`; performance test targets
- **Line/Type:** large rule set and production profiling
- **Evidence:** Connections has explicit 10k-row churn/search latency tests and Logs has 10k-entry snapshot tests. No equivalent 10k/50k threshold was found for rule grouping/search/hit aggregation, and no checked-in Instruments/ETTrace release baseline proves MainActor responsiveness across real traffic/log streams.
- **Impact:** A large subscription can introduce UI stalls without a correctness-test failure.
- **Fix:** Add deterministic rule projection benchmarks and retain Instruments output as an optional CI artifact or documented release check.
- **Test:** 10k and 50k rules, repeated query/filter/group updates, high-frequency traffic/log streams, MainActor stall budget.
- **Status:** Open P2 proof gap.

### TEST-ACCESS-001

- **Severity:** P2 UI proof gap
- **File:** `VelaTests/Localization/OnboardingAccessibilityLocalizationTests.swift`; feature views
- **Line/Type:** critical action accessibility matrix
- **Evidence:** Critical views have many explicit labels/identifiers and Reduce Motion handling, but there is no single automated matrix covering System Proxy, TUN, route mode, node selection, start/stop, log filters/inspector and configuration apply in both languages.
- **Impact:** A label or focus regression can ship unnoticed while visual tests remain unchanged.
- **Fix:** Extend existing accessibility/localization tests with stable identifiers and action semantics; avoid screenshot-only assertions.
- **Test:** Chinese/English label existence, enabled state, focusability and Reduce Motion behavior.
- **Status:** Open P2 proof gap.

## Priority order

1. Close `TEST-CORE-001` before declaring P1 complete.
2. Add deterministic performance characterization before changing projection architecture.
3. Add opt-in native integration proof without weakening or bypassing Hardening gates.
