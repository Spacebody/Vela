#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

MODE="dry-run"
KIND=""
ARTIFACT=""
RECEIPT_DIR=""
ARCHIVE_OUTPUT=""
KEYCHAIN=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--dry-run|--execute] --kind app|dmg --artifact PATH --receipt-dir DIR [--archive-output ZIP] [--keychain TEMP_KEYCHAIN]\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --receipt-dir) RECEIPT_DIR="${2:-}"; shift 2 ;;
    --archive-output) ARCHIVE_OUTPUT="${2:-}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ "${KIND}" == "app" || "${KIND}" == "dmg" ]] || fail "--kind must be app or dmg"
if [[ "${KIND}" == "app" ]]; then
  [[ -d "${ARTIFACT}" && ! -L "${ARTIFACT}" && "${ARTIFACT}" == *.app ]] || fail "App artifact is invalid"
else
  [[ -f "${ARTIFACT}" && ! -L "${ARTIFACT}" && "${ARTIFACT}" == *.dmg ]] || fail "DMG artifact is invalid"
fi
if [[ -n "${ARCHIVE_OUTPUT}" ]]; then
  [[ "${KIND}" == "app" ]] || fail "--archive-output is valid only for App notarization"
  [[ "${ARCHIVE_OUTPUT}" == *.zip ]] || fail "--archive-output must end in .zip"
  [[ ! -e "${ARCHIVE_OUTPUT}" && ! -L "${ARCHIVE_OUTPUT}" ]] || fail "refusing to overwrite App notary ZIP"
fi
[[ -n "${RECEIPT_DIR}" ]] || fail "--receipt-dir is required"

command -v xcrun >/dev/null || fail "xcrun is unavailable"
/usr/bin/xcrun notarytool --version >/dev/null

if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Notarization dry-run passed for %s. No upload, staple, or mutation was performed.\n' "${KIND}"
  exit 0
fi

[[ "${VELA_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_RELEASE_EXECUTE=YES and pass --execute"
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARY_PROFILE must name a protected notarytool Keychain profile"
[[ "${NOTARY_PROFILE}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "NOTARY_PROFILE contains unsafe characters"
[[ -f "${KEYCHAIN}" && ! -L "${KEYCHAIN}" ]] || fail "--keychain must be an explicit regular ephemeral Keychain"
KEYCHAIN="$(cd "$(/usr/bin/dirname "${KEYCHAIN}")" && /bin/pwd -P)/$(/usr/bin/basename "${KEYCHAIN}")"
[[ "$(/usr/bin/stat -f '%Lp' "${KEYCHAIN}")" == "600" ]] || fail "ephemeral Keychain permissions must be 0600"
[[ "$(/usr/bin/stat -f '%u' "${KEYCHAIN}")" == "$(/usr/bin/id -u)" ]] || fail "ephemeral Keychain must be owned by the release user"
KEYCHAIN_PARENT="$(/usr/bin/dirname "${KEYCHAIN}")"
[[ "$(/usr/bin/stat -f '%Lp' "${KEYCHAIN_PARENT}")" == "700" ]] || fail "ephemeral Keychain parent permissions must be 0700"
TEMP_KEYCHAIN=0
for candidate_root in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}"; do
  if [[ -n "${candidate_root}" && -d "${candidate_root}" && ! -L "${candidate_root}" ]]; then
    candidate_root="$(cd "${candidate_root}" && /bin/pwd -P)"
    case "${KEYCHAIN}" in
      "${candidate_root}"/*) TEMP_KEYCHAIN=1 ;;
    esac
  fi
done
[[ "${TEMP_KEYCHAIN}" == "1" ]] || fail "Keychain must live under RUNNER_TEMP or TMPDIR"
case "$(/usr/bin/basename "${KEYCHAIN}")" in
  login.keychain|login.keychain-db|System.keychain) fail "persistent login/system Keychains are forbidden" ;;
esac
/usr/bin/security show-keychain-info "${KEYCHAIN}" >/dev/null 2>&1 || fail "ephemeral Keychain is unavailable or locked"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "notarization release gate requires Apple Silicon"

/bin/mkdir -p "${RECEIPT_DIR}"
[[ -d "${RECEIPT_DIR}" && ! -L "${RECEIPT_DIR}" ]] || fail "receipt directory is unsafe"
RECEIPT_DIR="$(cd "${RECEIPT_DIR}" && /bin/pwd -P)"
RESULT="${RECEIPT_DIR}/notary-${KIND}-result.json"
LOG="${RECEIPT_DIR}/notary-${KIND}-log.json"
[[ ! -e "${RESULT}" && ! -L "${RESULT}" ]] || fail "notary receipt already exists"
[[ ! -e "${LOG}" && ! -L "${LOG}" ]] || fail "notary log already exists"

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-notary-${KIND}.XXXXXX")"
cleanup() {
  local result=$?
  case "${WORK}" in
    "${TEMP_ROOT}"/vela-notary-"${KIND}".*) /bin/rm -rf "${WORK}" ;;
    *) printf 'warning: refused to clean unexpected notarization staging path\n' >&2 ;;
  esac
  return "${result}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

SUBMISSION="${ARTIFACT}"
if [[ "${KIND}" == "app" ]]; then
  /usr/bin/codesign --verify --strict --verbose=4 "${ARTIFACT}"
  TEMP_ARCHIVE="${WORK}/Vela-app-notary.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${ARTIFACT}" "${TEMP_ARCHIVE}"
  if [[ -n "${ARCHIVE_OUTPUT}" ]]; then
    ARCHIVE_PARENT="$(/usr/bin/dirname "${ARCHIVE_OUTPUT}")"
    /bin/mkdir -p "${ARCHIVE_PARENT}"
    [[ -d "${ARCHIVE_PARENT}" && ! -L "${ARCHIVE_PARENT}" ]] || fail "App notary ZIP parent is unsafe"
    ARCHIVE_OUTPUT="$(cd "${ARCHIVE_PARENT}" && /bin/pwd -P)/$(/usr/bin/basename "${ARCHIVE_OUTPUT}")"
    /bin/ln "${TEMP_ARCHIVE}" "${ARCHIVE_OUTPUT}" || fail "App notary ZIP appeared concurrently"
    /bin/chmod 0600 "${ARCHIVE_OUTPUT}"
    SUBMISSION="${ARCHIVE_OUTPUT}"
  else
    SUBMISSION="${TEMP_ARCHIVE}"
  fi
else
  /usr/bin/hdiutil imageinfo "${ARTIFACT}" >/dev/null
fi

TEMP_RESULT="${WORK}/result.json"
SUBMIT_EXIT=0
/usr/bin/xcrun notarytool submit "${SUBMISSION}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --keychain "${KEYCHAIN}" \
  --wait \
  --output-format json >"${TEMP_RESULT}" || SUBMIT_EXIT=$?
[[ -s "${TEMP_RESULT}" ]] || fail "notarytool returned no JSON receipt"
/usr/bin/plutil -lint "${TEMP_RESULT}" >/dev/null || fail "notarytool receipt is not valid JSON/plist"
/bin/chmod 0600 "${TEMP_RESULT}"
/bin/ln "${TEMP_RESULT}" "${RESULT}" || fail "notary receipt appeared concurrently"

STATUS="$(/usr/bin/plutil -extract status raw -o - "${RESULT}" 2>/dev/null || true)"
IDENTIFIER="$(/usr/bin/plutil -extract id raw -o - "${RESULT}" 2>/dev/null || true)"
if [[ "${SUBMIT_EXIT}" != "0" || "${STATUS}" != "Accepted" ]]; then
  if [[ -n "${IDENTIFIER}" ]]; then
    /usr/bin/xcrun notarytool log "${IDENTIFIER}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --keychain "${KEYCHAIN}" \
      --output-format json >"${LOG}" || true
    /bin/chmod 0600 "${LOG}" 2>/dev/null || true
  fi
  fail "notarization was not Accepted (status=${STATUS:-unknown}, id=${IDENTIFIER:-unknown})"
fi

/usr/bin/xcrun stapler staple "${ARTIFACT}"
/usr/bin/xcrun stapler validate "${ARTIFACT}"
if [[ "${KIND}" == "app" ]]; then
  /usr/sbin/spctl --assess --type execute --verbose=4 "${ARTIFACT}"
else
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "${ARTIFACT}"
fi
printf 'Notarization accepted and stapled: kind=%s id=%s receipt=%s\n' "${KIND}" "${IDENTIFIER}" "${RESULT}"
