#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
APP=""
DMG=""
MANIFEST=""
ARTIFACTS=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --artifacts-dir) ARTIFACTS="${2:-}"; shift 2 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "RC bundle verification requires macOS"
[[ -d "${APP}" && ! -L "${APP}" ]] || fail "--app must be a regular App bundle"
[[ -f "${DMG}" && ! -L "${DMG}" ]] || fail "--dmg must be a regular DMG"
[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || fail "--manifest is required"
[[ -d "${ARTIFACTS}" && ! -L "${ARTIFACTS}" ]] || fail "--artifacts-dir is required"

/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_candidate.py" "${MANIFEST}" \
  --stage local --verify-files --artifacts-dir "${ARTIFACTS}"

MARKETING_VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["candidate"]["marketingVersion"])' "${MANIFEST}")"
BUILD="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["candidate"]["build"])' "${MANIFEST}")"
EXPECTED_DMG="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["artifacts"]["dmg"]["filename"])' "${MANIFEST}")"
CHECKSUMS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["artifacts"]["checksums"]["filename"])' "${MANIFEST}")"
[[ "$(/usr/bin/basename "${DMG}")" == "${EXPECTED_DMG}" ]] || fail "DMG basename differs from RC manifest"

"${REPO_ROOT}/Release/scripts/verify_release_bundle.sh" --post-notary \
  --app "${APP}" --dmg "${DMG}" \
  --config "${REPO_ROOT}/Release/config/release.json" \
  --expected-version "${MARKETING_VERSION}" --expected-build "${BUILD}"
"${REPO_ROOT}/Hardening/scripts/scan_release_fault_controls.sh" "${APP}"
"${SCRIPT_DIR}/scan_release_candidate.sh" --public "${ARTIFACTS}"
/usr/bin/env python3 "${REPO_ROOT}/Release/scripts/generate_checksums.py" verify \
  --checksums "${ARTIFACTS}/${CHECKSUMS}" --base-dir "${ARTIFACTS}"

printf 'Vela Release Candidate local bundle verification passed; attestation and final Go remain external/pending.\n'
