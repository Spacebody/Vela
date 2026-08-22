# System Proxy Qualification Matrix

Date: 2026-08-22

## Authorization

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

The host is not declared disposable or authorized for System Proxy mutation. Read-only `scutil --proxy` showed no enabled proxy dictionary entries at baseline. That is not lifecycle proof.

| Scenario | Live result |
|---|---|
| Original → enable → exact read-back → disable → exact restore | NOT EXECUTED |
| Engine startup failure after enable | NOT EXECUTED |
| Controller unavailable | NOT EXECUTED |
| Profile apply failure | NOT EXECUTED |
| External modification during ownership | NOT EXECUTED |
| Normal quit / force quit | NOT EXECUTED |
| Mihomo crash | NOT EXECUTED |
| Sleep/wake | NOT EXECUTED |
| Wi-Fi reconnect/network switch/service mutation | NOT EXECUTED |

No scenario is labelled `VERIFIED_APPLIED` or `VERIFIED_RESTORED` without signed-host read-back. Existing ownership, rollback and fault-injection tests remain repository evidence; they do not substitute for this host matrix.
