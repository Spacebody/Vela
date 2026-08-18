#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG="${SCRIPT_DIR}/config/core-release.json"
MODE="dry-run"
SEED=""
OUTPUT=""
KEYCHAIN=""
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run [--config FILE] | --execute --seed FILE --output DIR --keychain FILE [--config FILE]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "Core release config is missing or unsafe"
VALIDATE_CONFIG_ARGS=(--repository-root "${REPO_ROOT}" --config "${CONFIG}")
if [[ "${MODE}" == "execute" ]]; then VALIDATE_CONFIG_ARGS+=(--production); fi
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_config.py" "${VALIDATE_CONFIG_ARGS[@]}"
config_value() {
  /usr/bin/python3 - "${CONFIG}" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
if value is None:
    raise SystemExit("error: required Core release config value is null: " + sys.argv[2])
print(value)
PY
}
CONFIG_SEED="${REPO_ROOT}/$(config_value core.seed)"
[[ "$(config_value catalog.operation)" == "full" ]] || \
  fail "Core preparation requires catalog.operation=full; use the catalog-only incident workflow for incidents"
if [[ "${MODE}" == "dry-run" ]]; then
  FIXTURE_COMPAT="${REPO_ROOT}/Docs/V1/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/fixtures/compatibility-report-v1.19.28-r1.json"
  "${SCRIPT_DIR}/fetch_upstream_core.sh" --dry-run --seed "${CONFIG_SEED}"
  "${SCRIPT_DIR}/build_core_bundle.sh" --dry-run --seed "${CONFIG_SEED}" \
    --compatibility-report "${FIXTURE_COMPAT}" --license "${REPO_ROOT}/$(config_value core.license)" \
    --bundle-identifier "$(config_value product.bundleIdentifier)" --package-revision "$(config_value core.packageRevision)"
  "${SCRIPT_DIR}/verify_core_bundle.sh" --dry-run
  "${SCRIPT_DIR}/notarize_core_bundle.sh" --dry-run
  printf 'Core prepare dry-run completed. No network, signing, notarization, staging, or publication ran.\n'
  exit 0
fi
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --execute"
[[ -f "${SEED}" && ! -L "${SEED}" ]] || fail "--seed must be a regular reviewed seed file"
/usr/bin/cmp -s "${SEED}" "${CONFIG_SEED}" || fail "workflow seed bytes differ from the exact reviewed configured seed"
[[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new staging directory"
[[ -f "${KEYCHAIN}" && ! -L "${KEYCHAIN}" ]] || fail "--keychain must be an explicit ephemeral Keychain"
[[ -z "$(/usr/bin/git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "production Core preparation requires a clean checkout"
COMPATIBILITY="${REPO_ROOT}/$(config_value core.compatibilityReport)"
DEDICATED_EVIDENCE="${REPO_ROOT}/$(config_value core.dedicatedHostEvidence)"
PERFORMANCE_REVIEW="${REPO_ROOT}/$(config_value core.performanceReview)"
IDENTITY="$(config_value signing.developerIDIdentity)"
NOTARY_PROFILE_PREFIX="$(config_value signing.notaryProfilePrefix)"
NOTARY_PROFILE="${VELA_CORE_NOTARY_PROFILE:-}"
[[ -n "${GITHUB_RUN_ID:-}" && "${GITHUB_RUN_ID}" =~ ^[1-9][0-9]*$ ]] || \
  fail "production Core notarization requires the protected GitHub run ID"
[[ -n "${GITHUB_RUN_ATTEMPT:-}" && "${GITHUB_RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] || \
  fail "production Core notarization requires the protected GitHub run attempt"
EXPECTED_NOTARY_PROFILE="${NOTARY_PROFILE_PREFIX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
[[ "${NOTARY_PROFILE}" == "${EXPECTED_NOTARY_PROFILE}" ]] || \
  fail "VELA_CORE_NOTARY_PROFILE differs from the reviewed per-run profile contract"
TEAM="$(config_value product.teamIdentifier)"
IDENTIFIER="$(config_value product.bundleIdentifier)"
VERSION="$(config_value core.upstreamVersion)"
REVISION="$(config_value core.packageRevision)"
CORE_ID="$(config_value core.coreID)"
/bin/mkdir -m 0700 "${OUTPUT}"
FETCHED="${OUTPUT}/upstream"
VELA_CORE_RELEASE_EXECUTE=YES "${SCRIPT_DIR}/fetch_upstream_core.sh" --execute --seed "${SEED}" --output "${FETCHED}"
BUNDLE="${OUTPUT}/VelaMihomoCore.bundle"
VELA_CORE_RELEASE_EXECUTE=YES "${SCRIPT_DIR}/build_core_bundle.sh" --execute \
  --seed "${SEED}" --core-binary "${FETCHED}/mihomo" --compatibility-report "${COMPATIBILITY}" \
  --dedicated-host-evidence "${DEDICATED_EVIDENCE}" --performance-review "${PERFORMANCE_REVIEW}" \
  --license "${REPO_ROOT}/$(config_value core.license)" --bundle-identifier "${IDENTIFIER}" \
  --package-revision "${REVISION}" --output "${BUNDLE}" --identity "${IDENTITY}" --keychain "${KEYCHAIN}"
"${SCRIPT_DIR}/verify_core_bundle.sh" --production --bundle "${BUNDLE}" --team "${TEAM}" \
  --identifier "${IDENTIFIER}" --version "${VERSION}" --revision "${REVISION}"
/bin/mkdir -m 0700 "${OUTPUT}/notary"
VELA_CORE_RELEASE_EXECUTE=YES "${SCRIPT_DIR}/notarize_core_bundle.sh" --execute --bundle "${BUNDLE}" \
  --receipt-dir "${OUTPUT}/notary" --archive-output "${OUTPUT}/notary/VelaMihomoCore-${CORE_ID}.zip" \
  --keychain "${KEYCHAIN}" --profile "${NOTARY_PROFILE}"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_signed_core_identity.py" \
  --bundle "${BUNDLE}" --compatibility-report "${COMPATIBILITY}" \
  --upstream-payload "${FETCHED}/mihomo" --output "${OUTPUT}/signed-core-identity.json"
/usr/bin/shasum -a 256 "${COMPATIBILITY}" | /usr/bin/awk '{print $1 "  compatibility.json"}' >"${OUTPUT}/compatibility.sha256"
/bin/chmod 0600 "${OUTPUT}/compatibility.sha256"
printf 'Prepared signed/notarized Core staging without publication: %s\n' "${OUTPUT}"
