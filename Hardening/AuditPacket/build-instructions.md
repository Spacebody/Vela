# Auditor build and cleanup instructions

Use a clean Apple Silicon Mac with the repository's pinned Xcode/SwiftPM dependencies.
Run source-only tests and unsigned builds first:

```sh
python3 Hardening/scripts/validate_hardening_config.py
python3 -m unittest discover -s Hardening/tests -p 'test_*.py'
./script/ci_test.sh
./script/ci_build.sh
```

Production Developer ID/notary/App/Core signing keys are not distributed to auditors.
Privileged tests require a Development/Developer ID signed build, synthetic profiles and
Keychain services, an isolated dedicated machine, explicit
`VELA_RUN_DESTRUCTIVE_BETA_TESTS=1`, a passing machine manifest, and cleanup preflight.

Never run destructive commands from a fixture or modify an unknown utun/route/PID. Capture
pre/post state with `capture_cleanup_evidence.sh`, then use Vela's internal ownership checks
and fixed cleanup paths. A cleanup failure is itself an S1 candidate and must not be hidden
by rebooting or deleting unknown system state.
