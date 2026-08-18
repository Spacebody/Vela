# Known limitations and truthful Stop-Ship state

At creation of this source packet:

- the checkout is an in-progress dirty implementation, not an exact signed release tag;
- production Sparkle feed/key and Core endpoints/keyring are unprovisioned;
- the Release contract still requires CLI, Automation protocol, and Scene schema while
  production compatibility truthfully records them as absent/null;
- the private security contact and required privacy/legal reviews are incomplete;
- no historical tag-generated V0.1-V0.7 migration fixtures exist;
- performance budgets are uncalibrated and contain no approved absolute ceilings;
- 24h/72h soak, destructive TUN/sleep, multi-user, and physical accessibility labs have
  not been executed;
- no third-party audit/finding verification has occurred;
- no final signed/notarized V0.8 artifact, SBOM/provenance set, or artifact attestation
  exists.

These are active policy gates in `Hardening/config/release-readiness.json`; they are not
silently marked passed by scaffolding or unit tests.
