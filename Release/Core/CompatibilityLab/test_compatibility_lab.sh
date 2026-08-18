#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && /bin/pwd -P)"
PACK_REPORT="${REPO_ROOT}/Docs/V1/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/fixtures/compatibility-report-v1.19.28-r1.json"
FACTORY="${REPO_ROOT}/Vendor/Mihomo/bin/mihomo"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-compat-tests.XXXXXX")"
cleanup() { local status=$?; /bin/rm -rf "${WORK}"; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export PYTHONDONTWRITEBYTECODE=1
/usr/bin/env python3 -m unittest discover -s "${SCRIPT_DIR}/tests" -p 'test_*.py' -v
/usr/bin/env python3 "${SCRIPT_DIR}/validate_compatibility_report.py" "${PACK_REPORT}" --core-id v1.19.28-r1
if /usr/bin/env python3 "${SCRIPT_DIR}/validate_compatibility_report.py" "${PACK_REPORT}" --production >"${WORK}/expected-production-failure.log" 2>&1; then
  printf 'error: Pack fixture was unexpectedly accepted as production evidence\n' >&2
  exit 1
fi

if [[ "${VELA_COMPAT_LIVE_TEST:-NO}" == "YES" ]]; then
  "${REPO_ROOT}/Release/Core/run_core_compatibility.sh" \
    --candidate-executable "${FACTORY}" \
    --upstream-payload "${FACTORY}" \
    --factory-executable "${FACTORY}" \
    --core-id v1.19.28-r1 \
    --output "${WORK}/local-report.json" \
    --generated-at 2026-07-13T00:00:00Z \
    --skip-performance
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_compatibility_report.py" \
    "${WORK}/local-report.json" --core-id v1.19.28-r1
  /usr/bin/python3 - "${WORK}/local-report.json" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["result"] == "failed"
assert report["environment"]["userDataAccessed"] is False
assert report["artifacts"]["candidateExecutableSHA256"] == report["artifacts"]["factoryExecutableSHA256"]
assert report["artifacts"]["upstreamPayloadSHA256"] == report["artifacts"]["candidateExecutableSHA256"]
assert any(item.startswith("tun-backend:") for item in report["knownDeviations"])
PY
fi

printf 'Vela Core Compatibility Lab tooling tests passed.\n'
