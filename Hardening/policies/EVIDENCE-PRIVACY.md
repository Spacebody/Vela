# Reliability evidence privacy policy

Reliability evidence is local, bounded to 5,000 events or 30 days (whichever removes data
first), user-clearable, excluded from cloud sync, and has no upload scheduler. Session IDs
are random and cannot be reused as a stable installation/device identifier.

Allowed fields are stable build/channel, event/phase/result codes, duration, rollback
outcome, bounded resource counters, optional one-way generation hash, crash-signature
hash, and test-run ID. Profile/scene/node/group names or IDs, URL, host/IP/domain, SSID,
process/config path or value, Keychain account/value, controller secret, username, serial,
and raw error text are forbidden.

An export requires explicit user action, the V0.7 Support redactor, preview, size bounds,
and `scan_beta_evidence.py`. The scanner is an independent fail-closed gate, not a
redactor, and cannot be cited as proof that arbitrary binary traces are safe to publish.
Raw crash, xctrace, route/proxy, and multi-user lab evidence stays private unless manually
reviewed and transformed into the allowed summary schema.
