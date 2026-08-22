# Vela 24-Hour Soak Qualification

Date: 2026-08-22
Source baseline: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949`

## Status

`NOT EXECUTED — 24-HOUR WALL-CLOCK RUN NOT COMPLETED`

No 24-hour result is claimed. The current session performed bounded repository gates and repeated focused runtime tests only. It did not keep the exact signed candidate running for 24 hours, and no signed candidate was installed or launched.

## Required run

The release run must use the exact signed candidate and record, at fixed intervals:

- Vela, Mihomo and Helper PID/liveness;
- resident and virtual memory, CPU and handle counts;
- retained log and connection counts;
- Controller reconnect count and stream health;
- System Proxy/TUN ownership and read-back proof;
- journal/temp-file inventory;
- node and route changes, sleep/wake and network reconnect events.

It must include ordinary browsing, idle periods, page switching, node switching, route changes, sleep/wake and network reconnect. Single samples cannot close trend-based risks.

## Entry and exit criteria

Entry requires the exact signed candidate, an explicitly authorized dedicated host, and passing System Proxy/TUN normal paths. Exit requires no monotonic resource growth, unverifiable network state, journal residue, permanent reconnect loop, sustained CPU regression or repeated interaction stall.
