# System Network Audit

Review baseline: `main` at `50de407d`. Product contract: System Proxy and TUN (shown as System Network Card in the UI) are independently controlled and may be enabled together.

## Authoritative sources

| State | Authority | App projection |
|---|---|---|
| Current macOS proxy dictionaries | `LiveSystemProxyBackend` / SystemConfiguration | `SystemProxyManager.status()` classifies ownership and recovery need. |
| Vela-owned proxy mutation | Durable `SystemProxyRecoveryLease` | Original and managed fields provide compare-and-swap evidence for restore. |
| TUN/process/route ownership | Privileged helper lease and helper status | `PrivilegedMihomoBackend` and EngineStore reconcile from helper authority. |
| Stable requested user state | EngineStore expected-state projection | Published only after a verified operation; it is not used as proof of OS/helper state. |

## Stable-state model

```text
System Proxy: off / Vela-managed / external / partial-recovery
TUN:          off / helper-owned-and-live / indeterminate-reconciling
```

These axes are independent. During a backend transition Vela may temporarily restore System Proxy before changing the local endpoint and then re-enable it. That safety staging does not make the final modes mutually exclusive.

## Existing mechanisms that must be preserved

1. `SystemProxyManager` serializes mutations with a FIFO transaction gate.
2. Enable captures every active service's original proxy fields and writes a durable recovery lease before changing SystemConfiguration.
3. `LiveSystemProxyBackend.apply` locks preferences, compares every service against the expected snapshot, stages all changes, then commits/applies them.
4. Restore changes only Vela-managed fields. External changes to unrelated fields are preserved; conflicting managed fields are released rather than overwritten.
5. The recovery lease is cleared only after verification proves the managed fields are restored or safely released.
6. Commit/apply ambiguity is handled as an unknown outcome followed by status verification/rollback, not as a simple failure boolean.
7. TUN lifecycle mutations use the shared `RuntimeMutationGate`, `EngineTransitionCoordinator` and helper lease authority.
8. A transition failure must prove both runtime/TUN cleanup and System Proxy convergence before reporting rollback complete.

## Findings

### NET-PROXY-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/SystemProxy/SystemProxyManager.swift`; `Vela/Core/SystemProxy/LiveSystemProxyBackend.swift`; `Vela/Core/SystemProxy/SystemProxyRecoveryStore.swift`
- **Line/Type:** enable/restore/status/rollback transaction paths
- **Evidence:** A private atomic recovery lease precedes mutation; the native backend uses service-level compare-and-swap under an `SCPreferences` lock; restore verifies and preserves externally modified fields.
- **Impact:** Vela does not overwrite an administrator/user's newer proxy configuration and does not claim recovery without durable evidence.
- **Fix:** Preserve. All future proxy mutations must pass through this transaction owner.
- **Test:** Existing SystemProxyManager and recovery-store tests for external edits, failed restore, missing services, duplicate metadata and atomic round trip.
- **Status:** No defect found.

### NET-MODE-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** `performSetSystemProxyEnabled`, `setTunEnabled`, `transitionToTun`, `transitionToUser`
- **Evidence:** System Proxy and TUN have separate public operations and state. TUN transitions temporarily restore/reapply System Proxy only to move the local endpoint safely; the stable state supports both enabled.
- **Impact:** The implementation matches the documented independent-and-stackable product contract.
- **Fix:** Preserve. Tests and UI must continue treating these as two axes.
- **Test:** Add/retain a matrix for proxy-only, TUN-only, both, neither, plus profile/core switches in all four states.
- **Status:** No defect found.

### NET-TUN-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Engine/EngineStore.swift`; `Vela/Core/Privileged/PrivilegedMihomoBackend.swift`; `VelaIPC/Sources/VelaPrivilegedCore/OwnerLeaseCoordinator.swift`
- **Line/Type:** TUN enable/disable, helper status reconciliation and lease expiry
- **Evidence:** Engine mutations are serialized; helper process/TUN status is authoritative; cancellation and unknown RPC outcome trigger reconciliation; lease expiry cleans process, TUN/routes and staged work.
- **Impact:** Controller state and UI selection cannot independently claim that TUN is live or stopped.
- **Fix:** Preserve the helper-authoritative model. Never infer TUN state from Controller reachability.
- **Test:** Existing privileged backend/helper tests and integration lifecycle test; add sleep/wake plus helper-crash combinations where environment permits.
- **Status:** No defect found.

### NET-INTEGRATION-001

- **Severity:** P2 test gap
- **File:** `VelaTests/`; `VelaPrivilegedIntegrationTests/`
- **Line/Type:** real SystemConfiguration/TUN failure-injection matrix
- **Evidence:** Unit tests cover commit rejection, indeterminate outcome, external edits, rollback and helper cleanup. A true host integration test that forces `SCPreferencesCommitChanges` success followed by apply/verification failure, and then proves native restoration, is not part of the default deterministic test suite.
- **Impact:** The algorithm is covered, but OS-specific authorization/preferences behavior can regress outside the in-memory backend model.
- **Fix:** Add an opt-in, isolated privileged integration scenario using the existing `FaultInjection` controls and a disposable network-service fixture. Never weaken default security gates or alter the user's active network service.
- **Test:** Apply failure after commit, app/helper crash, wake, external edit and retry; prove recovery lease retention and eventual exact managed-field cleanup.
- **Status:** Open; environment-sensitive integration coverage.

### NET-OPS-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** system-network operation presentation and backend transitions
- **Evidence:** Correctness is centralized, but System Proxy/TUN operation state, transition state, expected state and authoritative status are projected through the broad EngineStore observation root.
- **Impact:** High-frequency unrelated updates can invalidate views observing network operation presentation, and the large facade makes illegal presentation combinations harder to test even though backend authority is sound.
- **Fix:** After correctness work, expose a narrow immutable system-network snapshot owned by existing managers/EngineStore facade. Do not create a second mutation owner.
- **Test:** Projection consistency across all four stable combinations and every applying/rollback/failure phase.
- **Status:** Planned strangler projection; mutation authority remains unchanged.

## System network conclusion

No known P0/P1 was found in the reviewed System Proxy/TUN paths. The implementation already uses durable ownership, compare-and-swap, rollback verification and privileged lease authority. Remaining work is test/projection hardening, not a replacement network architecture.

## Verification

- `SystemProxyManagerTests`: 21 tests passed, including PAC/WPAD rejection, lease-before-apply, external ownership, service/key-level CAS, indeterminate/partial failure rollback, missing-service recovery, FIFO serialization and cancellation.
- `SystemProxyRecoveryStoreTests`: 4 tests passed, including atomic persistence, malformed metadata and duplicate service rejection.
- `VelaIPC`: 127 tests passed, including helper lease, TUN route proof and crash-artifact cleanup.
- Native authorization and host-network mutation were intentionally not performed by this review batch; they remain the opt-in integration gap recorded as `NET-INTEGRATION-001`.
