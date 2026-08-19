# Privileged Boundary Audit

Review baseline: `main` at `50de407d`, after the first bounded Core lifecycle fix. The frozen `VelaIPC` schema and existing helper identity/session contracts were treated as constraints, not redesign targets.

## Authority and ownership map

| Boundary | Authoritative owner | Proof mechanism |
|---|---|---|
| XPC peer identity | `VelaHelperBootstrapListenerDelegate` | Every accepted message is checked against the designated code-signing requirement before the helper exports its interface. |
| RPC session and transport generation | `XPCPrivilegedHelperClient` actor | A compatible handshake establishes an opaque session. Request IDs, session IDs and connection generations reject stale replies and stale interruption handlers. |
| Privileged runtime and TUN lease | `PrivilegedHelperCoordinator` plus `OwnerLeaseCoordinator` actors | UID, session ID and connection ID must all match; expiration invokes authoritative process/TUN/transaction cleanup. |
| App-side prepared runtime | `PrivilegedMihomoBackend` actor | Configuration/resources are bounded, hashed and staged through stable file descriptors; commit validates the helper response before publishing a runtime. |
| Unknown-outcome recovery | Helper status, queried by `EngineStore` | Timeout, interruption or cancellation is not interpreted as success/failure. The app reconnects, reads helper authority and proves runtime/TUN/routes absent before continuing. |

## Existing mechanisms that must be preserved

1. `PrivilegedHelperRPCTimeouts` gives each RPC class a finite timeout; staging time grows only within a bounded policy.
2. `XPCReplyGate` resumes exactly once, supports cancellation before continuation installation and cancels its timeout timer.
3. Every mutating request requires an established session; response request IDs must match the request.
4. XPC interruption preserves only the opaque reconnect identity; invalidation clears transport authority. Generation checks prevent an old connection callback from invalidating a new connection.
5. Helper ownership is fail closed: lease renewal requires the same session/connection, sleep freezes the monotonic lease, wake grants a bounded grace period and expiry performs cleanup.
6. Staged configuration and resource requests have payload/count/byte limits. Resource files are opened with `O_NOFOLLOW`, checked with `lstat` and `fstat`, and rejected if device/inode/size changes.
7. An indeterminate privileged commit/stop is reconciled from helper status. The app does not infer privileged state from Controller availability.
8. Existing integration tests exercise signed handshake/status, malformed input, traversal, unsafe configuration and TUN lifecycle. These tests and the frozen IPC contract remain authoritative.

## Findings

### PRIV-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Privileged/PrivilegedHelperClient.swift`
- **Line/Type:** `PrivilegedHelperRPCTimeouts`, `XPCPrivilegedHelperClient.perform`, `XPCReplyGate`
- **Evidence:** RPCs are bounded by operation-specific timeouts and request/response limits. `perform` installs cancellation handling, validates the response request ID and invalidates an uncertain transport. `XPCReplyGate` serializes continuation/timer completion and prevents double resume.
- **Impact:** A stalled or duplicated XPC reply cannot leave an app operation waiting forever or publish a reply from the wrong request as current state.
- **Fix:** Preserve. New RPCs must use the same `perform` path and receive an explicit timeout/payload policy.
- **Test:** Existing client timeout, cancellation, response-correlation and reconnect tests; add a contract test whenever a new method is added.
- **Status:** No defect found.

### PRIV-002

- **Severity:** Verified mechanism
- **File:** `VelaIPC/Sources/VelaPrivilegedCore/OwnerLeaseCoordinator.swift`; `VelaIPC/Sources/VelaPrivilegedCore/PrivilegedHelperCoordinator.swift`
- **Line/Type:** lease claim/renew/disconnect/sleep/wake/expiry and active-lease guards
- **Evidence:** The coordinator requires exact UID/session/connection ownership, uses a monotonic clock, grants only bounded reconnect grace and stops process/TUN plus aborts staged work after expiration.
- **Impact:** Helper crash/disconnect and app disappearance converge to a bounded fail-closed cleanup path rather than leaving an indefinite privileged runtime.
- **Fix:** Preserve the single authoritative lease owner and exact-match checks.
- **Test:** Existing lease and helper coordinator tests, plus privileged integration TUN lifecycle tests.
- **Status:** No defect found.

### PRIV-003

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Privileged/PrivilegedMihomoBackend.swift`; `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** prepared start/commit/stop/status and `reconcilePrivilegedRuntimeToStopped`
- **Evidence:** Staging failures abort a known transaction. Timeout/interruption after commit or stop is marked indeterminate; EngineStore reconnects, queries helper status and proves process, TUN, routes and instance identity are absent before forward progress.
- **Impact:** Late helper completion cannot silently resurrect a runtime after app cancellation or termination.
- **Fix:** Preserve. Never replace reconciliation with a local boolean or Controller-disconnected check.
- **Test:** Existing termination-barrier late-commit and stale-bootstrap-runtime tests.
- **Status:** No defect found.

### PRIV-TASK-001

- **Severity:** P2
- **File:** `VelaHelper/VelaHelperXPCService.swift`
- **Line/Type:** per-request `Task` wrappers in exported RPC methods
- **Evidence:** Each XPC method creates an unstructured Swift task that is not registered against its owning `NSXPCConnection`. Client cancellation/timeout closes the app-side wait but cannot directly cancel helper-side work already accepted.
- **Impact:** Correctness remains fail closed because transaction identity, lease expiry and app reconciliation handle late completion. However, expensive rejected/disconnected work may outlive its caller and task ownership is not directly inspectable.
- **Fix:** In a bounded helper-only change, introduce connection/session-scoped task registration and cancel only work whose operation contract is cancellation-safe. Do not cancel cleanup/rollback work and do not change the frozen RPC schema.
- **Test:** Disconnect during staging and validation; prove cancellable work terminates, cleanup still completes and a late reply cannot mutate a later session.
- **Status:** Open; no P1 state-corruption path reproduced.

### PRIV-STREAM-001

- **Severity:** P3
- **File:** `Vela/Core/Privileged/PrivilegedLeaseCoordinator.swift`
- **Line/Type:** `events()`
- **Evidence:** Subscriber termination cleanup was already correct. The stream now uses `.bufferingNewest(8)`, matching its low-frequency state-like semantics and the bounded policy used by other long-lived streams.
- **Impact:** Normal renewal rate is low, so production exposure is limited. A stalled subscriber under rapid injected failures can accumulate events.
- **Fix:** Implemented without changing the frozen IPC schema, lease authority or renewal lifecycle.
- **Test:** The focused lease-coordinator test proves a stalled subscriber receives only the newest bounded suffix.
- **Status:** Closed; also recorded as `CONC-STREAM-001`.

## Privileged boundary conclusion

No known P0 or P1 defect was found in the reviewed privileged paths. The authoritative source is helper lease/status, not app presentation state and not Controller connectivity. The next privileged changes should be small hardening/test batches; a helper/client rewrite would weaken better mechanisms already present.

## Verification

- `swift test --package-path VelaIPC`: 127 tests in 21 suites passed, including owner lease, operation serialization, root transaction/FileHandle staging, route probing, sanitizer, journal recovery and IPC schema tests.
- The first sandboxed attempt was blocked by the local SwiftPM module-cache sandbox. Re-running with a private `/tmp` scratch/cache outside the nested sandbox completed successfully; this was an environment constraint, not a test failure.
