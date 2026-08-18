#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG="${SCRIPT_DIR}/config/core-release.json"
MODE="dry-run"
PRIOR_CATALOG=""
PRIVATE_KEY_FILE=""
ROTATION_PRIVATE_KEY_FILE=""
OUTPUT=""
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run [--config FILE] | --staging --prior-catalog FILE --output DIR --private-key-file FILE [--rotation-private-key-file FILE] [--config FILE]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --staging) MODE="staging"; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --prior-catalog) PRIOR_CATALOG="${2:-}"; shift 2 ;;
    --private-key-file) PRIVATE_KEY_FILE="${2:-}"; shift 2 ;;
    --rotation-private-key-file) ROTATION_PRIVATE_KEY_FILE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "Core release config is missing or unsafe"
VALIDATE_ARGS=(--repository-root "${REPO_ROOT}" --config "${CONFIG}")
if [[ "${MODE}" == "staging" ]]; then VALIDATE_ARGS+=(--production); fi
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_config.py" "${VALIDATE_ARGS[@]}"
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Core incident publish dry-run completed. No Catalog, signature, or output was created.\n'
  exit 0
fi
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --staging"
[[ -f "${PRIOR_CATALOG}" && ! -L "${PRIOR_CATALOG}" ]] || fail "--prior-catalog must be the fixed verified prior Catalog"
[[ -f "${PRIVATE_KEY_FILE}" && ! -L "${PRIVATE_KEY_FILE}" ]] || fail "--private-key-file must be a regular protected key file"
[[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new immutable directory"
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
config_optional() {
  /usr/bin/python3 - "${CONFIG}" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
if value is not None:
    print(value)
PY
}
[[ "$(config_value catalog.operation)" == "incident" ]] || fail "catalog-only publication requires catalog.operation=incident"
SEQUENCE="$(config_value catalog.sequence)"
CORE_ID="$(config_value core.coreID)"
PRIMARY_KEY_ID="$(config_value catalog.keyID)"
ROTATION_KEY_ID="$(config_optional catalog.rotationKeyID)"
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  [[ -f "${ROTATION_PRIVATE_KEY_FILE}" && ! -L "${ROTATION_PRIVATE_KEY_FILE}" ]] || \
    fail "configured Catalog rotation requires --rotation-private-key-file"
elif [[ -n "${ROTATION_PRIVATE_KEY_FILE}" ]]; then
  fail "rotation private key is forbidden when catalog.rotationKeyID is unconfigured"
fi
/usr/bin/env python3 "${SCRIPT_DIR}/verify_prior_core_catalog.py" "${PRIOR_CATALOG}" --config "${CONFIG}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-core-incident.XXXXXX")"
cleanup() { local status=$?; /bin/rm -rf "${WORK}"; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_incident_catalog.py" \
  --prior-catalog "${PRIOR_CATALOG}" --core-id "${CORE_ID}" \
  --status "$(config_value catalog.status)" --reason "$(config_value catalog.blockReason)" \
  --sequence "${SEQUENCE}" --generated-at "$(config_value catalog.generatedAt)" \
  --expires-at "$(config_value catalog.expiresAt)" \
  --key-set-version "$(config_value catalog.keySetVersion)" \
  --output "${WORK}/core-catalog.json" --production
PRIMARY_SIGNATURES="${WORK}/core-catalog.signatures.json"
if [[ -n "${ROTATION_KEY_ID}" ]]; then PRIMARY_SIGNATURES="${WORK}/core-catalog.primary.signatures.json"; fi
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${WORK}/core-catalog.json" \
  --key-id "${PRIMARY_KEY_ID}" --private-key-file "${PRIVATE_KEY_FILE}" \
  --output "${PRIMARY_SIGNATURES}" --repository-root "${REPO_ROOT}"
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  /usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${WORK}/core-catalog.json" \
    --key-id "${ROTATION_KEY_ID}" --private-key-file "${ROTATION_PRIVATE_KEY_FILE}" \
    --existing-envelope "${PRIMARY_SIGNATURES}" \
    --output "${WORK}/core-catalog.signatures.json" --repository-root "${REPO_ROOT}"
fi
CATALOG_VALIDATE=(
  "${WORK}/core-catalog.json" --signatures "${WORK}/core-catalog.signatures.json"
  --public-keyring "${REPO_ROOT}/$(config_value catalog.publicKeyring)"
  --prior-catalog "${PRIOR_CATALOG}" --production
  --required-key-id "${PRIMARY_KEY_ID}" --require-exact-key-set
)
if [[ -n "${ROTATION_KEY_ID}" ]]; then CATALOG_VALIDATE+=(--required-key-id "${ROTATION_KEY_ID}"); fi
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG_VALIDATE[@]}"
PUBLIC="${WORK}/public"
/bin/mkdir "${PUBLIC}"
/bin/cp -p "${WORK}/core-catalog.json" "${WORK}/core-catalog.signatures.json" "${PUBLIC}/"
/usr/bin/env python3 "${SCRIPT_DIR}/stage_core_catalog_history.py" \
  --catalog "${WORK}/core-catalog.json" --signatures "${WORK}/core-catalog.signatures.json" \
  --public-directory "${PUBLIC}" --sequence "${SEQUENCE}"
/usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${PUBLIC}"
/bin/mkdir -p "$(/usr/bin/dirname "${OUTPUT}")"
/bin/mv -n "${PUBLIC}" "${OUTPUT}"
[[ -d "${OUTPUT}" && ! -e "${PUBLIC}" ]] || fail "Core incident output appeared concurrently"
printf 'Catalog-only Core incident staged atomically without bundle rebuild: %s\n' "${OUTPUT}"
