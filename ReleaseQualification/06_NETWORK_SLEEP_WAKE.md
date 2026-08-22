# Network Transition and Sleep/Wake Qualification

Date: 2026-08-22

## Status

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

No sleep, Wi-Fi, DNS, IP, network-service, IPv4/IPv6 availability, System Proxy or TUN mutation was performed. A separate Clash Verge Mihomo runtime was active and intentionally left untouched.

Required coverage is repeated connected sleep/wake for Proxy-only, TUN-only, combined and disconnected states; Wi-Fi off/on and A/B transitions; temporary loss; Ethernet/Wi-Fi where available; DNS/IP and IPv4/IPv6 changes. Every case must prove Engine, Controller, routing, ownership, Helper lease, traffic and UI projection after recovery.

Permanent connecting state, duplicate runtime/stream, stale routing, unverifiable ownership or false connected presentation are failures.
