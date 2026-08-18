#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG="${SCRIPT_DIR}/config/core-release.json"
MODE="dry-run"
PREPARED=""
PRIVATE_KEY_FILE=""
ROTATION_PRIVATE_KEY_FILE=""
KEYCHAIN_SERVICE=""
KEYCHAIN_ACCOUNT=""
KEYCHAIN=""
PRIOR_CATALOG=""
OUTPUT=""
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run [--config FILE] | --staging --prepared DIR --output DIR [--private-key-file FILE | --keychain-service SERVICE --keychain-account ACCOUNT --keychain FILE] [--rotation-private-key-file FILE] [--prior-catalog VERIFIED_FILE]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --staging) MODE="staging"; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --prepared) PREPARED="${2:-}"; shift 2 ;;
    --private-key-file) PRIVATE_KEY_FILE="${2:-}"; shift 2 ;;
    --rotation-private-key-file) ROTATION_PRIVATE_KEY_FILE="${2:-}"; shift 2 ;;
    --keychain-service) KEYCHAIN_SERVICE="${2:-}"; shift 2 ;;
    --keychain-account) KEYCHAIN_ACCOUNT="${2:-}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:-}"; shift 2 ;;
    --prior-catalog) PRIOR_CATALOG="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "Core release config is missing or unsafe"
VALIDATE_CONFIG_ARGS=(--repository-root "${REPO_ROOT}" --config "${CONFIG}")
if [[ "${MODE}" == "staging" ]]; then VALIDATE_CONFIG_ARGS+=(--production); fi
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_config.py" "${VALIDATE_CONFIG_ARGS[@]}"
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Core publish dry-run completed. Missing production values remain stop-ship; no Catalog, signature, split files, or output was created.\n'
  exit 0
fi
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --staging"
[[ -d "${PREPARED}" && ! -L "${PREPARED}" ]] || fail "--prepared must be a regular prepared Core directory"
[[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new immutable directory"
if [[ -n "${PRIVATE_KEY_FILE}" ]]; then
  [[ -z "${KEYCHAIN_SERVICE}" && -z "${KEYCHAIN_ACCOUNT}" ]] || fail "choose either private key file or Keychain entry"
else
  [[ -n "${KEYCHAIN_SERVICE}" && -n "${KEYCHAIN_ACCOUNT}" && -n "${KEYCHAIN}" ]] || fail "Core Catalog signing requires an explicit key file or protected Keychain entry"
fi
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
CORE_ID="$(config_value core.coreID)"
[[ "$(config_value catalog.operation)" == "full" ]] || \
  fail "full Core publication requires catalog.operation=full"
SEQUENCE="$(config_value catalog.sequence)"
PRIMARY_KEY_ID="$(config_value catalog.keyID)"
ROTATION_KEY_ID="$(config_optional catalog.rotationKeyID)"
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  [[ -f "${ROTATION_PRIVATE_KEY_FILE}" && ! -L "${ROTATION_PRIVATE_KEY_FILE}" ]] || \
    fail "configured Catalog rotation requires --rotation-private-key-file"
elif [[ -n "${ROTATION_PRIVATE_KEY_FILE}" ]]; then
  fail "rotation private key is forbidden when catalog.rotationKeyID is unconfigured"
fi
if [[ "${SEQUENCE}" -gt 1 ]]; then
  [[ -f "${PRIOR_CATALOG}" && ! -L "${PRIOR_CATALOG}" ]] || fail "Catalog sequence >1 requires --prior-catalog acquired from the fixed reviewed origin"
  /usr/bin/env python3 "${SCRIPT_DIR}/verify_prior_core_catalog.py" \
    "${PRIOR_CATALOG}" --config "${CONFIG}"
elif [[ -n "${PRIOR_CATALOG}" ]]; then
  fail "Catalog sequence 1 must not accept --prior-catalog"
fi
BUNDLE="${PREPARED}/VelaMihomoCore.bundle"
NOTARY_RECEIPT="${PREPARED}/notary/notary-core-result.json"
COMPATIBILITY="${REPO_ROOT}/$(config_value core.compatibilityReport)"
DEDICATED_EVIDENCE="${REPO_ROOT}/$(config_value core.dedicatedHostEvidence)"
PERFORMANCE_REVIEW="${REPO_ROOT}/$(config_value core.performanceReview)"
SIGNED_IDENTITY="${PREPARED}/signed-core-identity.json"
UPSTREAM_PAYLOAD="${PREPARED}/upstream/mihomo"
[[ -f "${NOTARY_RECEIPT}" && ! -L "${NOTARY_RECEIPT}" ]] || fail "prepared Core lacks a real notary receipt"
[[ "$(/usr/bin/plutil -extract status raw -o - "${NOTARY_RECEIPT}" 2>/dev/null || true)" == "Accepted" ]] || fail "prepared Core notarization is not Accepted"
/usr/bin/cmp -s "${COMPATIBILITY}" "${BUNDLE}/Contents/Resources/compatibility.json" || fail "prepared Core compatibility report bytes differ from the reviewed release report"
[[ -f "${SIGNED_IDENTITY}" && ! -L "${SIGNED_IDENTITY}" ]] || fail "prepared Core lacks final signed identity evidence"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_signed_core_identity.py" "${SIGNED_IDENTITY}" \
  --bundle "${BUNDLE}" --compatibility-report "${COMPATIBILITY}" \
  --upstream-payload "${UPSTREAM_PAYLOAD}"
"${SCRIPT_DIR}/verify_core_bundle.sh" --production --bundle "${BUNDLE}" \
  --team "$(config_value product.teamIdentifier)" --identifier "$(config_value product.bundleIdentifier)" \
  --version "$(config_value core.upstreamVersion)" --revision "$(config_value core.packageRevision)"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-core-publish.XXXXXX")"
cleanup() { local status=$?; /bin/rm -rf "${WORK}"; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_file_index.py" "${BUNDLE}" \
  --base-url "$(config_value catalog.baseURL)/${CORE_ID}" --output "${WORK}/files.json"
/usr/bin/python3 - "${CONFIG}" "${WORK}/status-transitions.json" <<'PY'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(config["catalog"]["statusTransitions"], sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
CATALOG_ARGS=(
  --seed "${REPO_ROOT}/$(config_value core.seed)"
  --compatibility-report "${COMPATIBILITY}"
  --dedicated-host-evidence "${DEDICATED_EVIDENCE}"
  --performance-review "${PERFORMANCE_REVIEW}"
  --file-index "${WORK}/files.json"
  --output "${WORK}/core-catalog.json"
  --sequence "${SEQUENCE}"
  --generated-at "$(config_value catalog.generatedAt)"
  --expires-at "$(config_value catalog.expiresAt)"
  --published-at "$(config_value catalog.publishedAt)"
  --key-set-version "$(config_value catalog.keySetVersion)"
  --status "$(config_value catalog.status)"
  --status-transitions "${WORK}/status-transitions.json"
  --release-notes-url "$(config_value catalog.releaseNotesURL)"
  --bundle-identifier "$(config_value product.bundleIdentifier)"
  --minimum-vela-version "$(config_value product.velaVersion)"
  --minimum-vela-build "$(config_value product.velaBuild)"
  --production
)
BLOCK_REASON="$(config_optional catalog.blockReason)"
if [[ -n "${BLOCK_REASON}" ]]; then CATALOG_ARGS+=(--block-reason "${BLOCK_REASON}"); fi
if [[ -n "${PRIOR_CATALOG}" ]]; then CATALOG_ARGS+=(--prior-catalog "${PRIOR_CATALOG}"); fi
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_catalog.py" "${CATALOG_ARGS[@]}"
PRIMARY_SIGNATURES="${WORK}/core-catalog.signatures.json"
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  PRIMARY_SIGNATURES="${WORK}/core-catalog.primary.signatures.json"
fi
SIGN_ARGS=(
  "${WORK}/core-catalog.json"
  --key-id "${PRIMARY_KEY_ID}"
  --output "${PRIMARY_SIGNATURES}"
  --repository-root "${REPO_ROOT}"
)
if [[ -n "${PRIVATE_KEY_FILE}" ]]; then
  SIGN_ARGS+=(--private-key-file "${PRIVATE_KEY_FILE}")
else
  SIGN_ARGS+=(--keychain-service "${KEYCHAIN_SERVICE}" --keychain-account "${KEYCHAIN_ACCOUNT}" --keychain "${KEYCHAIN}")
fi
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${SIGN_ARGS[@]}"
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  /usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" \
    "${WORK}/core-catalog.json" --key-id "${ROTATION_KEY_ID}" \
    --private-key-file "${ROTATION_PRIVATE_KEY_FILE}" \
    --existing-envelope "${PRIMARY_SIGNATURES}" \
    --output "${WORK}/core-catalog.signatures.json" \
    --repository-root "${REPO_ROOT}"
fi
VALIDATE_ARGS=(
  "${WORK}/core-catalog.json"
  --signatures "${WORK}/core-catalog.signatures.json"
  --public-keyring "${REPO_ROOT}/$(config_value catalog.publicKeyring)"
  --compatibility-report "${COMPATIBILITY}"
  --dedicated-host-evidence "${DEDICATED_EVIDENCE}"
  --performance-review "${PERFORMANCE_REVIEW}"
  --production
  --required-key-id "${PRIMARY_KEY_ID}"
  --require-exact-key-set
)
if [[ -n "${ROTATION_KEY_ID}" ]]; then
  VALIDATE_ARGS+=(--required-key-id "${ROTATION_KEY_ID}")
fi
if [[ -n "${PRIOR_CATALOG}" ]]; then VALIDATE_ARGS+=(--prior-catalog "${PRIOR_CATALOG}"); fi
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${VALIDATE_ARGS[@]}"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_sbom.py" \
  --seed "${REPO_ROOT}/$(config_value core.seed)" --file-index "${WORK}/files.json" --core-id "${CORE_ID}" \
  --created-at "$(config_value catalog.publishedAt)" --output "${WORK}/core-sbom.spdx.json"
PUBLIC="${WORK}/public"
/bin/mkdir -p "${PUBLIC}/${CORE_ID}/Contents/MacOS" "${PUBLIC}/${CORE_ID}/Contents/_CodeSignature" "${PUBLIC}/${CORE_ID}/Contents/Resources"
while IFS= read -r relative; do
  /bin/cp -p "${BUNDLE}/${relative}" "${PUBLIC}/${CORE_ID}/${relative}"
done <<'FILES'
Contents/Info.plist
Contents/MacOS/mihomo
Contents/_CodeSignature/CodeResources
Contents/Resources/LICENSE
Contents/Resources/NOTICE.md
Contents/Resources/source.json
Contents/Resources/compatibility.json
FILES
/bin/cp -p "${WORK}/core-catalog.json" "${WORK}/core-catalog.signatures.json" "${WORK}/files.json" "${WORK}/core-sbom.spdx.json" "${PUBLIC}/"
/usr/bin/env python3 "${SCRIPT_DIR}/stage_core_catalog_history.py" \
  --catalog "${WORK}/core-catalog.json" \
  --signatures "${WORK}/core-catalog.signatures.json" \
  --public-directory "${PUBLIC}" --sequence "${SEQUENCE}"
/usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${PUBLIC}"
/bin/mkdir -p "$(/usr/bin/dirname "${OUTPUT}")"
/bin/mv -n "${PUBLIC}" "${OUTPUT}"
[[ -d "${OUTPUT}" && ! -e "${PUBLIC}" ]] || fail "Core publication output appeared concurrently"
printf 'Core release staged atomically without upload: %s\n' "${OUTPUT}"
