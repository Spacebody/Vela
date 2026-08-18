#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG="${ROOT}/ReleaseCandidate/config"

PYTHONPYCACHEPREFIX="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-rc-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX
trap '/bin/rm -rf "${PYTHONPYCACHEPREFIX}"' EXIT

/usr/bin/python3 -m compileall -q "${SCRIPT_DIR}" "${ROOT}/ReleaseCandidate/tests"
for script in "${SCRIPT_DIR}"/*.sh; do
  /bin/bash -n "${script}"
done

/usr/bin/python3 - "${ROOT}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "ReleaseCandidate/scripts"))
from _common import load_json, validate_schema

for stem in ("published-builds", "support-matrix", "known-limitations", "migration-guarantee", "installation-matrix", "audit-closure", "go-no-go"):
    value = load_json(root / "ReleaseCandidate/config" / f"{stem}.json", label=stem)
    validate_schema(value, f"{stem}.schema.json")
PY

/usr/bin/python3 "${SCRIPT_DIR}/validate_migration_guarantee.py" \
  "${CONFIG}/migration-guarantee.json" --allow-pending
/usr/bin/python3 "${SCRIPT_DIR}/validate_installation_matrix.py" \
  "${CONFIG}/installation-matrix.json" --allow-pending \
  --public-contract "${ROOT}/Contracts/v1/public-contract-freeze.json"
/usr/bin/python3 "${SCRIPT_DIR}/validate_audit_closure.py" \
  "${CONFIG}/audit-closure.json" --allow-pending
/usr/bin/python3 "${SCRIPT_DIR}/validate_known_limitations.py" \
  "${CONFIG}/known-limitations.json" --version 1.0.0
/usr/bin/python3 "${SCRIPT_DIR}/validate_support_matrix.py" \
  "${CONFIG}/support-matrix.json" \
  --public-contract "${ROOT}/Contracts/v1/public-contract-freeze.json"
/usr/bin/python3 "${SCRIPT_DIR}/validate_app_resources.py" \
  --repository-root "${ROOT}"
/usr/bin/python3 "${SCRIPT_DIR}/validate_go_no_go.py" \
  "${CONFIG}/go-no-go.json" --expect noGo
"${SCRIPT_DIR}/scan_release_candidate.sh" --source "${ROOT}/ReleaseCandidate"

printf 'Release Candidate tooling structural validation passed; committed decision remains NO-GO.\n'
