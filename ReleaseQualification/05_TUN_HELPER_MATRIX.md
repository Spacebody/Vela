# System Network Card / TUN and Helper Matrix

Date: 2026-08-22

## Authorization

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

No Helper was installed, no privileged handshake/session was created, no lease was acquired and no TUN interface/runtime was mutated. UI state is not accepted as privileged proof.

The host is not clean: Clash Verge owns active `utun1024` (`198.18.0.1`), and a stale inactive ServiceManagement registration for an older Vela Helper build remains in launchd while its executable is absent. The matrix must use a clean dedicated host or explicitly authorized cleanup plus interruption of the existing Clash route before it can produce admissible evidence.

| Scenario | Live result |
|---|---|
| Helper identity → handshake → session | NOT EXECUTED |
| TUN start → lease → Controller → traffic → stop → cleanup | NOT EXECUTED |
| Helper interruption/invalidation/crash | NOT EXECUTED |
| Lease expiry/renewal failure | NOT EXECUTED |
| Startup/Controller/stop timeout | NOT EXECUTED |
| Mihomo crash | NOT EXECUTED |
| Normal quit / force quit | NOT EXECUTED |
| Sleep/wake/network transition | NOT EXECUTED |
| Proxy OFF/TUN OFF and all three other combinations | NOT EXECUTED |

The authorized run must independently prove Helper state, root runtime, interface state, TUN authority, Controller state, EngineStore projection and cleanup after every case.
