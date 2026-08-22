# Signed-Host Evidence

Date: 2026-08-22  
Closure baseline: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc`

## Authorization State

**NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED**

No signed application was installed or launched for this pass. No System Proxy setting, TUN interface, privileged helper, lease, network service, sleep/wake state or user runtime was mutated. UI state is not accepted as privileged runtime proof.

## System Proxy Matrix

| Scenario | Required terminal proof | Result |
|---|---|---|
| OFF → snapshot → enable → read back → verify ownership → disable → restore → read back | `VERIFIED_APPLIED`, then `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Partial enable failure | `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Read-back mismatch | `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| External modification while owned by Vela | `VERIFIED_RESTORED` without overwriting unowned state | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Controller failure during ownership | `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Engine stop | `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Application termination | `VERIFIED_RESTORED` | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Sleep/wake | `VERIFIED_APPLIED` or `VERIFIED_RESTORED`, never unknown | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Network service change | `VERIFIED_APPLIED` or `VERIFIED_RESTORED`, never unknown | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |

No scenario is marked passed. `UNKNOWN`, `PARTIALLY_CONFIGURED` and `ASSUMED_RESTORED` are not acceptable terminal evidence.

## TUN / Helper Matrix

| Scenario | Required proof | Result |
|---|---|---|
| Install → identity → handshake → session → TUN start → lease → Controller → runtime → stop → cleanup | Helper, root runtime, EngineStore projection, TUN authority and cleanup all agree | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Helper interruption | Verified cleanup or verified resumed authority | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Helper invalidation | Verified cleanup and closed session | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Helper crash | Root runtime and lease prove cleanup/recovery | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Lease expiration | Root runtime stops or authority is reacquired and verified | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Lease renewal timeout | Verified cleanup; no UI-only success | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| TUN startup timeout | Verified no residual interface/process/lease | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Controller startup timeout | Verified root runtime cleanup and projection convergence | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Process crash | Verified helper/runtime/lease convergence | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Application termination | Verified stop and cleanup proof | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Sleep/wake | Verified authority after wake or verified cleanup | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |
| Stop timeout | Verified terminal cleanup or fail-closed retained ownership | NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED |

## Existing Repository Evidence

Static, unit and fault-injection evidence continues to cover identity/session checks, timeouts, interruption/invalidation handling, lease authority, rollback and cleanup contracts. That evidence is not represented as a substitute for the signed-host matrix above.
