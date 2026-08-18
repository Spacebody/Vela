# Stop-Ship and incident drill runbook

Release and Security/Reliability owners confirm a Stop-Ship. S0/S1 remains blocking unless
independent evidence proves an environment false positive. Clearing requires a fixed new
build plus the failing regression, cleanup, rollback, and applicable signing/notary tests.

For a bad App release, withdraw/replace the signed Appcast item without mutating the
published archive; retain the previous Stable. For a bad Core entry, publish a newly
signed catalog marking it blocked/withdrawn and provide visible rollback. Never remotely
force networking off or weaken trust to recover.

A hotfix gets a new build number, immutable artifact, full signing/notary/tests, and Beta
verification unless emergency coordinated S0 handling requires otherwise. Communicate
affected builds, severity, safe action, network impact, fixed build, and limitations
without disclosing sensitive exploit detail early.

Drill: bad App item, bad Core entry, unavailable App/Core signing key, Helper mismatch,
migration corruption, TUN residue, secret in a synthetic diagnostic fixture, and
provenance mismatch. Record actual date, owners, elapsed decisions, cleanup, and evidence;
do not check a drill box based on reading this runbook.
