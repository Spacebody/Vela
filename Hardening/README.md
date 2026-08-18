# Vela V0.8 Public Beta hardening

This tree implements reproducible source gates, local-only evidence policy, safe test
orchestration, and audit/Beta operations. It does not turn missing human, signed-machine,
long-duration, or external evidence into a pass.

Core source gate:

```sh
python3 Hardening/scripts/validate_hardening_config.py
python3 Hardening/scripts/validate_github_workflows.py .github/workflows
python3 -m unittest discover -s Hardening/tests -p 'test_*.py'
```

The workflow gate rejects every job-level permission override except the exact
`.github/workflows/release.yml` `attest` mapping reviewed in
`config/github-actions.json`. The release workflow must retain top-level
`contents: read`; adding, removing, or moving any attestation-job permission is a
source-gate failure.

The architecture files are generated from the real project:

```sh
python3 Hardening/scripts/generate_architecture_manifest.py \
  --repository-root . \
  --architecture-output Hardening/config/architecture-freeze.json \
  --attack-surface-output Hardening/config/attack-surface.json
python3 Hardening/scripts/validate_architecture_freeze.py
```

PRs compare the generated baseline with source. A security-sensitive freeze change needs
an ADR whose before/after hashes match exactly; there is no generic `--allow-change` flag.

Dry-run the soak plan safely:

```sh
python3 Hardening/scripts/run_soak_matrix.py Hardening/config/soak-matrix.json
```

Execution additionally needs an explicit command map and output. Destructive scenarios
also need `VELA_RUN_DESTRUCTIVE_BETA_TESTS=1`, `--confirm-dedicated-machine`, and a strict
machine manifest proving a signed build, synthetic data, required capabilities, and
cleanup preflight. No destructive command map is committed here.

Current Release/Beta truth is in `config/release-readiness.json`. The expected result of a
release gate today is failure; for example:

```sh
python3 Hardening/scripts/validate_stop_ship.py --channel publicBeta
```

Do not clear a condition until the referenced real evidence exists and has been reviewed.

`create_test_run_manifest.py` binds a run to the generated build and requires the exact
active Core ID/version via `--core-version`; it does not invent an installed Core from the
bundled Mihomo version.
