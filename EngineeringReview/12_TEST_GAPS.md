# Test Gaps

## Existing proof baseline

The repository already has unusually strong unit coverage for the transition coordinator, runtime configuration transaction/journal, system proxy compare-and-swap recovery, privileged filesystem, IPC schema, controller decoding/retry, connection projection performance, logging privacy and Hardening contracts. Gaps below are scoped to missing proof, not absence of the underlying mechanisms.

## Findings

### TEST-CORE-001

- **Severity:** P1 proof gap
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift:659-861`; `VelaTests/CoreLifecycle/CoreLifecycleControllerTests.swift`
- **Line/Type:** activation cancellation/probation/rollback composition
- **Evidence:** The transition coordinator suite proves generic cancellation and rollback. The focused Core lifecycle suite now also proves lease release for same-Core and pre-transaction failure, cancellation after journal creation, durable manual-repair state when automatic rollback fails, candidate health failure rollback, and healthy probation commit.
- **Impact:** A future edit could leave the Core journal, active resolver or runtime mutation lease inconsistent even while generic transition tests pass.
- **Fix:** Extend the existing Core lifecycle fixture with deterministic phase hooks/fault injection; do not create a second transition framework.
- **Test:** Covered: cancel after transaction creation with journal/Core/lease assertions, canonical subsecond journal update, rollback failure requiring manual repair with retained failed journal, candidate health failure restoring the previous Core, and healthy probation success committing the candidate and releasing the mutation lease. Remaining P2 matrix: probation-time runtime degradation after an initially healthy candidate and full production-adapter snapshot assertions.
- **Status:** Closed for known P1 correctness. The reproduced cancellation/journal defects are fixed and both probation terminal directions are now proven at controller level. The remaining production-adapter and late-probation fault combinations stay tracked as P2 integration work.

### TEST-NET-001

- **Severity:** P2 integration gap
- **File:** `VelaTests/SystemProxy/`; `VelaPrivilegedIntegrationTests/`
- **Line/Type:** native network adapter composition
- **Evidence:** `SystemProxyManagerTests` provides deterministic partial failure, external modification, verification and recovery coverage. The signed privileged integration target exercises helper identity/session handshake and status, malformed payload rejection, traversal and unsafe-configuration rejection, plus a minimal real TUN lifecycle. It intentionally does not mutate the host's selected macOS System Configuration network service.
- **Impact:** An entitlement, command-output or OS-version integration regression can pass the pure actor suite.
- **Fix:** Add an opt-in, environment-gated native integration scenario that snapshots and restores the exact test service. Never run it unguarded in ordinary unit CI.
- **Test:** Enable -> verify -> restore, partial failure, stale ownership and external modification.
- **Status:** Repository-controlled P2 correctness is closed by deterministic manager tests. Native network-service mutation remains an explicit signed-host release-validation item because running it would alter external machine state.

### TEST-TUN-001

- **Severity:** P2 integration gap
- **File:** `VelaPrivilegedIntegrationTests/`; `VelaIPC/Tests/VelaPrivilegedCoreTests/`
- **Line/Type:** helper/TUN long-running lifecycle
- **Evidence:** IPC and privileged-core suites cover schema, lease ownership/expiry, sleep/wake grace, dead-process and abandoned-runtime cleanup, symlink-safe cleanup and bounded process waits. `PrivilegedHandshakeStatusIntegrationTests` additionally proves signed helper identity/session handling, fail-closed malformed/traversal/unsafe configuration paths, and start -> Controller/interface/route/DNS/lease health -> stop/cleanup for mixed, system and gVisor TUN stacks. The signed target does not deliberately crash the installed helper or force host sleep/wake/stop-timeout conditions.
- **Impact:** Cross-process lifecycle regressions can escape unit fakes.
- **Fix:** Reuse the privileged integration target and existing fault injection. Keep tests opt-in where root/helper installation is required.
- **Test:** Start TUN -> lease active -> controller ready -> stop -> cleanup proof; helper crash; lease expiry; sleep/wake; stop timeout.
- **Status:** Closed for repository-controlled lifecycle logic and the safe signed-helper start/stop matrix. Destructive helper-crash and host power/timing scenarios remain authorization-gated release validation, not an untreated code finding.

### TEST-CONFIG-001

- **Severity:** P2 integration gap
- **File:** `VelaTests/Configuration/RuntimeConfigTransactionCoordinatorTests.swift`; `VelaTests/App/`
- **Line/Type:** production wiring composition
- **Evidence:** The coordinator suite covers health-failure rollback, reload/restart failure, crash recovery and journal retention. `RuntimeConfigFaultInjectionTests` reuses the canonical `FaultInjector` at `configuration.apply` and proves prior active bytes/revision restoration, bounded reload behavior, durable expected-state evidence and journal cleanup. `AppEnvironmentCompositionTests` constructs the real live-services graph in a private startup-smoke directory and proves the resulting EngineStore reaches its termination barrier.
- **Impact:** Repository-owned transaction ordering, rollback and production composition assembly now have deterministic regression proof. Native process launch and Controller transport behavior can still vary by host/toolchain.
- **Fix:** Completed without changing the zero-argument production contract or adding a second failure framework. Keep a real-process apply/restart/health run in release validation.
- **Test:** 28 transaction/fault-injection tests plus production `AppEnvironment` construction and termination.
- **Status:** Closed for repository-controlled P2 proof. Native Mihomo/Controller execution remains environment-sensitive release evidence, not an open implementation defect.

### TEST-PERF-001

- **Severity:** P2 performance proof gap
- **File:** `VelaTests/Rules/RulesPresentationTests.swift`; performance test targets
- **Line/Type:** large rule set and production profiling
- **Evidence:** Connections has explicit 10k-row churn/search latency tests and Logs has 50k-entry MainActor responsiveness coverage. `RulesServiceTests` now exercises 50,000-rule load, grouping, search/filter transitions, runtime API ordering and a MainActor responsiveness marker. No checked-in Instruments/ETTrace release baseline yet proves responsiveness across real traffic/log streams.
- **Impact:** A large subscription can introduce UI stalls without a correctness-test failure.
- **Fix:** The deterministic rule projection benchmark is implemented. Retain Instruments output as an optional CI artifact or documented release check rather than making hardware-sensitive wall-clock traces a mandatory unit gate.
- **Test:** 10k and 50k rules, repeated query/filter/group updates, high-frequency traffic/log streams, MainActor stall budget.
- **Status:** Closed for deterministic Rules projection/load proof. Production Instruments/ETTrace remains a documented release-validation activity, not a reproduced code defect.

### TEST-ACCESS-001

- **Severity:** P2 UI proof gap
- **File:** `VelaTests/Localization/OnboardingAccessibilityLocalizationTests.swift`; feature views
- **Line/Type:** critical action accessibility matrix
- **Evidence:** `CriticalControlsAccessibilityTests` now provides one source-contract matrix for stateful Overview network and route controls, proxy-node pointer/assistive/keyboard activation, Logs filters, Configuration Apply discoverability and Reduce Motion adoption on the daily-driver pages. Existing localization tests continue to cover the Chinese/English catalogs.
- **Impact:** A label or focus regression can ship unnoticed while visual tests remain unchanged.
- **Fix:** Implemented stable identifiers, action semantics, keyboard activation and Reduce Motion source contracts without relying on screenshot-only assertions.
- **Test:** Chinese/English label existence, enabled state, focusability and Reduce Motion behavior.
- **Status:** Closed for the audited source contracts. The clean Xcode host compiled the suite, but isolated executions either stalled before worker materialization or wedged after starting the first test; the result bundle contains no assertion failure and direct source IO completes in under one millisecond. Runtime completion must be rechecked when the local Xcode test service is healthy.

## Priority order

1. Run the opt-in native System Proxy/helper matrices only on an explicitly authorized signed host; these are release evidence, not ordinary CI mutations.
2. Extend the Core matrix with late-probation runtime degradation and production-adapter snapshots before any broader Core facade extraction.
3. Keep the deterministic configuration fault-injection and live-services composition suites as required regression gates for transaction edits.
