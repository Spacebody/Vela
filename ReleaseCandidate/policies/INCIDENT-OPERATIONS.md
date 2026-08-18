# V1 incident operations

Exercise bad App release, bad Core, migration corruption, Helper mismatch, TUN residue,
signature failure, synthetic secret exposure, crash loop, and support-volume spike using
the existing Hardening incident runbook. Record affected build, symptoms, safe action,
data/network state, rollback or update path, fixed build, owners, elapsed decisions, and
reviewed evidence.

Published bytes are immutable. Withdraw an Appcast entry or publish a newly signed Core
Catalog state; repair with a higher build. Never weaken trust, mutate an old artifact, or
request that a user publish secrets or an unredacted diagnostic archive.
