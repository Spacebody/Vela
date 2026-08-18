# V0.8 threat-model refresh

Primary attackers are a malicious local unprivileged process, malicious or compromised
subscription/provider content, a network attacker, tampered update/Core infrastructure,
or user-controlled filesystem state. Protected assets are root execution, controller and
subscription secrets, signed trust roots, active proxy/TUN/routes, journals/stores, and
release credentials outside the repository.

High-priority abuse cases:

- code-signing/XPC identity bypass, protocol downgrade, oversized DTO, PID reuse;
- arbitrary root path/command/PID, symlink or rename race, stale journal;
- hostile YAML depth/aliases/listeners/scripts and protected-path escape;
- App/Core catalog tamper, replay, same-sequence substitution, expired/revoked key;
- migration data loss, downgrade overwrite, crash between write/rename/commit;
- stale TUN/route/system proxy or rollback loop after crash/sleep/network loss;
- Help markup/link injection, bidi spoofing, ZIP traversal, or secret export;
- retry storms, task/FD/process leaks, and fault controls present in Release;
- GitHub Action drift, leaked secrets, dependency drift, or provenance mismatch.

Residual risks and missing evidence are listed in `known-limitations.md` and the live
Stop-Ship assessment. Missing tool coverage is never interpreted as a security pass.
